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
#include <sys/mman.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>

static const uint64_t MEM_SIZE = 0x20000000ull;   // 512 MB physical window
static const uint64_t MEM_MASK = MEM_SIZE - 1;
static const uint32_t HALT_PA  = 0x1fd00000u;      // magic-halt register (BFD00000)

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
    uint64_t pa = (uint64_t)p_paddr & 0x1fffffffull;     // kseg -> physical
    if(pa + p_memsz > MEM_SIZE) { fprintf(stderr, "segment out of RAM\n"); exit(1); }
    memcpy(g_mem + pa, f + p_offset, p_filesz);          // .bss already zero
    printf("loaded segment: pa 0x%08llx  filesz 0x%x  memsz 0x%x\n",
           (unsigned long long)pa, p_filesz, p_memsz);
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
  memcpy(g_mem + (pa & MEM_MASK), f, st.st_size);
  printf("loaded ARCS firmware (%lld bytes) at physical 0x%llx\n",
         (long long)st.st_size, (unsigned long long)pa);
  munmap(f, st.st_size);
  close(fd);
}

int main(int argc, char **argv) {
  std::string kernel, arcs;
  uint64_t max_cyc = 120000000ull;
  for(int i = 1; i < argc; i++) {
    std::string a = argv[i];
    if(a == "--kernel" && i+1 < argc)      kernel = argv[++i];
    else if(a == "--arcs" && i+1 < argc)   arcs   = argv[++i];
    else if(a == "--maxcyc" && i+1 < argc) max_cyc = strtoull(argv[++i], nullptr, 0);
  }
  if(kernel.empty()) { fprintf(stderr, "usage: %s --kernel <elf> [--arcs <blob>] [--maxcyc N]\n", argv[0]); return 1; }

  g_mem = (uint8_t*)mmap(nullptr, MEM_SIZE, PROT_READ|PROT_WRITE,
                         MAP_PRIVATE|MAP_ANONYMOUS|MAP_NORESERVE, -1, 0);
  if(g_mem == MAP_FAILED) { perror("mmap ram"); return 1; }

  uint32_t entry = load_elf_be32(kernel.c_str());
  if(!arcs.empty()) load_blob(arcs.c_str(), 0x1000);

  setvbuf(stdout, nullptr, _IONBF, 0);   // unbuffered: banner appears promptly

  Verilated::commandArgs(argc, argv);
  Vhenry_soc *tb = new Vhenry_soc;

  auto tick = [&](void) { tb->clk = 1; tb->eval(); tb->clk = 0; tb->eval(); };

  // ---- reset ----
  tb->reset = 1; tb->extern_irq = 0; tb->resume = 0; tb->resume_pc = 0;
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
  const int MEM_LAT = 4;
  uint64_t retired = 0, last_pc = 0;
  uint64_t prev_epc = 0; int exc_prints = 0;

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

    // ---- memory bus servicing (mem_rsp sampled on the NEXT posedge) ----
    tb->mem_rsp_valid = 0;
    if(tb->mem_req_valid && reply_cyc == -1) {
      req_addr = (uint64_t)tb->mem_req_addr & MEM_MASK;
      req_op   = tb->mem_req_opcode;
      req_mask = tb->mem_req_mask;
      for(int i = 0; i < 4; i++) req_sd[i] = tb->mem_req_store_data[i];
      reply_cyc = (int64_t)cyc + ((req_op == 4) ? MEM_LAT : 2*MEM_LAT);
    }
    if(reply_cyc == (int64_t)cyc) {
      if(req_op == 4) {                       // line load
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
            if((uint32_t)(a & 0x1fffffffu) == (HALT_PA & 0x1fffffffu) && by)
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

    if(tb->epc != prev_epc && exc_prints < 40) {
      fprintf(stderr, "[exc %d] cyc %llu  cause=%u  epc=0x%llx  badv=0x%llx  sr=0x%08x  irq=%u\n",
              exc_prints, (unsigned long long)cyc, (unsigned)tb->cause,
              (unsigned long long)tb->epc, (unsigned long long)tb->badvaddr,
              (unsigned)tb->status_reg, (unsigned)tb->took_irq);
      prev_epc = tb->epc; exc_prints++;
    }
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
  delete tb;
  return 0;
}
