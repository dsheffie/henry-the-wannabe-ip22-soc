// -----------------------------------------------------------------------------
// henry_tb.cpp -- Verilator testbench for the Henry IP22 SoC top (henry_soc).
//
// Self-contained: a flat behavioral RAM on the SoC's external memory bus (the
// IP22 MC/HPC/SCC devices live in RTL now, so the external bus is pure memory),
// a minimal big-endian ELF32 loader for the IRIX /unix kernel, the ARCS System
// Parameter Block blob at physical 0x1000, and the core's resume handshake.
// Console output (SCC UART + core putchar, merged in henry_soc) drains to stdout.
//
//   ./henry_tb --kernel <unix.elf> [--arcs <blob>] [--maxcyc N]
// -----------------------------------------------------------------------------
#include "Vhenry_soc.h"
#include "Vhenry_soc__Dpi.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <string>
#include <vector>
#include <sys/mman.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>

static const uint64_t MEM_SIZE = 0x20000000ull;   // 512 MB physical window
static const uint64_t MEM_MASK = MEM_SIZE - 1;
static const uint32_t HALT_PA  = 0x1fd00000u;      // magic-halt register (BFD00000)

// ---- FPGA address map (bit-exact model of axi_is_the_worst_v1_0_M00_AXI.v sgi_mode) ----
// The FPGA's AXI DRAM master does NOT use a flat "& MEM_MASK"; it folds the IP22
// physical map into the 496 MB PS-DRAM and FAULTS (mem_rsp_bad) on anything past
// addrmask.  Mirror it exactly so the sim reproduces FPGA-only address behavior
// (the plain mask silently wraps out-of-range PAs in-range and hides such bugs).
// Knob: set false to fall back to the legacy flat 512 MB "& MEM_MASK" window.
static const bool     FPGA_ADDRESS_MAP = true;
static const uint32_t FPGA_ADDRMASK    = 0x1effffffu;  // 496 MB - 1 (FPGA DRAM size)

// cpuaddr is the 29-bit physical address the core presents to the AXI master.
// Returns the DRAM byte offset (baseaddr=0 in sim); *bad mirrors w_bad_addr.
static inline uint32_t fpga_map(uint32_t cpuaddr, bool *bad) {
  uint32_t t;
  if(cpuaddr >= 0x08000000u && cpuaddr <= 0x17ffffffu)
    t = cpuaddr & 0x0fffffffu;                  // {4'd0, cpuaddr[27:0]}  256 MB Low Local Mem
  else if(cpuaddr >= 0x1f000000u && cpuaddr <= 0x1fffffffu)
    t = 0x10000000u | (cpuaddr & 0x00ffffffu);  // {8'd16,cpuaddr[23:0]}  16 MB device/PROM shadow
  else
    t = cpuaddr;                                // identity
  *bad = (t > FPGA_ADDRMASK);
  return t;
}

static uint8_t *g_mem = nullptr;

// ---- core instrumentation/co-sim DPI hooks: stubbed (RTL-only run) ----
// Declared extern "C" via Vhenry_soc__Dpi.h above, so these definitions get C
// linkage and satisfy the core's import "DPI-C" references.
int  check_insn_bytes(long long, int) { return 1; }          // skip golden-mem check
void record_alloc(int,int,int,int,int,int,int,int,int) {}
void record_branches(int) {}
void record_ds_restart(int) {}
void record_faults(int) {}
void record_fetch(int,int,int,int,long long,long long,long long,long long,int,int) {}
void record_l1d(int,int,int,int,int) {}
void record_restart(int) {}
void record_retirement(long long,long long,long long,long long,long long,int,int,int,int) {}
void report_exec(int,int,int,int,int,int,int,int,int,int,int) {}

static inline uint32_t be32(const uint8_t *p) {
  return (uint32_t(p[0])<<24)|(uint32_t(p[1])<<16)|(uint32_t(p[2])<<8)|uint32_t(p[3]);
}
static inline uint16_t be16(const uint8_t *p) { return (uint16_t(p[0])<<8)|uint16_t(p[1]); }

// Load a big-endian ELF32 (MIPS) kernel; return the entry point (vaddr).
static uint32_t load_elf_be32(const char *path) {
  int fd = open(path, O_RDONLY);
  if(fd < 0) { fprintf(stderr, "cannot open kernel %s\n", path); exit(1); }
  struct stat st; fstat(fd, &st);
  uint8_t *f = (uint8_t*)mmap(nullptr, st.st_size, PROT_READ, MAP_PRIVATE, fd, 0);
  if(f == MAP_FAILED) { perror("mmap kernel"); exit(1); }

  if(!(f[0]==0x7f && f[1]=='E' && f[2]=='L' && f[3]=='F')) {
    fprintf(stderr, "not an ELF: %s\n", path); exit(1);
  }
  if(f[4] != 1 /*ELFCLASS32*/ || f[5] != 2 /*ELFDATA2MSB*/) {
    fprintf(stderr, "expected big-endian ELF32\n"); exit(1);
  }
  uint32_t e_entry     = be32(f + 24);
  uint32_t e_phoff     = be32(f + 28);
  uint16_t e_phentsize = be16(f + 42);
  uint16_t e_phnum     = be16(f + 44);

  for(uint16_t i = 0; i < e_phnum; i++) {
    const uint8_t *ph = f + e_phoff + (uint32_t)i * e_phentsize;
    uint32_t p_type   = be32(ph + 0);
    uint32_t p_offset = be32(ph + 4);
    uint32_t p_paddr  = be32(ph + 12);
    uint32_t p_filesz = be32(ph + 16);
    uint32_t p_memsz  = be32(ph + 20);
    if(p_type != 1 /*PT_LOAD*/) continue;
    uint32_t pa = (uint32_t)((uint64_t)p_paddr & 0x1fffffffull);   // kseg -> physical
    // Mirror the core->memory path henry_soc applies, so a segment lands where the
    // core will actually fetch it: (1) IP22 System Memory Alias -- the low 512 KB
    // alias up into Low Local Mem @ 0x08000000 (set bit27); (2) the FPGA address map.
    // For IRIX (segments at 0x08xxxxxx) both are identity, so this is a no-op there.
    uint32_t ca = ((pa >> 19) == 0) ? (pa | 0x08000000u) : pa;
    bool b = false; uint32_t off = fpga_map(ca, &b);
    if(b || off + p_memsz > MEM_SIZE) { fprintf(stderr, "segment out of RAM\n"); exit(1); }
    memcpy(g_mem + off, f + p_offset, p_filesz);          // .bss already zero
    printf("loaded segment: pa 0x%08x -> dram off 0x%08x  filesz 0x%x  memsz 0x%x\n",
           pa, off, p_filesz, p_memsz);
  }
  munmap(f, st.st_size);
  close(fd);
  printf("kernel entry 0x%08x\n", e_entry);
  return e_entry;
}

static void load_blob(const char *path, uint64_t pa) {
  int fd = open(path, O_RDONLY);
  if(fd < 0) { fprintf(stderr, "cannot open %s\n", path); exit(1); }
  struct stat st; fstat(fd, &st);
  uint8_t *f = (uint8_t*)mmap(nullptr, st.st_size, PROT_READ, MAP_PRIVATE, fd, 0);
  // place at the DRAM offset the core will actually read (the FSBL lives in the
  // PROM region, which the address map shadows into DRAM @ 0x10c00000).
  bool bad = false; uint32_t off = fpga_map((uint32_t)pa, &bad);
  memcpy(g_mem + off, f, st.st_size);
  printf("loaded ARCS firmware (%lld bytes) at physical 0x%llx (dram off 0x%x)\n",
         (long long)st.st_size, (unsigned long long)pa, off);
  munmap(f, st.st_size);
  close(fd);
}

// dump 8 big-endian words from a physical address (post-run page-table inspection)
static void dump_pa(uint64_t pa) {
  pa &= MEM_MASK;
  fprintf(stderr, "[dump] PA 0x%08llx:", (unsigned long long)pa);
  for(int i = 0; i < 8; i++) {
    uint64_t a = (pa + 4*i) & MEM_MASK;
    uint32_t w = ((uint32_t)g_mem[a]<<24)|((uint32_t)g_mem[a+1]<<16)|
                 ((uint32_t)g_mem[a+2]<<8)|(uint32_t)g_mem[a+3];   // big-endian
    fprintf(stderr, " %08x", w);
  }
  fprintf(stderr, "\n");
}

static void put_be32(uint64_t pa, uint32_t w) {
  pa &= MEM_MASK;
  g_mem[pa]   = (w>>24)&0xff; g_mem[pa+1] = (w>>16)&0xff;
  g_mem[pa+2] = (w>>8)&0xff;  g_mem[pa+3] = w&0xff;
}

// Synthesize the ARCS/sash -> /unix handoff (MAME_QUESTIONS.md Q5): lay out
// argv/envp in high RAM and a tiny bootstrap stub that sets a0=argc, a1=argv,
// a2=envp and jumps to the kernel entry.  Returns the stub's kseg0 entry PC.
// (An RTL core can't have its GPRs injected directly, so a code stub does it.)
static uint32_t install_arcs_handoff(uint32_t kentry) {
  static const char *argv_strs[] = {
    "scsi(0)disk(1)rdisk(0)partition(0)/unix", "OSLoadOptions=auto",
    "ConsoleIn=serial(0)", "ConsoleOut=serial(0)",
    "SystemPartition=scsi(0)disk(1)rdisk(0)partition(8)", "OSLoader=sash",
    "OSLoadPartition=scsi(0)disk(1)rdisk(0)partition(0)", "OSLoadFilename=/unix",
  };
  static const char *envp_strs[] = {
    "AutoLoad=Yes","TimeZone=PST8PDT","console=d","diskless=0","dbaud=9600",
    "volume=80","sgilogo=y","autopower=y","eaddr=08:01:02:03:04:05",
    "ConsoleOut=serial(0)","ConsoleIn=serial(0)","cpufreq=100",
    "SystemPartition=scsi(0)disk(1)rdisk(0)partition(8)",
    "OSLoadPartition=scsi(0)disk(1)rdisk(0)partition(0)",
    "OSLoadFilename=/unix","OSLoader=sash",
    "kernname=scsi(0)disk(1)rdisk(0)partition(0)/unix", nullptr,
  };
  const uint32_t K = 0x80000000u;          // kseg0 bit (PA -> kseg0 VA)
  const uint32_t STUB_PA = 0x08ff0000u;    // top of 16 MB RAM (MAME uses 0x08fffxxx)
  uint32_t argv_arr = 0x08ff0100u, envp_arr = 0x08ff0400u, str_pa = 0x08ff1000u;
  uint32_t nargc = sizeof(argv_strs)/sizeof(argv_strs[0]);

  for(uint32_t i = 0; i < nargc; i++) {
    memcpy(g_mem + str_pa, argv_strs[i], strlen(argv_strs[i]) + 1);
    put_be32(argv_arr + 4*i, K | str_pa);
    str_pa = (str_pa + strlen(argv_strs[i]) + 1 + 3) & ~3u;
  }
  put_be32(argv_arr + 4*nargc, 0);
  uint32_t e = 0;
  for(; envp_strs[e]; e++) {
    memcpy(g_mem + str_pa, envp_strs[e], strlen(envp_strs[e]) + 1);
    put_be32(envp_arr + 4*e, K | str_pa);
    str_pa = (str_pa + strlen(envp_strs[e]) + 1 + 3) & ~3u;
  }
  put_be32(envp_arr + 4*e, 0);

  uint32_t av = K | argv_arr, ev = K | envp_arr, p = STUB_PA;
  put_be32(p, 0x34040000u | nargc);            p+=4; // ori a0,zero,argc
  put_be32(p, 0x3c050000u | (av>>16));         p+=4; // lui a1,hi(argv)
  put_be32(p, 0x34a50000u | (av&0xffff));      p+=4; // ori a1,a1,lo(argv)
  put_be32(p, 0x3c060000u | (ev>>16));         p+=4; // lui a2,hi(envp)
  put_be32(p, 0x34c60000u | (ev&0xffff));      p+=4; // ori a2,a2,lo(envp)
  put_be32(p, 0x3c010000u | (kentry>>16));     p+=4; // lui at,hi(kentry)
  put_be32(p, 0x34210000u | (kentry&0xffff));  p+=4; // ori at,at,lo(kentry)
  put_be32(p, 0x00200008u);                    p+=4; // jr at
  put_be32(p, 0x00000000u);                          // nop (delay slot)
  printf("ARCS handoff: argc=%u argv=0x%08x envp=0x%08x stub=0x%08x\n",
         nargc, av, ev, K | STUB_PA);
  return K | STUB_PA;
}

int main(int argc, char **argv) {
  std::string kernel, arcs;
  uint64_t max_cyc = 120000000ull;
  uint32_t start_pc = 0;   // fake-BIOS: start in the arcs boot stub (skip C++ handoff)
  std::vector<uint64_t> dump_pas;
  std::string trace_file;
  for(int i = 1; i < argc; i++) {
    std::string a = argv[i];
    if(a == "--kernel" && i+1 < argc)      kernel = argv[++i];
    else if(a == "--arcs" && i+1 < argc)   arcs   = argv[++i];
    else if(a == "--maxcyc" && i+1 < argc) max_cyc = strtoull(argv[++i], nullptr, 0);
    else if(a == "--start-pc" && i+1 < argc) start_pc = (uint32_t)strtoull(argv[++i], nullptr, 0);
    else if(a == "--dump" && i+1 < argc)   dump_pas.push_back(strtoull(argv[++i], nullptr, 0));
    else if(a == "--trace" && i+1 < argc)  trace_file = argv[++i];
  }
  if(kernel.empty()) { fprintf(stderr, "usage: %s --kernel <elf> [--arcs <blob>] [--maxcyc N]\n", argv[0]); return 1; }

  g_mem = (uint8_t*)mmap(nullptr, MEM_SIZE, PROT_READ|PROT_WRITE,
                         MAP_PRIVATE|MAP_ANONYMOUS|MAP_NORESERVE, -1, 0);
  if(g_mem == MAP_FAILED) { perror("mmap ram"); return 1; }

  uint32_t entry = load_elf_be32(kernel.c_str());
  uint32_t kentry = entry;                  // real kernel entry (trace starts here)
  if(!arcs.empty()) {
    load_blob(arcs.c_str(), 0x1fc00000);   // FSBL lives in the Boot PROM region
    // patch the FSBL kernel-entry slot @ phys 0x1fc00008 with the real ELF entry
    // (mirrors the mips-axi driver), so the FSBL jumps to the right place even
    // after a kernel rebuild shifts the entry off the baked-in default.
    { bool b=false; uint32_t soff = fpga_map(0x1fc00008u, &b); put_be32(soff, kentry);
      printf("patched FSBL kentry slot @0x1fc00008 (dram 0x%x) = 0x%08x\n", soff, kentry); }
    if(start_pc) { entry = start_pc; printf("fake-bios: start pc = %08x\n", start_pc); }
    else         entry = install_arcs_handoff(entry); // sash-style argv/envp handoff -> stub -> kernel
  }

  // retired-PC trace (for the MAME co-sim diff): one 32-bit vPC per line, in
  // retire order incl. delay slots, starting at the kernel entry (skip the stub).
  FILE *trace = nullptr;
  bool trace_started = false;
  if(!trace_file.empty()) {
    trace = fopen(trace_file.c_str(), "w");
    if(!trace) { perror("open trace"); return 1; }
  }

  setvbuf(stdout, nullptr, _IONBF, 0);   // unbuffered: banner appears promptly

  Verilated::commandArgs(argc, argv);
  Vhenry_soc *tb = new Vhenry_soc;

  auto tick = [&](void) { tb->clk = 1; tb->eval(); tb->clk = 0; tb->eval(); };

  // ---- reset ----
  tb->reset = 1; tb->resume = 0; tb->resume_pc = 0;
  tb->mem_rsp_valid = 0; tb->mem_rsp_bad = 0; tb->putchar_fifo_pop = 0;
  for(int i = 0; i < 4; i++) tick();

  // ---- launch the core at the kernel entry (mirrors r9999 top.cc) ----
  tb->resume_pc = (uint64_t)(int64_t)(int32_t)entry;
  tb->reset = 0; tick();
  while(!tb->ready_for_resume) tick();
  tb->resume = 1; tick();
  tb->resume = 0; tick();
  tb->resume = 1; tb->resume_pc = (uint64_t)(int64_t)(int32_t)entry; tick();
  tb->resume = 0; tick();

  // ---- run ----
  bool halted = false;
  int64_t reply_cyc = -1;
  uint64_t req_addr = 0; uint32_t req_op = 0; uint16_t req_mask = 0;
  uint32_t req_sd[4] = {0,0,0,0};
  bool req_bad = false, req_is_halt = false;
  const int MEM_LAT = 4;
  uint64_t retired = 0, last_pc = 0;
  uint64_t prev_epc = 0; int exc_prints = 0; uint32_t prev_sr = 0; uint64_t prev_badv = 0;

  // Loop mirrors r9999 top.cc phase ordering: posedge eval FIRST (core samples
  // the mem_rsp set last cycle), THEN read mem_req and present mem_rsp for the
  // next posedge, then negedge eval.
  for(uint64_t cyc = 0; cyc < max_cyc && !halted && !Verilated::gotFinish(); cyc++) {
    // drain the console (SCC UART + core putchar, merged on the putchar port):
    // decide pop from the settled pre-posedge state so the posedge-clocked FIFO
    // actually advances rptr (assert pop BEFORE the edge, print the popped head).
    bool drain   = !tb->putchar_fifo_empty;
    char drain_ch = (char)tb->putchar_fifo_out;
    tb->putchar_fifo_pop = drain ? 1 : 0;

    tb->clk = 1;
    tb->eval();                              // posedge (FIFO advances if pop)
    if(drain) putchar(drain_ch);

    if(tb->retire_valid) { retired++; last_pc = tb->retire_pc; }
    // 64-bit-address-bug probe: log every a0 (reg 4) writeback near the fault
    if(cyc > 35850000ull && cyc < 35870000ull) {
      if(tb->retire_valid && tb->retire_reg_ptr == 4)  // reg 4 = a0
        fprintf(stderr, "[a0wr] cyc=%llu pc=0x%llx a0=0x%016llx\n",
                (unsigned long long)cyc, (unsigned long long)tb->retire_pc,
                (unsigned long long)tb->retire_reg_data);
      if(tb->retire_two_valid && tb->retire_reg_two_ptr == 4)
        fprintf(stderr, "[a0wr2] cyc=%llu pc=0x%llx a0=0x%016llx\n",
                (unsigned long long)cyc, (unsigned long long)tb->retire_two_pc,
                (unsigned long long)tb->retire_reg_two_data);
    }

    // retired-PC trace (retire order: port 0 then port 1), gated to start at kentry.
    // Each line is "<vPC> <retire-cycle>" so a diff of two runs shows, at the
    // divergence, how many cycles the next instruction took to retire (stall length).
    if(trace) {
      if(tb->retire_valid) {
        uint32_t pc = (uint32_t)tb->retire_pc;
        if(!trace_started && pc == kentry) trace_started = true;
        if(trace_started) fprintf(trace, "%08x %llu\n", pc, (unsigned long long)cyc);
      }
      if(tb->retire_two_valid && trace_started)
        fprintf(trace, "%08x %llu\n", (uint32_t)tb->retire_two_pc, (unsigned long long)cyc);
    }

    // ---- memory bus servicing (mem_rsp sampled on the NEXT posedge) ----
    tb->mem_rsp_valid = 0;
    tb->mem_rsp_bad   = 0;
    if(tb->mem_req_valid && reply_cyc == -1) {
      uint32_t phys = (uint32_t)tb->mem_req_addr & 0x1fffffffu;  // 29-bit phys to the AXI master
      req_is_halt = (phys == HALT_PA);
      if(FPGA_ADDRESS_MAP) {
        req_addr = fpga_map(phys, &req_bad);
        if(req_bad)
          fprintf(stderr, "[bad_addr] cyc=%lu phys=0x%08x op=%u mask=0x%x  (FPGA mem_rsp_bad)\n",
                  (unsigned long)cyc, phys,
                  (unsigned)tb->mem_req_opcode, (unsigned)tb->mem_req_mask);
      } else {
        req_addr = (uint64_t)tb->mem_req_addr & MEM_MASK;
        req_bad  = false;
      }
      req_op   = tb->mem_req_opcode;
      req_mask = tb->mem_req_mask;
      for(int i = 0; i < 4; i++) req_sd[i] = tb->mem_req_store_data[i];
      reply_cyc = (int64_t)cyc + ((req_op == 4) ? MEM_LAT : 2*MEM_LAT);
    }
    if(reply_cyc == (int64_t)cyc) {
      if(req_bad) {
        // FPGA M00_AXI faults (mem_rsp_bad) on addr past addrmask -- no memory effect.
        tb->mem_rsp_bad = 1;
      }
      else if(req_op == 4) {                  // line load
        for(int i = 0; i < 4; i++) {
          uint64_t a = (req_addr + 4*i) & MEM_MASK;
          tb->mem_rsp_load_data[i] =
            (uint32_t)g_mem[a] | ((uint32_t)g_mem[a+1]<<8) |
            ((uint32_t)g_mem[a+2]<<16) | ((uint32_t)g_mem[a+3]<<24);
        }
      }
      else if(req_op == 7) {                  // store (byte mask) -- ONLY opcode 7
        for(int i = 0; i < 16; i++) {
          if((req_mask >> i) & 1) {
            uint64_t a = (req_addr + i) & MEM_MASK;
            uint8_t  by = (req_sd[i>>2] >> (8*(i&3))) & 0xff;
            if(req_is_halt && by)
              halted = true;
            g_mem[a] = by;
          }
        }
      }
      // any other opcode (uncached/special): respond, no memory effect
      tb->mem_rsp_valid = 1;
      reply_cyc = -1;
    }

    tb->clk = 0;
    tb->eval();                              // negedge

    if((tb->badvaddr != prev_badv || tb->epc != prev_epc) && exc_prints < 120) {
      unsigned pre_exl = (prev_sr >> 1) & 1;
      fprintf(stderr, "[exc %d] cyc %llu  cause=%u  epc=0x%llx  badv=0x%llx  pre_EXL=%u  lastpc=0x%llx\n",
              exc_prints, (unsigned long long)cyc, (unsigned)tb->cause,
              (unsigned long long)tb->epc, (unsigned long long)tb->badvaddr,
              pre_exl, (unsigned long long)last_pc);
      prev_epc = tb->epc; prev_badv = tb->badvaddr; exc_prints++;
    }
    prev_sr = tb->status_reg;
    if(cyc && (cyc % 5000000) == 0)
      fprintf(stderr, "[tb] cyc %llu  retired %llu  last_pc 0x%llx  head_pc 0x%llx  "
              "cause=%u epc=0x%llx badv=0x%llx sr=0x%08x irq=%u\n",
              (unsigned long long)cyc, (unsigned long long)retired,
              (unsigned long long)last_pc, (unsigned long long)tb->dbg_head_pc,
              (unsigned)tb->cause, (unsigned long long)tb->epc,
              (unsigned long long)tb->badvaddr, (unsigned)tb->status_reg, (unsigned)tb->took_irq);
    if(tb->got_bad_addr) { printf("\n[tb] got_bad_addr at cycle %llu\n", (unsigned long long)cyc); }
  }

  fprintf(stderr, "[tb] final: retired %llu  last_pc 0x%llx  head_pc 0x%llx  "
          "cause=%u epc=0x%llx badv=0x%llx sr=0x%08x irq=%u\n",
          (unsigned long long)retired, (unsigned long long)last_pc,
          (unsigned long long)tb->dbg_head_pc, (unsigned)tb->cause,
          (unsigned long long)tb->epc, (unsigned long long)tb->badvaddr,
          (unsigned)tb->status_reg, (unsigned)tb->took_irq);
  printf("\n[tb] %s\n", halted ? "halted (magic-halt store)" : "reached max cycles");
  for(uint64_t pa : dump_pas) dump_pa(pa);
  if(trace) { fclose(trace); fprintf(stderr, "[tb] wrote retired-PC trace to %s\n", trace_file.c_str()); }
  delete tb;
  return 0;
}
