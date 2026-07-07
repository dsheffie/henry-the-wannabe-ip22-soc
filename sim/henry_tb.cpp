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
#include "scsi_service.h"   // host-side SCSI disk service (henry_scsi.h contract)
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/socket.h>
#include <netinet/in.h>

// ---- lockstep co-sim checker: r9999's embedded interp as the golden model ----
#include "interpret.hh"
#include "loadelf.hh"
// The interp objects reference these globals (defined in r9999/top.cc, which we
// don't link); provide them here so the ISS objects resolve.
namespace globals {
  bool     enClockFuncts   = false;
  uint64_t icountMIPS      = 0;
  uint64_t cycle           = 0;
  bool     trace_retirement= false;
  bool     trace_fp        = false;
  bool     report_syscalls = false;
};
static sparse_mem *g_ss_mem   = nullptr;   // golden ISS memory (own 4GB, PA-indexed)
static state_t    *ss         = nullptr;   // golden checker state
static bool        g_checker  = false;     // --checker enables the lockstep compare
static const bool  g_go_a0_trace = getenv("GO_A0_TRACE") != nullptr; // diagnostic a0-corruption window trace
static uint64_t    g_chk_insns = 0;        // instructions checked

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

// timer-IRQ trace: core.sv calls log_timer_irq() (DPI) once per timer interrupt
// taken; we stamp it with the current sim cycle.  Queryable via monitor `timer`.
static uint64_t g_cur_cyc = 0;                 // updated each loop iteration
static std::vector<uint64_t> g_timer_irq_cyc;  // cycle of every timer IRQ taken
extern "C" void log_timer_irq() { g_timer_irq_cyc.push_back(g_cur_cyc); }

// ---- SCSI disk service (scsi_shim.sv mailbox; active only with `ENABLE_SCSI_SHIM + --disk) ----
// Poll the doorbell (scsi_req_seq change), walk the descriptor chain in g_mem, do
// the disk I/O, post the completion. The accessor applies the SAME FPGA address
// map as the AXI master so descriptor BP/nbdp (guest physical) index g_mem right.
static scsi_disk g_scsi_disk;
static uint32_t  g_last_scsi_req_seq = 0;
static uint8_t *scsi_mem(void * /*ctx*/, uint32_t phys, uint32_t len) {
  bool bad = false;
  uint32_t off = FPGA_ADDRESS_MAP ? fpga_map(phys, &bad) : (uint32_t)(phys & MEM_MASK);
  if(bad || (uint64_t)off + len > MEM_SIZE) return nullptr;
  return g_mem + off;
}

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

// ===========================================================================
//  Checkpoint resume: load a full-state checkpoint (from interp_mips
//  --checkpoint-at) into g_mem + a global state, and seed the RTL register
//  files / TLB / control regs at reset via these DPI functions (loadgpr etc.),
//  then resume the core at the checkpoint PC. Binary layout MUST match
//  interp_mips/saveState.cc.
// ===========================================================================
struct cp_tlb { uint64_t entry_hi, entry_lo0, entry_lo1; uint32_t page_mask, _pad; } __attribute__((packed));
struct cp_header {
  uint64_t magic; int64_t pc; int64_t gpr[32]; int64_t hi; int64_t lo;
  uint32_t cpr0[32]; uint64_t cpr0_64[32]; uint64_t cpr1[32]; uint32_t fcr1[5];
  cp_tlb tlb[48]; uint64_t icnt; uint32_t num_pages;
} __attribute__((packed));
struct cp_page { uint32_t va; uint8_t data[4096]; } __attribute__((packed));
static const uint64_t CKPT_MAGIC = 0x6d697073f5f5d005ULL;

static cp_header g_ckpt;
static bool g_have_ckpt = false;

// fwd: fpga_map is defined above; pages are physical -> map to g_mem offset.
static void load_checkpoint(const char *path) {
  FILE *f = fopen(path, "rb");
  if(!f) { fprintf(stderr, "cannot open checkpoint %s\n", path); exit(1); }
  if(fread(&g_ckpt, 1, sizeof(g_ckpt), f) != sizeof(g_ckpt) || g_ckpt.magic != CKPT_MAGIC) {
    fprintf(stderr, "bad checkpoint %s\n", path); exit(1);
  }
  for(uint32_t i = 0; i < g_ckpt.num_pages; i++) {
    cp_page p;
    if(fread(&p, 1, sizeof(p), f) != sizeof(p)) { fprintf(stderr, "short checkpoint\n"); exit(1); }
    bool bad = false; uint32_t off = fpga_map(p.va, &bad);
    if(!bad) memcpy(g_mem + off, p.data, 4096);
    if(ss) memcpy(ss->mem.get_raw_ptr(p.va), p.data, 4096);  // golden ISS: PA-indexed
  }
  fclose(f);
  g_have_ckpt = true;
  fprintf(stderr, "[ckpt] loaded %s: pc=%08x, %u pages, icnt=%llu\n",
          path, (uint32_t)g_ckpt.pc, g_ckpt.num_pages, (unsigned long long)g_ckpt.icnt);
}

// DPI seeds consumed by rf4r2w / fp_regfile (and, once added, exec/tlb) at reset.
extern "C" long long loadgpr(int regid)  { return g_have_ckpt ? g_ckpt.gpr[regid & 31] : 0; }
extern "C" long long loadfpr(int regid)  { return g_have_ckpt ? (long long)g_ckpt.cpr1[regid & 31] : 0; }
extern "C" int       have_checkpoint()   { return g_have_ckpt ? 1 : 0; }
extern "C" int       loadcp0(int reg)    { return g_have_ckpt ? (int)g_ckpt.cpr0[reg & 31] : 0; }
extern "C" long long loadcp0_64(int reg) { return g_have_ckpt ? (long long)g_ckpt.cpr0_64[reg & 31] : 0; }
extern "C" long long loadhilo(int half)  { return g_have_ckpt ? (half ? g_ckpt.hi : g_ckpt.lo) : 0; }
extern "C" int       loadfcsr()          { return g_have_ckpt ? (int)g_ckpt.fcr1[4] : 0; } /* FCR31 = fcr1[4] */
// A/B DIAG (go stale-a0): RTL calls this at the mem-execute stage. g_probe_cyc is
// updated by the main loop. GO_A0_TRACE-gated so it is inert unless armed.
uint64_t g_probe_cyc = 0;
extern "C" void dpi_a0_probe(int pc, int is_store, int phys, long long val) {
  if(!g_go_a0_trace) return;
  // is_store: 0=restore-load dst(Pd), 1=store srcA(Ps), 2=int-PRF load writeback.
  // Writebacks flood, so window them to the faulting-replay cycles.
  if(is_store == 2 && !(g_probe_cyc >= 21123000ull && g_probe_cyc <= 21124300ull)) return;
  const char *tag = is_store == 1 ? "STORE-srcA(Ps)" : is_store == 0 ? "LOAD-dst(Pd)  " : "PRF-WB        ";
  fprintf(stderr, "[a0dpi] cyc=%llu pc=%08x %s phys=%d val=%016llx\n",
          (unsigned long long)g_probe_cyc, (unsigned)pc, tag, phys,
          (unsigned long long)val);
}
// A/B DIAG: read committed DRAM (g_mem) at a PA, big-endian 64b, to split
// SAVE-LOST (DRAM==0) from LOAD-MISREAD (DRAM==0x1200fa608 but load returned 0).
extern "C" void dpi_mem_at(long long vaddr, long long pa, long long stdata, int is_store) {
  if(!g_go_a0_trace) return;
  uint32_t phys = (uint32_t)((uint64_t)pa & 0x1fffffffull);
  bool bad = false;
  uint32_t off = FPGA_ADDRESS_MAP ? fpga_map(phys, &bad) : (uint32_t)(phys & MEM_MASK);
  uint64_t v = 0; int okmem = (!bad && (uint64_t)off + 8 <= MEM_SIZE);
  if(okmem) { for(int i = 0; i < 8; i++) { v = (v << 8) | g_mem[off + i]; } }
  if(is_store)
    fprintf(stderr, "[a0mem] cyc=%llu SAVE-store vaddr=%016llx pa=%08x stdata=%016llx dram_before=%016llx bad=%d\n",
            (unsigned long long)g_probe_cyc, (unsigned long long)vaddr, phys,
            (unsigned long long)stdata, (unsigned long long)v, bad);
  else
    fprintf(stderr, "[a0mem] cyc=%llu RESTORE-load vaddr=%016llx pa=%08x DRAM64=%016llx bad=%d\n",
            (unsigned long long)g_probe_cyc, (unsigned long long)vaddr, phys,
            (unsigned long long)v, bad);
}
extern "C" long long loadtlb(int entry, int field) {  /* 0=hi 1=lo0 2=lo1 3=pagemask */
  if(!g_have_ckpt) return 0;
  const cp_tlb &t = g_ckpt.tlb[entry % 48];
  switch(field & 3) { case 0: return (long long)t.entry_hi;  case 1: return (long long)t.entry_lo0;
                      case 2: return (long long)t.entry_lo1; default: return (long long)t.page_mask; }
}

// ---------------------------------------------------------------------------
// Lockstep co-sim checker (mirrors r9999/top.cc): seed the golden ISS from the
// checkpoint, then on each RTL retire step the ISS and compare the retired reg.
// ---------------------------------------------------------------------------
static void seed_checker() {
  if(!ss || !g_have_ckpt) return;
  ss->pc = (state_t::reg_t)g_ckpt.pc;
  ss->hi = (state_t::reg_t)g_ckpt.hi;  ss->lo = (state_t::reg_t)g_ckpt.lo;
  for(int i = 0; i < 32; i++) {
    ss->gpr[i]     = (state_t::reg_t)g_ckpt.gpr[i];
    ss->cpr0[i]    = g_ckpt.cpr0[i];
    ss->cpr0_64[i] = g_ckpt.cpr0_64[i];
    ss->cpr1[i]    = g_ckpt.cpr1[i];
  }
  for(int i = 0; i < 5; i++) ss->fcr1[i] = g_ckpt.fcr1[i];
  for(int i = 0; i < 48 && i < (int)(sizeof(ss->tlb)/sizeof(ss->tlb[0])); i++) {
    ss->tlb[i].entry_hi  = g_ckpt.tlb[i].entry_hi;
    ss->tlb[i].entry_lo0 = g_ckpt.tlb[i].entry_lo0;
    ss->tlb[i].entry_lo1 = g_ckpt.tlb[i].entry_lo1;
    ss->tlb[i].page_mask = g_ckpt.tlb[i].page_mask;
  }
  fprintf(stderr, "[checker] golden ISS seeded at pc=%08x\n", (uint32_t)ss->pc);
}

static uint64_t g_chk_diverge = 0, g_chk_copsupp = 0, g_chk_resync = 0, g_chk_mapped = 0;
static bool     g_expect_ds = false;   // next retire is a branch's delay slot
static uint32_t g_ds_pc     = 0;
static int      g_settle    = 0;       // suppress compares while ISS state re-converges after a resync

// A diverging retired reg is a known ISS-fidelity gap to trust silently if it is
// k0/k1 (kernel exception scratch) or a coprocessor read (mfc0/dmfc0/cfc1/mfc2/
// ... read CP0/CP1/CP2 bits the 1:1 ISS doesn't model bit-for-bit: CU2, Cause).
static bool chk_suppress(uint32_t vpc, int rrp) {
  if(rrp == 26 || rrp == 27) return true;
  // dosample (i8254 PIT calibration, 0x880045ac..): lbu of the free-running PIT
  // counter -- the 1:1 ISS models no PIT so it reads a constant while the RTL
  // reads the real count. Known-benign timing-dependent device read.
  if(vpc >= 0x880045acu && vpc <= 0x88004650u) return true;
  if(vpc >= 0x80000000u && vpc < 0xc0000000u) {
    uint8_t *p = ss->mem.get_raw_ptr(vpc & 0x1fffffffu);
    uint32_t insn = (uint32_t(p[0])<<24)|(uint32_t(p[1])<<16)|(uint32_t(p[2])<<8)|uint32_t(p[3]);
    uint32_t op = insn >> 26, rs = (insn >> 21) & 0x1f, funct = insn & 0x3f;
    if((op == 0x10 || op == 0x11 || op == 0x12) && rs <= 2) return true;
    // mfhi/mflo: HI/LO isn't retire-exposed so the ISS can't trust-sync it, and
    // it drifts across mapped-userspace mults we skip.  Not a pointer/data path.
    if(op == 0 && (funct == 0x10 || funct == 0x12)) return true;
  }
  return false;
}

// True if the retiring insn is a load whose effective address is IP22 device /
// PROM space or kseg1 uncached -- the 1:1 ISS models no devices there (reads 0),
// so trust the RTL.  MUST be called BEFORE execMips so ss->gpr[base] is the
// pre-load value (covers the rt==base form, e.g. lw a4,off(a4)).
static bool is_device_load(uint32_t vpc) {
  if(vpc < 0x80000000u || vpc >= 0xc0000000u) return false;
  uint8_t *p = ss->mem.get_raw_ptr(vpc & 0x1fffffffu);
  uint32_t insn = (uint32_t(p[0])<<24)|(uint32_t(p[1])<<16)|(uint32_t(p[2])<<8)|uint32_t(p[3]);
  uint32_t op = insn >> 26, rs = (insn >> 21) & 0x1f;
  bool is_load = (op >= 0x20 && op <= 0x27) || op == 0x1a || op == 0x1b || op == 0x37;
  if(!is_load) return false;
  uint32_t ea = (uint32_t)((int64_t)ss->gpr[rs] + (int16_t)(insn & 0xffff));
  uint32_t pa = (ea >= 0x80000000u) ? (ea & 0x1fffffffu) : ea;
  return (pa >= 0x1f000000u) || (ea >= 0xa0000000u && ea < 0xc0000000u);
}

// Compare the ISS's architected result for a retired insn against the RTL, then
// trust the RTL value (keeps the ISS locked; also covers device-MMIO loads).
static void chk_compare(uint32_t vpc, bool rrv, int rrp, uint64_t rrd, bool devload) {
  if(!rrv || rrp == 0) return;
  if((uint64_t)ss->gpr[rrp] != rrd) {
    if(g_settle > 0 || devload || chk_suppress(vpc, rrp)) g_chk_copsupp++;
    else {
      if(g_chk_diverge < 200)
        fprintf(stderr, "[checker] DIVERGE @pc=%08x r%d: ISS=%016llx RTL=%016llx (chk#%llu)\n",
                vpc, rrp, (unsigned long long)ss->gpr[rrp], (unsigned long long)rrd,
                (unsigned long long)g_chk_insns);
      g_chk_diverge++;
    }
  }
  ss->gpr[rrp] = (state_t::reg_t)rrd;
}

// Advance the golden ISS by one RTL retirement, staying locked to the RTL.  The
// ISS runs a branch + its delay slot atomically inside one execMips, so when the
// RTL retires that delay slot separately we CONSUME it (compare + trust) instead
// of re-executing.  A genuine control-flow desync re-syncs onto the RTL pc so the
// harness keeps tracking a full OS boot rather than stalling.
static void checker_step(uint64_t rpc, bool rrv, int rrp, uint64_t rrd) {
  if(!ss || ss->brk) return;
  uint32_t vpc = (uint32_t)rpc;
  if(g_expect_ds && vpc == g_ds_pc) {        // delay slot the ISS already executed
    g_expect_ds = false;
    chk_compare(vpc, rrv, rrp, rrd, is_device_load(vpc));  // best-effort (post-exec base)
    return;
  }
  g_expect_ds = false;
  // Mapped execution (user / TLB-translated, pc outside kseg0/kseg1): the 1:1
  // va2pa ISS reads the wrong physical memory, so it cannot validly execute it.
  // Trust the RTL wholesale (no check) and keep the register file synced; the
  // ISS resumes checking when the RTL returns to kseg0 (where bad istack lives).
  if(vpc < 0x80000000u || vpc >= 0xc0000000u) {
    ss->pc = (state_t::reg_t)(int64_t)rpc;
    if(rrv && rrp != 0) ss->gpr[rrp] = (state_t::reg_t)rrd;
    g_chk_mapped++;
    return;
  }
  bool resynced = false;
  if((uint32_t)ss->pc != vpc) {              // control-flow (PC) divergence
    // Classify. An exception-vector target = the RTL took an exception the 1:1 ISS
    // doesn't model (async timer IRQ; or a TLB/AdEL it can't see) -- usually benign.
    // A MAIN-LINE divergence (both in normal code, different PC) = a real wrong-PC
    // bug: bad eret target, mis-resolved branch, or a spurious/missed exception.
    bool exc_entry = (vpc==0x80000000u || vpc==0x80000080u || vpc==0x80000100u ||
                      vpc==0x80000180u || (vpc>=0xbfc00200u && vpc<=0xbfc00480u));
    static int shown = 0;
    if(shown < 200) {
      fprintf(stderr, "[checker] PC-DIVERGE ISS=%08x RTL=%08x %s after %llu checked\n",
              (uint32_t)ss->pc, vpc, exc_entry ? "[exc-entry]" : "[MAIN-LINE!]",
              (unsigned long long)g_chk_insns);
      shown++;
    }
    ss->pc = (state_t::reg_t)(int64_t)rpc;   // re-sync onto RTL control flow
    g_chk_resync++; resynced = true; g_settle = 16;  // let the reg file re-converge
  }
  if(g_settle > 0) g_settle--;
  bool devload = is_device_load(vpc);        // classify BEFORE execMips (pre-load base)
  uint32_t prev = (uint32_t)ss->pc;
  execMips(ss);
  g_chk_insns++;
  if((uint32_t)ss->pc != prev + 4) { g_expect_ds = true; g_ds_pc = prev + 4; }  // took a branch
  if(resynced) { if(rrv && rrp != 0) ss->gpr[rrp] = (state_t::reg_t)rrd; }  // trust only (state stale)
  else chk_compare(vpc, rrv, rrp, rrd, devload);
}

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
    // Seed the golden ISS too, so --checker works on a fresh --kernel boot (not
    // just --checkpoint). The 1:1 va2pa ISS reads at the RAW physical `pa`
    // (va & 0x1fffffff), NOT the fpga_map'd g_mem offset -- index ss->mem by pa.
    if(ss) memcpy(ss->mem.get_raw_ptr(pa), f + p_offset, p_filesz);
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
  // place at the DRAM offset the core will actually read. Mirror the full
  // core->memory path (System Memory Alias for low <512KB -> 0x08000000, then
  // fpga_map) just like load_elf_be32, so a stub-style arcs linked low (IRIX:
  // pa 0x1000, arcs_boot @ pa 0x3000) lands where the core fetches it, AND the
  // FSBL-style arcs at pa 0x1fc00000 still maps to the PROM shadow 0x10c00000.
  uint32_t cpa = ((((uint32_t)pa) >> 19) == 0) ? (((uint32_t)pa) | 0x08000000u) : (uint32_t)pa;
  bool bad = false; uint32_t off = fpga_map(cpa, &bad);
  memcpy(g_mem + off, f, st.st_size);
  if(ss) memcpy(ss->mem.get_raw_ptr((uint32_t)pa), f, st.st_size);  // golden ISS: raw physical
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

// ============================================================================
// TCP monitor: connect over a socket (env MONPORT, default 2323; enable with
// MON=1 or MONPORT=N) to inspect state and halt/step the sim.  Mirrors the
// on-board mips-axi mon.cc protocol -- raw TCP, Ctrl-] toggles console<->monitor
// -- so the same `mipsmon` client works.
//   commands: pc regs r<N> cp0 epc mem <hex> [n] state perf halt go step[N] help
// GPR/CP0 come from the lockstep ISS (`ss`) -> run with --checker for those;
// pc/mem/state/step/halt work without it.  Nothing changes unless a client
// connects (non-blocking accept polled from the main loop).
// ============================================================================
static int      g_mon_listen = -1, g_mon_client = -1;
static bool     g_mon_cmd_mode = true;    // true = commands, false = console passthrough
static bool     g_mon_paused   = false;   // halt: main loop freezes (polls, does not tick)
static uint64_t g_mon_step_to  = 0;       // step: run until `retired` reaches this, then pause
static char     g_mon_line[512];
static int      g_mon_len = 0;
static uint64_t g_mon_cyc = 0, g_mon_retired = 0, g_mon_last_pc = 0;  // snapshot from the loop

static void mon_send(const char *s) {
  if(g_mon_client >= 0) { ssize_t r = write(g_mon_client, s, strlen(s)); (void)r; }
}
static void mon_console_out(int c) {   // guest console byte -> client (console mode only)
  if(g_mon_client >= 0 && !g_mon_cmd_mode) { char b = (char)c; ssize_t r = write(g_mon_client, &b, 1); (void)r; }
}
static void mon_init(int port) {
  g_mon_listen = socket(AF_INET, SOCK_STREAM, 0);
  if(g_mon_listen < 0) return;
  int one = 1; setsockopt(g_mon_listen, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
  struct sockaddr_in a; memset(&a, 0, sizeof(a));
  a.sin_family = AF_INET; a.sin_addr.s_addr = INADDR_ANY; a.sin_port = htons((uint16_t)port);
  if(bind(g_mon_listen, (struct sockaddr*)&a, sizeof(a)) < 0) { close(g_mon_listen); g_mon_listen = -1; return; }
  listen(g_mon_listen, 1);
  fcntl(g_mon_listen, F_SETFL, fcntl(g_mon_listen, F_GETFL, 0) | O_NONBLOCK);
  fprintf(stderr, "[mon] henry_tb monitor on tcp:%d (connect: `nc localhost %d`)\n", port, port);
}
// read a 32-bit word the way the RTL AXI master does (kseg->phys, then fpga_map)
static bool mon_mem_rd(uint32_t va, uint32_t *out) {
  uint32_t phys = (va >= 0x80000000u && va < 0xc0000000u) ? (va & 0x1fffffffu) : va;
  bool bad = false; uint32_t off = fpga_map(phys, &bad);
  if(bad || (uint64_t)off + 4 > MEM_SIZE) return false;
  *out = ((uint32_t)g_mem[off]<<24)|((uint32_t)g_mem[off+1]<<16)|((uint32_t)g_mem[off+2]<<8)|g_mem[off+3];
  return true;
}
static const char *g_mon_help =
  "pc regs r<N> cp0 epc mem <hex> [n] state perf timer[N] halt go step[N] help   (Ctrl-] = console)\r\n";

static void mon_cmd(char *line) {
  char out[1024];
  while(*line == ' ') line++;
  if(line[0] == 0 || (line[0] == 'c' && line[1] == 0)) { g_mon_cmd_mode = false; mon_send("\r\n[console -- Ctrl-] = monitor]\r\n"); return; }
  else if(!strncmp(line, "help", 4) || line[0] == '?') mon_send(g_mon_help);
  else if(!strncmp(line, "pc", 2)) {
    snprintf(out, sizeof(out), "rtl_last_pc=%016llx iss_pc=%016llx cyc=%llu retired=%llu\r\n",
             (unsigned long long)g_mon_last_pc, (unsigned long long)(ss ? (uint64_t)ss->pc : 0),
             (unsigned long long)g_mon_cyc, (unsigned long long)g_mon_retired); mon_send(out);
  }
  else if(!strncmp(line, "state", 5)) {
    snprintf(out, sizeof(out), "cyc=%llu retired=%llu %s (checker=%s)\r\n",
             (unsigned long long)g_mon_cyc, (unsigned long long)g_mon_retired,
             g_mon_paused ? "[PAUSED]" : "[running]", ss ? "on" : "off"); mon_send(out);
  }
  else if(!strncmp(line, "perf", 4)) {
    uint64_t c = g_mon_cyc ? g_mon_cyc : 1; uint64_t m = g_mon_retired * 1000 / c;
    snprintf(out, sizeof(out), "retired=%llu cycles=%llu ipc=%llu.%03llu\r\n",
             (unsigned long long)g_mon_retired, (unsigned long long)g_mon_cyc,
             (unsigned long long)(m/1000), (unsigned long long)(m%1000)); mon_send(out);
  }
  else if(!strncmp(line, "cp0", 3) || !strncmp(line, "epc", 3)) {
    if(!ss) mon_send("cp0: no ISS -- run with --checker\r\n");
    else { snprintf(out, sizeof(out),
      "epc=%016llx status=%08x cause=%08x badv=%016llx index=%08x entryhi=%016llx\r\n",
      (unsigned long long)ss->cpr0_64[14], (uint32_t)ss->cpr0[12], (uint32_t)ss->cpr0[13],
      (unsigned long long)ss->cpr0_64[8], (uint32_t)ss->cpr0[0], (unsigned long long)ss->cpr0_64[10]); mon_send(out); }
  }
  else if(!strncmp(line, "regs", 4) || (line[0]=='r' && line[1] != 'e')) {
    if(!ss) mon_send("regs: no ISS -- run with --checker\r\n");
    else { const char *p = line+1; while(*p==' ') p++;
      if(*p>='0' && *p<='9') { int n = atoi(p) & 31; snprintf(out,sizeof(out),"r%d=%016llx\r\n",n,(unsigned long long)ss->gpr[n]); mon_send(out); }
      else for(int n=0;n<32;n++){ snprintf(out,sizeof(out),"r%-2d=%016llx%s",n,(unsigned long long)ss->gpr[n],(n&1)?"\r\n":"  "); mon_send(out); } }
  }
  else if(!strncmp(line, "mem", 3)) {
    const char *p = line+3; while(*p==' ') p++;
    uint32_t addr = (uint32_t)strtoul(p, nullptr, 16);
    const char *q = p; while(*q && *q!=' ') q++; while(*q==' ') q++;
    int n = (*q>='0'&&*q<='9') ? atoi(q) : 4; if(n > 64) n = 64;
    for(int i=0;i<n;i++){ uint32_t v; if(mon_mem_rd(addr+4*i,&v)) snprintf(out,sizeof(out),"%08x: %08x\r\n",addr+4*i,v);
                          else snprintf(out,sizeof(out),"%08x: <out of range>\r\n",addr+4*i); mon_send(out); }
  }
  else if(!strncmp(line, "timer", 5) || !strncmp(line, "tirq", 4)) {
    size_t n = g_timer_irq_cyc.size();
    if(n == 0) mon_send("timer: no timer IRQs logged yet\r\n");
    else {
      const char *p = line; while(*p && *p!=' ') p++; while(*p==' ') p++;
      int want = (*p>='0'&&*p<='9') ? atoi(p) : 10;
      snprintf(out, sizeof(out), "timer IRQs: %zu total  first=%llu last=%llu  (last %d, cyc:+delta)\r\n",
               n, (unsigned long long)g_timer_irq_cyc[0], (unsigned long long)g_timer_irq_cyc[n-1], want);
      mon_send(out);
      size_t lo = (n > (size_t)want) ? n - want : 0;
      for(size_t i = lo; i < n; i++) {
        uint64_t d = (i > 0) ? g_timer_irq_cyc[i] - g_timer_irq_cyc[i-1] : 0;
        snprintf(out, sizeof(out), "  #%zu  cyc=%llu  +%llu\r\n", i, (unsigned long long)g_timer_irq_cyc[i], (unsigned long long)d);
        mon_send(out);
      }
    }
  }
  else if(!strncmp(line, "halt", 4) || line[0]=='h') { g_mon_paused = true;  g_mon_step_to = 0; mon_send("[halted]\r\n"); }
  else if(!strncmp(line, "go", 2)   || line[0]=='g') { g_mon_paused = false; g_mon_step_to = 0; mon_send("[running]\r\n"); }
  else if(!strncmp(line, "step", 4) || line[0]=='s' || line[0]=='n') {
    const char *p = line + ((line[0]=='s'&&line[1]=='t') ? 4 : 1); while(*p==' ') p++;
    uint64_t cnt = (*p>='0'&&*p<='9') ? strtoull(p,nullptr,10) : 1;
    g_mon_step_to = g_mon_retired + cnt; g_mon_paused = false;   // run cnt retirements, re-pause
    snprintf(out, sizeof(out), "[step %llu insns...]\r\n", (unsigned long long)cnt); mon_send(out);
    return;   // the step-done reporter prints the next prompt
  }
  else mon_send("? (help)\r\n");
  mon_send("mon> ");
}

static void mon_poll(void) {
  if(g_mon_listen < 0) return;
  if(g_mon_client < 0) {
    int fd = accept(g_mon_listen, nullptr, nullptr);
    if(fd < 0) return;
    g_mon_client = fd;
    fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK);
    g_mon_cmd_mode = true; g_mon_len = 0;
    mon_send("\r\n[henry_tb monitor] 'help'; Ctrl-] toggles console\r\nmon> ");
    return;
  }
  uint8_t rb[256];
  ssize_t n = read(g_mon_client, rb, sizeof(rb));
  if(n == 0) { close(g_mon_client); g_mon_client = -1; g_mon_paused = false; g_mon_step_to = 0; return; }
  if(n < 0) return;   // EWOULDBLOCK
  for(ssize_t i=0;i<n;i++){
    uint8_t c = rb[i];
    if(c == 0x1d) { g_mon_cmd_mode = !g_mon_cmd_mode; mon_send(g_mon_cmd_mode ? "\r\n[monitor]\r\nmon> " : "\r\n[console]\r\n"); continue; }
    if(!g_mon_cmd_mode) continue;   // console input to guest not wired (inspect-only)
    if(c=='\r'||c=='\n'){ mon_send("\r\n"); g_mon_line[g_mon_len]=0; mon_cmd(g_mon_line); g_mon_len=0; }
    else if(c==0x7f||c==8){ if(g_mon_len>0){ g_mon_len--; mon_send("\b \b"); } }
    else if(g_mon_len < (int)sizeof(g_mon_line)-1){ g_mon_line[g_mon_len++]=(char)c; char e[2]={(char)c,0}; mon_send(e); }
  }
}

int main(int argc, char **argv) {
  std::string kernel, arcs, ckpt_file;
  uint64_t max_cyc = 120000000ull;
  uint64_t max_icnt = 0;   // --maxicnt: stop after this many retired insns (0 = unlimited)
  uint32_t start_pc = 0;   // fake-BIOS: start in the arcs boot stub (skip C++ handoff)
  std::vector<uint64_t> dump_pas;
  std::string trace_file;
  std::string rx_str;       // bytes to feed into the SCC serial Rx FIFO (--rx)
  // --arcs load address (physical). The henry_arcs FSBL firmware loads at the PROM
  // 0x1fc00000 (--start-pc 0xbfc00000). --arcs-addr overrides for a non-FSBL blob
  // that links low (e.g. 0x1000). Default = FSBL.
  uint64_t arcs_addr = 0x1fc00000ull;
  for(int i = 1; i < argc; i++) {
    std::string a = argv[i];
    if(a == "--kernel" && i+1 < argc)      kernel = argv[++i];
    else if(a == "--arcs" && i+1 < argc)   arcs   = argv[++i];
    else if(a == "--arcs-addr" && i+1 < argc) arcs_addr = strtoull(argv[++i], nullptr, 0);
    else if(a == "--maxcyc" && i+1 < argc) max_cyc = strtoull(argv[++i], nullptr, 0);
    else if(a == "--maxicnt" && i+1 < argc) max_icnt = strtoull(argv[++i], nullptr, 0);
    else if(a == "--start-pc" && i+1 < argc) start_pc = (uint32_t)strtoull(argv[++i], nullptr, 0);
    else if(a == "--dump" && i+1 < argc)   dump_pas.push_back(strtoull(argv[++i], nullptr, 0));
    else if(a == "--trace" && i+1 < argc)  trace_file = argv[++i];
    else if(a == "--rx" && i+1 < argc)     rx_str = argv[++i];
    else if(a == "--disk" && i+1 < argc)   g_scsi_disk.open_image(argv[++i]);
    else if(a == "--checkpoint" && i+1 < argc) ckpt_file = argv[++i];
    else if(a == "--checker")              g_checker = true;
  }
  std::vector<uint8_t> rx_bytes(rx_str.begin(), rx_str.end());
  if(kernel.empty() && ckpt_file.empty()) { fprintf(stderr, "usage: %s {--kernel <elf> | --checkpoint <file>} [--arcs <blob>] [--maxcyc N]\n", argv[0]); return 1; }

  g_mem = (uint8_t*)mmap(nullptr, MEM_SIZE, PROT_READ|PROT_WRITE,
                         MAP_PRIVATE|MAP_ANONYMOUS|MAP_NORESERVE, -1, 0);
  if(g_mem == MAP_FAILED) { perror("mmap ram"); return 1; }

  // Lockstep checker: create the golden ISS now so load_checkpoint can seed its
  // (PA-indexed) memory, matching the interp's va2pa output.
  if(g_checker) {
    g_ss_mem = new sparse_mem();
    ss = new state_t(*g_ss_mem);
    initState(ss);
    fprintf(stderr, "[checker] golden ISS created\n");
  }

  uint32_t entry;
  uint32_t kentry;
  if(!ckpt_file.empty()) {
    // checkpoint resume: the checkpoint carries ALL memory (kernel + page tables
    // + user) and the resume PC. No ELF/FSBL load; the RTL seeds its regs/TLB/CP0
    // from g_ckpt via DPI at reset. Skips the (hours-long) boot entirely.
    load_checkpoint(ckpt_file.c_str());
    entry = kentry = (uint32_t)g_ckpt.pc;
    seed_checker();
  } else {
  entry = load_elf_be32(kernel.c_str());
  kentry = entry;                  // real kernel entry (trace starts here)
  if(!arcs.empty()) {
    load_blob(arcs.c_str(), arcs_addr);    // FSBL @0x1fc00000, or stub-style @0x1000 (--arcs-addr)
    // FSBL path only: patch the kernel-entry slot @ phys 0x1fc00008 with the real
    // ELF entry (mirrors the mips-axi driver). A non-FSBL blob loaded low hardcodes
    // its kentry internally, so skip the patch when not loading at the PROM.
    if(arcs_addr == 0x1fc00000ull) {
      bool b=false; uint32_t soff = fpga_map(0x1fc00008u, &b); put_be32(soff, kentry);
      if(ss) { uint8_t *q = ss->mem.get_raw_ptr(0x1fc00008u);   // golden ISS: same kentry patch
               q[0]=kentry>>24; q[1]=kentry>>16; q[2]=kentry>>8; q[3]=(uint8_t)kentry; }
      printf("patched FSBL kentry slot @0x1fc00008 (dram 0x%x) = 0x%08x\n", soff, kentry);
    }
    if(start_pc) { entry = start_pc; printf("fake-bios: start pc = %08x\n", start_pc); }
    else         entry = install_arcs_handoff(entry); // sash-style argv/envp handoff -> stub -> kernel
  }
  }  // end else (non-checkpoint load)

  // checkpoint PC is a full 64-bit VA (n64 user code @ 0x1_xxxxxxxx); don't truncate.
  uint64_t resume_pc64 = ckpt_file.empty() ? (uint64_t)(int64_t)(int32_t)entry
                                           : (uint64_t)g_ckpt.pc;

  // Fresh-boot checker: ISS memory was seeded by load_elf_be32/load_blob above;
  // start it at the same entry the RTL resumes from (checker_step re-syncs the pc
  // on the first retirement anyway, but this makes the first compares meaningful).
  if(g_checker && ss && ckpt_file.empty()) {
    ss->pc = (state_t::reg_t)resume_pc64;
    fprintf(stderr, "[checker] golden ISS seeded for --kernel boot at pc=%08x\n", (uint32_t)ss->pc);
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

  // TCP monitor: enable with MON=1 or MONPORT=N (default port 2323). Opt-in so
  // the many automated runs don't hold a socket; connect with `nc localhost 2323`.
  //{ const char *mp = getenv("MONPORT");
  //if(mp || getenv("MON")) mon_init(mp ? atoi(mp) : 2323);
  //}
  mon_init(2323);

  Verilated::commandArgs(argc, argv);
  Vhenry_soc *tb = new Vhenry_soc;

  auto tick = [&](void) { tb->clk = 1; tb->eval(); tb->clk = 0; tb->eval(); };

  // ---- reset ----
  tb->reset = 1; tb->resume = 0; tb->resume_pc = 0;
  tb->mem_rsp_valid = 0; tb->mem_rsp_bad = 0; tb->putchar_fifo_pop = 0;
  tb->scc_rx_valid = 0; tb->scc_rx_byte = 0;
  for(int i = 0; i < 4; i++) tick();

  // ---- launch the core at the kernel entry (mirrors r9999 top.cc) ----
  tb->resume_pc = resume_pc64;
  tb->reset = 0; tick();
  while(!tb->ready_for_resume) tick();
  tb->resume = 1; tick();
  tb->resume = 0; tick();
  tb->resume = 1; tb->resume_pc = resume_pc64; tick();
  tb->resume = 0; tick();

  // ---- run ----
  bool halted = false;
  int64_t reply_cyc = -1;
  // Real AXI master requires mem_req_valid to DROP to 0 between requests before
  // it accepts the next -- so only accept on a 0->1 edge of mem_req_valid, not
  // merely when idle.  (Catches a missing arbiter turnaround that the old
  // reply_cyc==-1-only check silently let pass.)
  int prev_mem_req_valid = 0;
  uint64_t req_addr = 0; uint32_t req_op = 0; uint16_t req_mask = 0;
  uint32_t req_sd[4] = {0,0,0,0};
  bool req_bad = false, req_is_halt = false;
  /* RANDOM per-request memory latency (shmoo -> randomized): each request draws a
   * latency in [MEM_LAT_MIN,MEM_LAT_MAX], seeded by MEM_SEED, so a single boot
   * explores many load-timing alignments (mimics the FPGA's non-determinism to
   * hunt the load-timing x interrupt-boundary corruption race). */
  const int MEM_LAT_MIN = getenv("MEM_LAT_MIN") ? atoi(getenv("MEM_LAT_MIN")) : 1;
  const int MEM_LAT_MAX = getenv("MEM_LAT_MAX") ? atoi(getenv("MEM_LAT_MAX")) : 16;
  const unsigned MEM_SEED = getenv("MEM_SEED") ? (unsigned)atoi(getenv("MEM_SEED")) : 1;
  /* deterministic xorshift64 PRNG (machine-independent, unlike rand()) so a given
   * MEM_SEED reproduces the exact latency sequence anywhere. */
  uint64_t memlat_state = MEM_SEED ? (uint64_t)MEM_SEED : 88172645463325252ULL;
  auto memlat_next = [&memlat_state]() -> uint64_t {
    memlat_state ^= memlat_state << 13;
    memlat_state ^= memlat_state >> 7;
    memlat_state ^= memlat_state << 17;
    return memlat_state;
  };
  const uint64_t MEM_LAT_SPAN = (uint64_t)(MEM_LAT_MAX - MEM_LAT_MIN + 1);
  fprintf(stderr, "[memlat] RANDOM xorshift latency [%d,%d] seed=%u\n", MEM_LAT_MIN, MEM_LAT_MAX, MEM_SEED);
  uint64_t retired = 0, last_pc = 0;
  uint64_t prev_epc = 0; int exc_prints = 0; uint32_t prev_sr = 0; uint64_t prev_badv = 0;

  // Loop mirrors r9999 top.cc phase ordering: posedge eval FIRST (core samples
  // the mem_rsp set last cycle), THEN read mem_req and present mem_rsp for the
  // next posedge, then negedge eval.
  for(uint64_t cyc = 0; cyc < max_cyc && (max_icnt == 0 || retired < max_icnt) && !halted && !Verilated::gotFinish(); cyc++) {
    g_cur_cyc = cyc;   // stamp for the log_timer_irq() DPI (fires during eval below)
    // TCP monitor: snapshot counters, poll for client input, and FREEZE (poll
    // only, no RTL tick) while halted -- so `halt`/`step` hold the sim still for
    // inspection.  Poll sparsely while free-running to keep the fast path fast.
    if(g_mon_listen >= 0) {
      g_mon_cyc = cyc; g_mon_retired = retired; g_mon_last_pc = (uint64_t)last_pc;
      if(g_mon_paused || (cyc & 0x3ff) == 0) mon_poll();
      while(g_mon_paused) { mon_poll(); usleep(1000); }
    }
    g_probe_cyc = cyc;  // A/B DIAG: expose cyc to dpi_a0_probe
    // SCC serial Rx injection (--rx): drip one byte into the IOC2 Rx FIFO every 64
    // cycles once the core is running, so a directed test observes a serial IRQ.
    tb->scc_rx_valid = 0;
    { static size_t rx_idx = 0;
      if(rx_idx < rx_bytes.size() && cyc >= 2000 && (cyc % 64) == 0) {
        tb->scc_rx_valid = 1; tb->scc_rx_byte = rx_bytes[rx_idx++];
      } }

    // drain the console (SCC UART + core putchar, merged on the putchar port):
    // decide pop from the settled pre-posedge state so the posedge-clocked FIFO
    // actually advances rptr (assert pop BEFORE the edge, print the popped head).
    bool drain   = !tb->putchar_fifo_empty;
    char drain_ch = (char)tb->putchar_fifo_out;
    tb->putchar_fifo_pop = drain ? 1 : 0;

    tb->clk = 1;
    tb->eval();                              // posedge (FIFO advances if pop)
    if(drain) { putchar(drain_ch); mon_console_out(drain_ch); }

    if(tb->retire_valid) { retired++; last_pc = tb->retire_pc; }
    // monitor `step N`: re-pause once N more instructions have retired
    if(g_mon_step_to && retired >= g_mon_step_to) {
      g_mon_paused = true; g_mon_step_to = 0;
      char b[128]; snprintf(b, sizeof(b), "[stepped] retired=%llu rtl_pc=%016llx\r\nmon> ",
                            (unsigned long long)retired, (unsigned long long)tb->retire_pc);
      mon_send(b);
    }

    // ---- lockstep co-sim checker (mirrors r9999/top.cc:686-800) ----
    if(g_checker && ss) {
      ss->cpr0[CPR0_COUNT] = (uint32_t)tb->cp0_count;      // keep mfc0 $9 in sync
      // Track the RTL's exception CP0 regs so the ISS's handler control-flow
      // follows the RTL (the co-sim scope is GPRs/data, not CP0 modeling).
      ss->cpr0[14] = (uint32_t)tb->epc;      ss->cpr0_64[14] = tb->epc;        // EPC
      ss->cpr0[12] = tb->status_reg;                                           // Status
      ss->cpr0[8]  = (uint32_t)tb->badvaddr; ss->cpr0_64[8]  = tb->badvaddr;   // BadVAddr
      if(tb->took_irq) raise_int(ss, (uint32_t)tb->epc);   // IRQ: jump ISS to vector
      if(tb->retire_valid)
        checker_step(tb->retire_pc, tb->retire_reg_valid, tb->retire_reg_ptr, tb->retire_reg_data);
      if(tb->retire_two_valid)
        checker_step(tb->retire_two_pc, tb->retire_reg_two_valid, tb->retire_reg_two_ptr, tb->retire_reg_two_data);
    }

    // ---- go a0-corruption trace (approach B checkpoint; diagnostic) ----
    // Walk a0 (reg 4) through the ISR that runs between the userspace load
    // @0x12000146c (a0 <- valid ptr 0x1200fa608) and the faulting store
    // @0x120001480 (a0 == 0 -> SIGSEGV write to NULL).  Deterministic on the B
    // checkpoint; window scoped so the log stays small.  Env GO_A0_TRACE=1 arms it.
    // PC-gated variant (timing-independent for the A/B toggles): fire only near
    // the crash neighborhood so the log stays small regardless of when (which
    // cycle) the architectural crash point is reached.  a0 RESTORE @0x880119e0,
    // the go userspace crash region 0x1200146c..0x12000494, capped by g_go_lines.
    static uint64_t g_go_lines = 0;
    uint32_t p0lo = (uint32_t)tb->retire_pc, p1lo = (uint32_t)tb->retire_two_pc;
    bool near0 = (p0lo == 0x880119e0u) || (p0lo >= 0x20001460u && p0lo <= 0x20001494u);
    bool near1 = (p1lo == 0x880119e0u) || (p1lo >= 0x20001460u && p1lo <= 0x20001494u);
    if(g_go_a0_trace && g_go_lines < 4000 && (near0 || near1)) {
      g_go_lines++;
      if(tb->retire_valid && near0)
        fprintf(stderr, "[go] cyc=%llu p0 pc=0x%08x rv=%u r%u<=0x%llx\n",
                (unsigned long long)cyc, p0lo, (unsigned)tb->retire_reg_valid,
                (unsigned)tb->retire_reg_ptr, (unsigned long long)tb->retire_reg_data);
      if(tb->retire_two_valid && near1)
        fprintf(stderr, "[go] cyc=%llu p1 pc=0x%08x rv=%u r%u<=0x%llx\n",
                (unsigned long long)cyc, p1lo, (unsigned)tb->retire_reg_two_valid,
                (unsigned)tb->retire_reg_two_ptr, (unsigned long long)tb->retire_reg_two_data);
    }
    if(g_go_a0_trace && cyc > 21073000ull && cyc < 21130000ull) {
      // (1) every ARCHITECTURAL write to a0 (reg 4), both retire ports.  If a0
      // reaches 0 WITHOUT any such write, the clobber is silent (PRF/rename).
      if(tb->retire_valid && tb->retire_reg_valid && tb->retire_reg_ptr == 4)
        fprintf(stderr, "[a0] cyc=%llu p0 pc=0x%llx a0<=0x%016llx\n",
                (unsigned long long)cyc, (unsigned long long)tb->retire_pc,
                (unsigned long long)tb->retire_reg_data);
      if(tb->retire_two_valid && tb->retire_reg_two_valid && tb->retire_reg_two_ptr == 4)
        fprintf(stderr, "[a0] cyc=%llu p1 pc=0x%llx a0<=0x%016llx\n",
                (unsigned long long)cyc, (unsigned long long)tb->retire_two_pc,
                (unsigned long long)tb->retire_reg_two_data);
      // (2) IRQ / exception entry markers (nested-exception detection).
      if(tb->took_irq)
        fprintf(stderr, "[irq] cyc=%llu epc=0x%llx cause=%u sr=0x%08x badv=0x%llx\n",
                (unsigned long long)cyc, (unsigned long long)tb->epc,
                (unsigned)tb->cause, (unsigned)tb->status_reg,
                (unsigned long long)tb->badvaddr);
      // (3) full retire trace (both ports, with any reg writeback) for the ISR
      // walk + disassembly.  sp(29)/k0(26)/k1(27) writes here let us reconstruct
      // the pt_regs frame base to locate PT_R4 for the save/restore.
      if(tb->retire_valid)
        fprintf(stderr, "[rt] cyc=%llu p0 pc=0x%08x rv=%u r%u<=0x%llx\n",
                (unsigned long long)cyc, (uint32_t)tb->retire_pc,
                (unsigned)tb->retire_reg_valid, (unsigned)tb->retire_reg_ptr,
                (unsigned long long)tb->retire_reg_data);
      if(tb->retire_two_valid)
        fprintf(stderr, "[rt] cyc=%llu p1 pc=0x%08x rv=%u r%u<=0x%llx\n",
                (unsigned long long)cyc, (uint32_t)tb->retire_two_pc,
                (unsigned)tb->retire_reg_two_valid, (unsigned)tb->retire_reg_two_ptr,
                (unsigned long long)tb->retire_reg_two_data);
    }

    // calibration probe: _cpuclkper100ticks ends at 0x88019648 (subu v0,v1,v0).
    if(tb->retire_valid && (uint32_t)tb->retire_pc == 0x88019648u)
      fprintf(stderr, "[calib] cyc=%llu reg%u=%d (0x%x)\n", (unsigned long long)cyc,
              (unsigned)tb->retire_reg_ptr, (int)tb->retire_reg_data, (unsigned)tb->retire_reg_data);
    if(tb->retire_two_valid && (uint32_t)tb->retire_two_pc == 0x88019648u)
      fprintf(stderr, "[calib2] cyc=%llu reg%u=%d (0x%x)\n", (unsigned long long)cyc,
              (unsigned)tb->retire_reg_two_ptr, (int)tb->retire_reg_two_data, (unsigned)tb->retire_reg_two_data);

    // ---- SCSI: the ARM disk service (TB plays the PS).  RADICALLY DIFFERENT "DMA":
    // the scsi_dma RTL engine is the ONLY agent that touches MIPS memory -- it walks
    // the {BP,BC,DP} descriptor chain and writes mem[BP] via M00, in the same domain
    // the CPU reads from.  The TB NEVER touches g_mem for the payload; it only sources
    // /sinks disk bytes across the beat conduit (the FPGA's ordered S00 slave-reg leg):
    //   READ : pread the disk -> stream 16B beats into scsi_beat_* (engine -> mem[BP]).
    //   WRITE: capture the engine's disk_wr beats (engine reads mem[BP]) -> block_write.
    // Byte count is derived from the CDB by scsi_service_run (sizes g_buf); the engine
    // independently uses the descriptor BC.  Completion: the engine pulses dma_done
    // (data has landed); we post scsi_rsp_* for the SCSI-level status (GOOD, or
    // selection-timeout 0x42 which makes the shim abort the otherwise-stalled engine).
    static std::vector<uint8_t> g_buf;
    static bool       g_to_dev = false;
    static uint64_t   g_wr_lba = 0;
    static bool       g_streaming = false;     // READ:  feeding beats into the FIFO
    static size_t     g_stream_pos = 0;
    static bool       g_capturing = false;     // WRITE: draining engine disk_wr beats
    static scsi_rsp_t g_pending_rsp;
#ifdef FAITHFUL_SCSI
    // Faithful chunked DMA (Stage A): carry {buf,pos,total} across HPC3 descriptor-
    // chain EOX chunk boundaries.  chunk = min(WD33C93 xfer count, remaining) == the
    // chain the engine walks per doorbell; on dma_done pos+=chunk and, if pos<total,
    // post a PAUSE (0x48/0x49) so IRIX reprograms + re-issues SEL_ATN_XFER.  A doorbell
    // arriving mid-transfer is a RESUME (same buf; beats stream continuously across
    // chunks).  Mirrors interp_mips select_and_transfer()/pause_transfer().
    static size_t     g_pos = 0, g_total = 0;
    static uint32_t   g_chunk = 0;
    static bool       g_active = false;
#endif
    auto post_rsp = [&](void){
      tb->scsi_rsp_residual    = g_pending_rsp.residual;
      tb->scsi_rsp_scsi_status = g_pending_rsp.scsi_status;
      tb->scsi_rsp_tgt_status  = g_pending_rsp.tgt_status;
      tb->scsi_rsp_seq         = g_pending_rsp.seq;
    };
    tb->scsi_beat_push = 0;
    if(g_scsi_disk.ok() && tb->scsi_req_seq != g_last_scsi_req_seq) {
      g_last_scsi_req_seq = tb->scsi_req_seq;
      scsi_req_t req; req.seq = tb->scsi_req_seq; req.channel = CH_SCSI0;
      req.nbdp = tb->scsi_req_nbdp; req.xfer_len = tb->scsi_req_xfer_len;
      for(int i = 0; i < 4; i++) ((uint32_t*)req.cdb)[i] = tb->scsi_req_cdb[i];
      req.dest = (uint8_t)tb->scsi_req_dest; req.lun = (uint8_t)tb->scsi_req_lun;
      req.to_device = (uint8_t)tb->scsi_req_to_device;
#ifdef FAITHFUL_SCSI
      bool resume = g_active && g_pos < g_total;       // mid-transfer doorbell = resume
      if(!resume) {                                    // NEW command: decode + read disk
        scsi_service_run(&req, &g_pending_rsp, &g_scsi_disk, g_buf, g_to_dev, g_wr_lba);
        g_total = g_buf.size(); g_pos = 0; g_stream_pos = 0;
        g_active = (g_pending_rsp.scsi_status == ST_SELECT_TRANSFER_SUCCESS) && !g_buf.empty();
      } else {                                         // RESUME: same buf, new chain
        g_pending_rsp.scsi_status = ST_SELECT_TRANSFER_SUCCESS; g_pending_rsp.tgt_status = TGT_GOOD;
      }
      g_pending_rsp.seq = tb->scsi_req_seq;
      if(getenv("SCSIDBG"))
        fprintf(stderr, "[scsi] cyc=%llu %s CDB %02x %02x %02x %02x %02x %02x dest=%u lun=%u "
                "nbdp=%08x xfer=%u pos=%zu/%zu dir=%d\n", (unsigned long long)cyc,
                resume?"RESUME":"NEW", req.cdb[0],req.cdb[1],req.cdb[2],req.cdb[3],req.cdb[4],
                req.cdb[5], req.dest, req.lun, req.nbdp, req.xfer_len, g_pos, g_total, (int)g_to_dev);
      if(g_active) {
        uint32_t rem = (uint32_t)(g_total - g_pos);    // chunk = WD33C93 count (== chain)
        g_chunk = (req.xfer_len && req.xfer_len < rem) ? req.xfer_len : rem;
        if(!g_to_dev) { g_streaming = true; }          // READ: feed the engine this chunk
        else          { if(!resume) g_buf.clear(); g_capturing = true; }  // WRITE: drain
      } else {
        post_rsp();                                    // timeout / no data (shim aborts)
      }
#else
      scsi_service_run(&req, &g_pending_rsp, &g_scsi_disk, g_buf, g_to_dev, g_wr_lba);
      g_pending_rsp.seq = tb->scsi_req_seq;
      if(getenv("SCSIDBG"))
        fprintf(stderr, "[scsi] cyc=%llu CDB %02x %02x %02x %02x %02x %02x dest=%u lun=%u "
                "nbdp=%08x -> st=%02x tgt=%02x bufsz=%zu dir=%d\n",
                (unsigned long long)cyc, req.cdb[0],req.cdb[1],req.cdb[2],req.cdb[3],req.cdb[4],
                req.cdb[5], req.dest, req.lun, req.nbdp, g_pending_rsp.scsi_status,
                g_pending_rsp.tgt_status, g_buf.size(), (int)g_to_dev);
      if(g_pending_rsp.scsi_status == ST_SELECT_TRANSFER_SUCCESS && !g_to_dev && !g_buf.empty()) {
        g_stream_pos = 0; g_streaming = true;          // READ: feed the engine
      } else if(g_pending_rsp.scsi_status == ST_SELECT_TRANSFER_SUCCESS && g_to_dev) {
        g_buf.clear(); g_capturing = true;             // WRITE: drain the engine
      } else {
        post_rsp();                                    // timeout / no data: status now (shim aborts)
      }
#endif
    }
    // READ: push one 16-byte beat/cycle into the conduit (engine stalls when empty),
    // respecting full; post status once the whole buffer is in flight.
    if(g_streaming) {
#ifdef FAITHFUL_SCSI
      // Stream beats continuously across chunks (the engine consumes one chain per
      // doorbell); the chunk boundary is dma_done, not the stream pointer.
      if(g_stream_pos < g_total && !tb->scsi_beat_full) {
        for(int i = 0; i < 4; i++) { uint32_t w = 0;
          for(int j = 0; j < 4; j++) { size_t idx = g_stream_pos + 4*i + j;
            if(idx < g_total) w |= (uint32_t)g_buf[idx] << (8*j); }
          tb->scsi_beat_data[i] = w; }
        tb->scsi_beat_push = 1;
        g_stream_pos += 16;
      }
      if(tb->scsi_dma_done) {                          // engine finished this chunk's chain
        g_pos += g_chunk; g_streaming = false;
        if(g_pos < g_total) {                          // chunk PAUSE: IRIX will resume
          g_pending_rsp.completion = SCSI_DONE_PAUSE; g_pending_rsp.scsi_status = 0x49;
        } else {                                       // whole command delivered
          g_pending_rsp.completion = SCSI_DONE_COMPLETE;
          g_pending_rsp.scsi_status = ST_SELECT_TRANSFER_SUCCESS; g_active = false;
        }
        g_pending_rsp.residual = 0; post_rsp();
      }
#else
      if(g_stream_pos >= g_buf.size()) { g_streaming = false; post_rsp(); }
      else if(!tb->scsi_beat_full) {
        for(int i = 0; i < 4; i++) { uint32_t w = 0;
          for(int j = 0; j < 4; j++) { size_t idx = g_stream_pos + 4*i + j;
            if(idx < g_buf.size()) w |= (uint32_t)g_buf[idx] << (8*j); }
          tb->scsi_beat_data[i] = w; }
        tb->scsi_beat_push = 1;
        g_stream_pos += 16;
      }
#endif
    }
    // WRITE: capture each beat the engine pushes out (mem[BP] -> disk), commit at done.
    if(g_capturing) {
      if(tb->scsi_disk_wr_en)
        for(int b = 0; b < 16; b++)
          g_buf.push_back((tb->scsi_disk_wr_data[b>>2] >> (8*(b&3))) & 0xff);
      if(tb->scsi_dma_done) {
        g_capturing = false;
#ifdef FAITHFUL_SCSI
        // commit this chunk's blocks at the running LBA offset, then advance / pause
        for(size_t b = 0; b*512 + 512 <= g_buf.size(); b++)
          g_scsi_disk.block_write(g_wr_lba + g_pos/512 + b, g_buf.data() + b*512);
        g_pos += g_chunk; g_buf.clear();
        if(g_pos < g_total) {                          // chunk PAUSE: IRIX will resume
          g_pending_rsp.completion = SCSI_DONE_PAUSE; g_pending_rsp.scsi_status = 0x48;
        } else {                                       // whole command delivered
          g_pending_rsp.completion = SCSI_DONE_COMPLETE;
          g_pending_rsp.scsi_status = ST_SELECT_TRANSFER_SUCCESS; g_active = false;
        }
        g_pending_rsp.residual = 0; post_rsp();
#else
        for(size_t b = 0; b*512 + 512 <= g_buf.size(); b++)
          g_scsi_disk.block_write(g_wr_lba + b, g_buf.data() + b*512);
        post_rsp();
#endif
      }
    }
    // programmable shim select->data delay (on the FPGA this is an AXI reg the ARM
    // sets; in sim drive a fixed value -- must be >= the SVC_DELAY service deferral).
    tb->scsi_sel_delay = 8192;
    // 64-bit-address-bug probe: log every a0 (reg 4) writeback near the fault
    if(false && cyc > 35850000ull && cyc < 35870000ull) {
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
    if(tb->mem_req_valid && !prev_mem_req_valid && reply_cyc == -1) {  // accept on 0->1 edge only
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
      { int lat = MEM_LAT_MIN + (int)(memlat_next() % MEM_LAT_SPAN);   /* random per request */
        reply_cyc = (int64_t)cyc + ((req_op == 4) ? lat : 2*lat); }
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
    prev_mem_req_valid = tb->mem_req_valid;  // for the next-cycle 0->1 edge check

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
    if(cyc && (cyc % (1UL<<24)) == 0) {
      fprintf(stderr, "[tb] cyc %llu  retired %llu  last_pc 0x%llx  head_pc 0x%llx  "
              "cause=%u epc=0x%llx badv=0x%llx sr=0x%08x irq=%u\n",
              (unsigned long long)cyc, (unsigned long long)retired,
              (unsigned long long)last_pc, (unsigned long long)tb->dbg_head_pc,
              (unsigned)tb->cause, (unsigned long long)tb->epc,
              (unsigned long long)tb->badvaddr, (unsigned)tb->status_reg, (unsigned)tb->took_irq);
    }
    if(tb->got_bad_addr) { printf("\n[tb] got_bad_addr at cycle %llu\n", (unsigned long long)cyc); }
  }

  fprintf(stderr, "[tb] final: retired %llu  last_pc 0x%llx  head_pc 0x%llx  "
          "cause=%u epc=0x%llx badv=0x%llx sr=0x%08x irq=%u\n",
          (unsigned long long)retired, (unsigned long long)last_pc,
          (unsigned long long)tb->dbg_head_pc, (unsigned)tb->cause,
          (unsigned long long)tb->epc, (unsigned long long)tb->badvaddr,
          (unsigned)tb->status_reg, (unsigned)tb->took_irq);
  if(g_checker)
    fprintf(stderr, "[checker] %llu insns checked, %llu real divergences, %llu suppressed, %llu mapped-skip, %llu resync\n",
            (unsigned long long)g_chk_insns, (unsigned long long)g_chk_diverge,
            (unsigned long long)g_chk_copsupp, (unsigned long long)g_chk_mapped, (unsigned long long)g_chk_resync);
  printf("\n[tb] %s\n", halted ? "halted (magic-halt store)" : "reached max cycles");
  for(uint64_t pa : dump_pas) dump_pa(pa);
  if(trace) { fclose(trace); fprintf(stderr, "[tb] wrote retired-PC trace to %s\n", trace_file.c_str()); }
  delete tb;
  return 0;
}
