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
#include <map>
#include <algorithm>
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
// RTL exception context latched each cycle (used by checker_step's exception sync).
// tb->cause is the 5-bit ExcCode (0=Int/async, 1=Mod, 2=TLBL, 3=TLBS, ...).
static uint32_t    g_rtl_cause = 0;
static uint32_t    g_rtl_cause_ip = 0;   // RTL Cause.IP[7:0] pending bits, for correct ISS ISR dispatch
static uint32_t    g_rtl_epc = 0;        // RTL exception EPC, for the async-interrupt entry EPC only
static uint64_t    g_rtl_badv  = 0;
static int         g_tlb_delta_shown = 0;  // cap the [TLB-DELTA] log
static uint32_t    g_chk_gate_pc = 0;      // preamble-resume: start lockstep at this ckpt pc
static bool        g_chk_active_gate = true; // on for normal boot; off (gated) when resuming

// ---- co-sim store-check (forward-ported from rv64core across the shared MIPS ancestor) ----
// The golden ISS records committed stores (interpret.cc, program order); the RTL reports
// each store cache-write via the wr_log DPI (l1d.sv).  Both streams are program-order, so
// we drain+compare fronts -- the first mismatch is THE root store.  Compares pc/addr and
// the low-32 data bits (endianness/partial-store robust).
std::deque<store_rec>        g_iss_stores;          // defined here; extern in interpret.hh
static std::deque<store_rec> g_rtl_stores;
static bool                  g_store_diverged = false;
extern "C" void wr_log(long long pc, int rob_ptr, unsigned long long addr,
                       unsigned long long data, int is_atomic) {
  (void)rob_ptr; (void)is_atomic;
  if(g_checker) g_rtl_stores.emplace_back((uint64_t)pc, addr, data);
}

// RTL TLB-write mirror: itlb.sv fires this DPI on every TLBWI/TLBWR (tlb_entry_in_valid),
// passing the entry index + the installed EntryHi/EntryLo0/EntryLo1 (already packed into
// the ISS's CP0 bit layout) + the RTL pagemask.  We BUFFER it and apply it to ss->tlb[]
// AFTER checker_step (so it overrides the ISS's own tlbwr, which can drift).  Keeps the
// golden ISS's 48-entry TLB bit-identical to the RTL's, closing the kseg2 TLB-desync class.
extern void iss_apply_tlb_write(state_t *s, int idx, uint64_t ehi, uint64_t elo0, uint64_t elo1, uint32_t pm);
struct pend_tlb_t { int idx; uint64_t ehi, elo0, elo1; uint32_t pm; };
static std::deque<pend_tlb_t> g_pend_tlb;   // FIFO: wirepda installs several wired entries
                                            // back-to-back; a single-entry buffer dropped the
                                            // clobbered write -> the ISS missed the wired PDA.
// most-recent retiring PC (updated each cycle in the main loop). TLBDUP prints it
// so a duplicate's CREATING write is attributed to its handler: eutlbmiss/utlbmiss
// (~0x880147xx, a blind tlbwr on a REFILL => spurious miss on a resident VA = root)
// vs tlbdropin (~0x88002dxx, tlbp-then-tlbwi) vs kmissnxt (~0x880145xx).
static uint64_t g_cur_retire_pc = 0;
extern "C" void tlb_wr_log(int entry, long long ehi, long long elo0, long long elo1, int pm) {
  { /* TLBDUP: MIPS makes 2 entries matching the same VA UNDEFINED ("very bad
     * things"). Mirror the 48 entries and, after each write, scan for a duplicate
     * of the just-written one (same VPN2[39:13] + R[63:62], and ASID[7:0] equal OR
     * both pages Global). A hit = the RTL/kernel created a duplicate -> the store
     * can hit a stale D=0 copy while the D=1 update lands elsewhere -> Modify loop. */
    static const bool tdup = getenv("TLBDUP") != nullptr;
    if(tdup && entry >= 0 && entry < 48) {
      static uint64_t m_ehi[48]={0}, m_elo0[48]={0}, m_elo1[48]={0}; static bool m_wr[48]={false};
      auto vpn2 = [](uint64_t e){ return (e >> 13) & 0x7ffffffULL; };
      auto rfld = [](uint64_t e){ return (e >> 62) & 0x3ULL; };
      auto asid = [](uint64_t e){ return e & 0xffULL; };
      auto glob = [](uint64_t l0, uint64_t l1){ return (l0 & 1ULL) && (l1 & 1ULL); };
      static uint64_t n_wr = 0; n_wr++;
      auto vld = [](uint64_t l0, uint64_t l1){ return ((l0 >> 1) & 1) || ((l1 >> 1) & 1); };  /* V bit either page */
      m_ehi[entry]=(uint64_t)ehi; m_elo0[entry]=(uint64_t)elo0; m_elo1[entry]=(uint64_t)elo1; m_wr[entry]=true;
      for(int j = 0; j < 48; j++) {
        if(j == entry || !m_wr[j]) continue;
        bool va_match = (vpn2(m_ehi[j]) == vpn2((uint64_t)ehi)) && (rfld(m_ehi[j]) == rfld((uint64_t)ehi));
        bool as_match = (asid(m_ehi[j]) == asid((uint64_t)ehi)) ||
                        (glob(m_elo0[j],m_elo1[j]) && glob((uint64_t)elo0,(uint64_t)elo1));
        /* only DANGEROUS duplicates: at least one page valid in BOTH slots (an all-invalid
         * placeholder pair never matches a real access -> harmless TLB-init idiom). */
        if(va_match && as_match && vld((uint64_t)elo0,(uint64_t)elo1) && vld(m_elo0[j],m_elo1[j]))
          fprintf(stderr, "[TLBDUP] wr#%llu creator_pc=%08llx DUP vpn2=%llx r=%llu: entry %d (ehi=%llx elo0=%llx elo1=%llx) == entry %d (ehi=%llx elo0=%llx elo1=%llx)\n",
                  (unsigned long long)n_wr, (unsigned long long)g_cur_retire_pc,
                  (unsigned long long)vpn2((uint64_t)ehi), (unsigned long long)rfld((uint64_t)ehi),
                  entry, (unsigned long long)ehi, (unsigned long long)elo0, (unsigned long long)elo1,
                  j, (unsigned long long)m_ehi[j], (unsigned long long)m_elo0[j], (unsigned long long)m_elo1[j]);
      }
    }
  }
  if(!g_checker) return;
  g_pend_tlb.push_back({ entry, (uint64_t)ehi, (uint64_t)elo0, (uint64_t)elo1, (uint32_t)pm << 13 });
}
// L1D->L2 writeback watch (DESCWATCH): log dirty-line writebacks to the SCSI descriptor line
// -> tells us if the L1D already holds the corrupted line (L1D bug) vs the L2 corrupting it.
extern "C" void l1d_wb_log(unsigned long long pa, unsigned long long data_lo, unsigned long long data_hi) {
  if(!g_checker) return;
  static const bool dw = getenv("DESCWATCH") != nullptr;
  if(!dw) return;
  uint32_t la = (uint32_t)(pa & 0x0ffffff0ull);
  static int n = 0;
  if(la == 0x003e4000u || la == 0x083e4000u || n++ < 12)   /* +first 12 = does the DPI fire at all? */
    fprintf(stderr, "[l1dwb] pa=%08llx lo=%016llx hi=%016llx\n", pa, data_lo, data_hi);
}
static uint64_t g_cur_cyc = 0;                 // updated each loop iteration (declared early for the DPIs)

// TIP: commit-stall attribution (ported from rv64core top.cc). Every cycle, charge
// 1.0 to the ROB-head PC when nothing retires (the head is the stall), or split the
// cycle among the retiree(s). tip[pc] = total cycles spent at/waiting-on that PC ->
// the top PCs are exactly where the pipeline burns time. Gated by env TIP.
static std::map<uint32_t,double> g_tip;
static void tip_dump(const char *tag) {
  if(g_tip.empty()) { return; }
  std::vector<std::pair<uint32_t,double>> v(g_tip.begin(), g_tip.end());
  std::sort(v.begin(), v.end(), [](const std::pair<uint32_t,double>&a,
                                   const std::pair<uint32_t,double>&b){ return a.second > b.second; });
  double tot = 0.0;
  for(size_t i = 0; i < v.size(); i++) { tot += v[i].second; }
  fprintf(stderr, "[tip] === %s  total=%.0f cyc  distinct_pcs=%zu ===\n", tag, tot, v.size());
  for(size_t i = 0; i < v.size() && i < 20; i++) {
    fprintf(stderr, "[tip]   pc=%08x  %12.0f cyc  (%5.1f%%)\n",
            v[i].first, v[i].second, 100.0 * v[i].second / tot);
  }
}
// scsi_dma engine trace (SCSIDMADBG): every chain start / descriptor read / mem write, so we
// can see whether the engine's r_bp (write target) walks onto the descriptor's own address.
extern "C" void scsi_dma_log(int kind, unsigned long long a, unsigned long long b,
                             unsigned long long c, unsigned long long d) {
  if(!g_checker) return;
  static const bool dbg = getenv("SCSIDMADBG") != nullptr;
  if(!dbg) return;
  if(kind == 2)
    fprintf(stderr, "[dma-go]   cyc=%llu nbdp=%08llx to_dev=%llu\n", (unsigned long long)g_cur_cyc, a, b);
  else if(kind == 0)
    fprintf(stderr, "[dma-desc] cyc=%llu nbdp=%08llx -> bp=%08llx bc=%08llx dp=%08llx\n",
            (unsigned long long)g_cur_cyc, a, b, c, d);
  else if(kind == 1)
    fprintf(stderr, "[dma-wr]   cyc=%llu bp=%08llx cnt=%llu data=%016llx%016llx\n",
            (unsigned long long)g_cur_cyc, a, b, d, c);
  else
    fprintf(stderr, "[dma-st]   cyc=%llu state=%llu nbdp=%08llx bp=%08llx cnt=%llu\n",
            (unsigned long long)g_cur_cyc, a, b, c, d);
}
// L2 line tracer (L2DBG): full 16-byte descriptor line at each L2 boundary.
// side 0 = L1D->L2 store/writeback IN, 1 = L2->DRAM eviction OUT, 2 = L2 fill from DRAM.
// Descriptor {BP,BC,DP} is big-endian in DRAM; d0 packs bytes 0..7 little-endian, so
// BP = bswap32(low32(d0)), BC = bswap32(high32(d0)).
extern "C" void l2_line_log(int side, unsigned long long pa, unsigned long long d0,
                            unsigned long long d1, int op, int mask) {
  static const bool l2dbg = getenv("L2DBG") != nullptr;
  if(!l2dbg) return;
  const char *sn = (side == 0) ? "L1->L2 " : (side == 1) ? "L2->DRAM" : "fill    ";
  uint32_t bp = __builtin_bswap32((uint32_t)d0), bc = __builtin_bswap32((uint32_t)(d0 >> 32));
  uint32_t dp = __builtin_bswap32((uint32_t)d1);
  fprintf(stderr, "[l2line] cyc=%llu %s pa=%08llx op=%d mask=%04x  d0=%016llx d1=%016llx  BP=%08x BC=%08x DP=%08x\n",
          (unsigned long long)g_cur_cyc, sn, pa, op, (unsigned)mask, d0, d1, bp, bc, dp);
}
// L2 CHECK_VALID_AND_TAG decision for the descriptor line: did the op hit? is the
// held line dirty? what does it hold?  Reveals why a MEM_WB fails to drop a stale copy.
extern "C" void l2_chk_log(unsigned long long pa, int whit, int wvalid, int wdirty,
                           int op, unsigned long long d0lo, unsigned long long d0hi) {
  static const bool l2dbg = getenv("L2DBG") != nullptr;
  if(!l2dbg) return;
  static const char *opn[32] = {0};
  opn[4]="LW"; opn[7]="SW"; opn[15]="SD"; opn[24]="INVL"; opn[26]="WB"; opn[27]="CHWB"; opn[28]="CHWBINV"; opn[29]="CHINV";
  const char *on = (op>=0 && op<32 && opn[op]) ? opn[op] : "?";
  uint32_t bp = __builtin_bswap32((uint32_t)d0lo), bc = __builtin_bswap32((uint32_t)(d0lo >> 32));
  fprintf(stderr, "[l2chk ] cyc=%llu pa=%08llx op=%-3s(%d) hit=%d valid=%d dirty=%d  held: BP=%08x BC=%08x\n",
          (unsigned long long)g_cur_cyc, pa, on, op, whit, wvalid, wdirty, bp, bc);
}
static void drain_store_check() {
  while(!g_iss_stores.empty() && !g_rtl_stores.empty()) {
    store_rec &i = g_iss_stores.front(), &r = g_rtl_stores.front();
    // Both sides now: real PA (ISS via tlb_probe_ro), and data masked to the store size
    // (sb/sh/sw/sd).  Compare pc + full PA + full data.
    bool ok = ((uint32_t)i.pc) == ((uint32_t)r.pc)
              && i.addr == r.addr
              && i.data == r.data;
    if(!ok) {
      fprintf(stderr, "[STORE-CHECK] ROOT STORE DIVERGENCE\n"
              "  ISS pc=%08x addr=%09lx data=%016llx\n"
              "  RTL pc=%08x addr=%09lx data=%016llx\n",
              (uint32_t)i.pc, (unsigned long)i.addr, (unsigned long long)i.data,
              (uint32_t)r.pc, (unsigned long)r.addr, (unsigned long long)r.data);
      // Dump both store streams (depth + first entries) so the divergence context is
      // visible: is one side a phantom (extra store) the other never made, or a value
      // mismatch at the same pc?  Look for where the streams re-converge.
      fprintf(stderr, "  [queues] ISS depth=%zu  RTL depth=%zu\n", g_iss_stores.size(), g_rtl_stores.size());
      for(size_t k = 0; k < 8 && k < g_iss_stores.size(); k++)
        fprintf(stderr, "    ISS[%zu] pc=%08x addr=%09lx data=%016llx\n", k,
                (uint32_t)g_iss_stores[k].pc, (unsigned long)g_iss_stores[k].addr, (unsigned long long)g_iss_stores[k].data);
      for(size_t k = 0; k < 8 && k < g_rtl_stores.size(); k++)
        fprintf(stderr, "    RTL[%zu] pc=%08x addr=%09lx data=%016llx\n", k,
                (uint32_t)g_rtl_stores[k].pc, (unsigned long)g_rtl_stores[k].addr, (unsigned long long)g_rtl_stores[k].data);
      // TLB-DUMP: dump the ISS TLB (mirrored from the RTL's tlbwi/tlbwr) for every entry
      // covering the fault VA, so a store/translate divergence can be compared against the
      // matched entry's V/D/PFN (duplicate entries, mismatched D, or a drifted mapping).
      { uint32_t fva = (uint32_t)g_rtl_badv;
        uint32_t fvpn2 = fva >> 13;
        fprintf(stderr, "[TLB-DUMP] fault VA=%08x vpn2=%07x va12(odd)=%u curASID=%02x\n",
                fva, fvpn2, (fva>>12)&1, (unsigned)(ss->cpr0[10] & 0xff));
        for(int t=0; t<48; t++) {
          uint64_t ehi=ss->tlb[t].entry_hi, e0=ss->tlb[t].entry_lo0, e1=ss->tlb[t].entry_lo1;
          uint64_t pm=(ss->tlb[t].page_mask)&0x1ffe000ULL;
          uint64_t vpnMask=(~(uint64_t)(pm|0x1fffULL))&0x000000ffffffe000ULL;
          bool covers=(((uint64_t)fva)&vpnMask)==(ehi&vpnMask);      // pagemask-aware coverage of the fault VA
          uint32_t vpn=(uint32_t)((ehi>>13)&0x7ffffffULL);
          if(covers)                                                  // ALL entries covering 0x0fbdbc3c (incl. large pages)
            fprintf(stderr, "  [%2d]*COVERS pm=%07x vpn=%07x asid=%02x g=%u|%u v=%u|%u d=%u|%u pfn=%06x|%06x\n",
                    t, (unsigned)(ss->tlb[t].page_mask), vpn, (unsigned)(ehi&0xff),
                    (unsigned)(e0&1),(unsigned)(e1&1),(unsigned)((e0>>1)&1),(unsigned)((e1>>1)&1),
                    (unsigned)((e0>>2)&1),(unsigned)((e1>>2)&1),
                    (unsigned)((e0>>6)&0xffffff),(unsigned)((e1>>6)&0xffffff));
        }
      }
      g_store_diverged = true; return;
    }
    g_iss_stores.pop_front(); g_rtl_stores.pop_front();
  }
}
#ifdef HENRY_TB_GO_DEBUG
static const bool  g_go_a0_trace = getenv("GO_A0_TRACE") != nullptr; // diagnostic a0-corruption window trace
#endif
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

// Preamble-resume test: load a .cimg (ckpt2preamble.py output = [u32 num][u32 pa,4096B]..)
// into g_mem (mirrors the ARM PS writing DRAM), + the golden ISS's mem if present.  NO
// DPI state seeding -- the arcs 'preamble' blob restores regs/CP0/TLB itself, exactly as
// it will on silicon.  Validates the preamble reproduces the DPI checkpoint resume.
static void load_cimg(const char *path) {
  FILE *f = fopen(path, "rb");
  if(!f) { fprintf(stderr, "cannot open cimg %s\n", path); exit(1); }
  uint64_t base_icnt = 0; if(fread(&base_icnt, 8, 1, f) != 1) { fprintf(stderr, "bad cimg\n"); exit(1); }
  g_ckpt.icnt = base_icnt;   // so --verify computes the window length correctly
  uint32_t n = 0; if(fread(&n, 4, 1, f) != 1) { fprintf(stderr, "bad cimg\n"); exit(1); }
  uint32_t loaded = 0;
  for(uint32_t i = 0; i < n; i++) {
    uint32_t va = 0; uint8_t data[4096];
    if(fread(&va, 4, 1, f) != 1 || fread(data, 1, 4096, f) != 4096) break;
    bool bad=false; uint32_t off = fpga_map(va, &bad);
    if(!bad) { memcpy(g_mem + off, data, 4096); loaded++; }
    if(ss) memcpy(ss->mem.get_raw_ptr(va), data, 4096);
  }
  fclose(f);
  fprintf(stderr, "[cimg] loaded %u/%u pages from %s (g_mem%s)\n", loaded, n, path, ss?"+ISS":"");
}

// ---- echo-free validation --------------------------------------------------
// Compare the RTL's committed memory (g_mem) against an INDEPENDENT interp_mips
// checkpoint (ckpt_Y) that was NEVER seeded from the RTL.  Seed the co-sim from
// ckpt_X, run the RTL forward icnt(Y)-icnt(X) retired instructions, then call this:
// if g_mem matches ckpt_Y, the RTL -- driven through the window with all the syncs
// active -- reproduced the oracle's memory, so the TLB/DMA syncs aren't masking a
// bug.  Mismatches are exactly the RTL-vs-oracle divergences the syncs could hide.
// (ss->mem is compared too, but it's fed by the RTL, so it's only a cross-check.)
static const char *g_verify_path = nullptr;
static uint64_t    g_verify_target = 0;   // retired count at which to run the compare
static uint64_t    g_verify_icnt_y = 0;
static int64_t     g_rf[32] = {0};        // RTL architectural regfile shadow (seed + retire)
static void verify_against_checkpoint(const char *path) {
  FILE *f = fopen(path, "rb");
  if(!f) { fprintf(stderr, "[verify] cannot open %s\n", path); return; }
  cp_header h;
  if(fread(&h, 1, sizeof(h), f) != sizeof(h) || h.magic != CKPT_MAGIC) {
    fprintf(stderr, "[verify] bad checkpoint %s\n", path); fclose(f); return; }
  uint32_t rtl_ok=0, rtl_bad=0, iss_ok=0, iss_bad=0, shown=0;
  for(uint32_t i = 0; i < h.num_pages; i++) {
    cp_page p;
    if(fread(&p, 1, sizeof(p), f) != sizeof(p)) break;
    bool bad=false; uint32_t off = fpga_map(p.va, &bad);
    if(!bad) {
      if(memcmp(g_mem + off, p.data, 4096) == 0) rtl_ok++;
      else {
        rtl_bad++;
        if(shown < 10) for(int b=0;b<4096;b+=4) if(memcmp(g_mem+off+b, p.data+b, 4)) {
          fprintf(stderr,"[verify] RTL!=oracle pa=%08x+%03x: g_mem=%02x%02x%02x%02x oracle=%02x%02x%02x%02x\n",
            p.va, b, g_mem[off+b],g_mem[off+b+1],g_mem[off+b+2],g_mem[off+b+3],
            p.data[b],p.data[b+1],p.data[b+2],p.data[b+3]); shown++; break; }
      }
    }
    if(ss) { uint8_t *q = ss->mem.get_raw_ptr(p.va);
             if(memcmp(q, p.data, 4096)==0) iss_ok++; else iss_bad++; }
  }
  fclose(f);
  fprintf(stderr, "[verify] vs %s (oracle icnt=%llu): RTL pages MATCH=%u MISMATCH=%u | ISS match=%u mismatch=%u\n",
          path, (unsigned long long)h.icnt, rtl_ok, rtl_bad, iss_ok, iss_bad);
}

// Compute the verify target (window length) from g_verify_path + the base icnt
// (g_ckpt.icnt, set by load_checkpoint OR load_cimg).  Shared by both resume paths.
static void setup_verify() {
  if(!g_verify_path) return;
  FILE *vf = fopen(g_verify_path, "rb"); cp_header vh;
  if(vf && fread(&vh, 1, sizeof(vh), vf) == sizeof(vh) && vh.magic == CKPT_MAGIC && vh.icnt > g_ckpt.icnt) {
    g_verify_icnt_y = vh.icnt;
    g_verify_target = vh.icnt - g_ckpt.icnt;
    fprintf(stderr, "[verify] will compare g_mem vs %s after %llu retired insns (icnt %llu -> %llu)\n",
            g_verify_path, (unsigned long long)g_verify_target,
            (unsigned long long)g_ckpt.icnt, (unsigned long long)vh.icnt);
  } else { fprintf(stderr, "[verify] bad/earlier verify ckpt -- disabled\n"); g_verify_path = nullptr; }
  if(vf) fclose(vf);
}

// DPI seeds consumed by rf4r2w / fp_regfile (and, once added, exec/tlb) at reset.
extern "C" long long loadgpr(int regid)  { return g_have_ckpt ? g_ckpt.gpr[regid & 31] : 0; }
extern "C" long long loadfpr(int regid)  { return g_have_ckpt ? (long long)g_ckpt.cpr1[regid & 31] : 0; }
extern "C" int       have_checkpoint()   { return g_have_ckpt ? 1 : 0; }
extern "C" int       loadcp0(int reg)    { return g_have_ckpt ? (int)g_ckpt.cpr0[reg & 31] : 0; }
extern "C" long long loadcp0_64(int reg) { return g_have_ckpt ? (long long)g_ckpt.cpr0_64[reg & 31] : 0; }
extern "C" long long loadhilo(int half)  { return g_have_ckpt ? (half ? g_ckpt.hi : g_ckpt.lo) : 0; }
extern "C" int       loadfcsr()          { return g_have_ckpt ? (int)g_ckpt.fcr1[4] : 0; } /* FCR31 = fcr1[4] */
// A/B DIAG (go stale-a0): bug #41 diagnostic, resolved. The RTL DPI import that
// called these was removed, so they are dead -- compile in with -DHENRY_TB_GO_DEBUG.
#ifdef HENRY_TB_GO_DEBUG
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
#endif // HENRY_TB_GO_DEBUG
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
// A checkpoint stores pc as interp's (32-bit va2pa) pc, ZERO-extended for kseg
// addresses (kseg0 0x8801964c -> 0x00000000_8801964c).  The RTL decodes the full
// 64-bit VA, where that is xuseg (mapped) -> a spurious TLB miss on resume.  Sign-
// extend a compat-32 pc (high32==0) so kseg0/1/2/3 resolve; leave a true n64 pc
// (high32!=0) alone.  [reference_32b_to_64b_bugs]
static inline uint64_t ckpt_pc_sext(uint64_t pc) {
  return ((pc >> 32) == 0) ? (uint64_t)(int64_t)(int32_t)pc : pc;
}

static void seed_checker() {
  if(!ss || !g_have_ckpt) return;
  ss->pc = (state_t::reg_t)ckpt_pc_sext((uint64_t)g_ckpt.pc);
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

extern uint64_t g_iss_last_ld_va;   // set by the ISS's va_translate on each load
// Like is_device_load, but for a DELAY-SLOT load that already executed: its base reg
// may be clobbered by a load-to-base (lwu v0,off(v0)), so re-decoding gpr[rs] gives the
// wrong address.  Use the VA the ISS actually translated for this load instead.
static bool ds_is_device_load(uint32_t vpc) {
  if(vpc < 0x80000000u || vpc >= 0xc0000000u) return false;
  uint8_t *p = ss->mem.get_raw_ptr(vpc & 0x1fffffffu);
  uint32_t insn = (uint32_t(p[0])<<24)|(uint32_t(p[1])<<16)|(uint32_t(p[2])<<8)|uint32_t(p[3]);
  uint32_t op = insn >> 26;
  if(!((op >= 0x20 && op <= 0x27) || op == 0x1a || op == 0x1b || op == 0x37)) return false;
  uint32_t ea = (uint32_t)g_iss_last_ld_va;
  uint32_t pa = (ea >= 0x80000000u) ? (ea & 0x1fffffffu) : ea;
  return (pa >= 0x1f000000u) || (ea >= 0xa0000000u && ea < 0xc0000000u);
}

// Compare the ISS's architected result for a retired insn against the RTL, then
// trust the RTL value (keeps the ISS locked; also covers device-MMIO loads).
static void chk_compare(uint32_t vpc, bool rrv, int rrp, uint64_t rrd, bool devload) {
  if(!rrv || rrp == 0) return;
  if((uint64_t)ss->gpr[rrp] != rrd) {
    if(vpc == 0x880099d0u) {  /* wd93dma_flush BC load: dump RTL g_mem vs ISS g_ss_mem @ a2's PA */
      uint32_t pa = (uint32_t)((uint64_t)ss->gpr[6] & 0x1fffffffu);   /* kseg0 a2 -> PA */
      uint32_t base = pa & ~0xfu; bool bad=false; uint32_t off = fpga_map(base, &bad);
      uint8_t *q = ss->mem.get_raw_ptr(base);
      fprintf(stderr, "[wd93] a2=%016llx pa=%08x ISS_v0=%llx RTL_v0=%llx\n  RTL g_mem[%08x]=",
              (unsigned long long)(uint64_t)ss->gpr[6], pa, (unsigned long long)ss->gpr[rrp],
              (unsigned long long)rrd, base);
      for(int i=0;i<16;i++) fprintf(stderr, "%02x%s", g_mem[off+i], (i%4==3)?" ":"");
      fprintf(stderr, "\n  ISS g_ss[%08x]=", base);
      for(int i=0;i<16;i++) fprintf(stderr, "%02x%s", q[i], (i%4==3)?" ":"");
      fprintf(stderr, "\n");
    }
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
  { static const char *ct = getenv("CHKTRACE");           // debug: dump [lo,lo+120) checker steps
    static const uint64_t ctlo = ct ? strtoull(ct, 0, 0) : 0;
    if(ct && g_chk_insns >= ctlo && g_chk_insns < ctlo + 120)
      fprintf(stderr, "[chk %llu] RTL=%08x ISS=%08x rrv=%d rrp=%2d rrd=%016llx  ISSk0=%08x issCause=%08x EPC=%08x badv=%08x\n",
              (unsigned long long)g_chk_insns, vpc, (uint32_t)ss->pc, rrv, rrp,
              (unsigned long long)rrd, (uint32_t)ss->gpr[26], (uint32_t)ss->cpr0[CPR0_CAUSE],
              (uint32_t)ss->cpr0[CPR0_EPC], (uint32_t)ss->cpr0[CPR0_BADVADDR]); }
  if(g_expect_ds && vpc == g_ds_pc) {        // delay slot the ISS already executed
    g_expect_ds = false;
    chk_compare(vpc, rrv, rrp, rrd, is_device_load(vpc) || ds_is_device_load(vpc));  // delay-slot: base may be clobbered
    return;
  }
  g_expect_ds = false;
  // Mapped execution (pc outside kseg0/kseg1: userspace or kseg2/kseg3).  Historically
  // the 1:1 va2pa ISS could not validly execute it (wrong physical memory) so the
  // checker trusted the RTL wholesale -- but then STORES done in mapped code never
  // reached the ISS's memory, and later kseg0 loads read stale data (real divergences
  // downstream).  With the real-TLB ISS the ISS can execute mapped code, keeping its
  // memory in sync.  NOMAPSKIP=1 lets the ISS execute mapped code (default: old skip).
  { static const bool no_mapskip = getenv("NOMAPSKIP") != nullptr;
    if(!no_mapskip && (vpc < 0x80000000u || vpc >= 0xc0000000u)) {
      ss->pc = (state_t::reg_t)(int64_t)rpc;
      if(rrv && rrp != 0) ss->gpr[rrp] = (state_t::reg_t)rrd;
      g_chk_mapped++;
      return;
    }
  }
  bool resynced = false;
  if((uint32_t)ss->pc != vpc) {              // control-flow (PC) divergence
    bool exc_entry = (vpc==0x80000000u || vpc==0x80000080u || vpc==0x80000100u ||
                      vpc==0x80000180u || (vpc>=0xbfc00200u && vpc<=0xbfc00480u));
    if(exc_entry) {
      // The RTL vectored.  ASYNC (timer/device IRQ) = general vector (0x180 / bfc0x380)
      // with ExcCode 0.  Everything else is SYNCHRONOUS -- caused by the faulting
      // instruction the ISS is about to execute (ss->pc): TLB refill (0x000/0x080),
      // TLB-Invalid/Modify/syscall/... (0x180 with ExcCode!=0).
      bool is_async = ((vpc==0x80000180u || (vpc>=0xbfc00200u && vpc<=0xbfc00480u))
                       && g_rtl_cause == 0);
      if(is_async) {
        // Take the interrupt in the ISS: EPC = the interrupted instruction (ss->pc),
        // then snap to the exact RTL vector.  Fall through to execMips the vector's
        // first instruction + compare (clean lockstep, no trust window).
        raise_int(ss, g_rtl_epc, g_rtl_cause_ip);   // exact RTL exception EPC at entry
        ss->pc = (state_t::reg_t)(int64_t)rpc;
      } else {
        // SYNCHRONOUS fault: let the ISS execute the faulting instruction and check it
        // faults to the SAME vector.  If the ISS does NOT fault (or vectors elsewhere)
        // while the RTL did, the RTL's TLB/exception logic disagrees with the golden
        // model -- a real RTL bug (the IRIX o32 crash class).  dsheffie: poke TLB deltas.
        uint32_t fpc = (uint32_t)ss->pc;
        execMips(ss);
        g_chk_insns++;
        if((uint32_t)ss->pc == vpc) {
          // ISS agrees -- same fault, same vector.  Fall through: execMips runs the
          // vector's first instruction and compares (stay locked, no trust window).
        } else {
          if(g_tlb_delta_shown < 400) {
            fprintf(stderr, "[TLB-DELTA] fpc=%08x  RTL vectored %08x (cause=%u badv=%016llx)  but ISS->%08x  chk#%llu\n",
                    fpc, vpc, g_rtl_cause, (unsigned long long)g_rtl_badv,
                    (uint32_t)ss->pc, (unsigned long long)g_chk_insns);
            g_tlb_delta_shown++;
          }
          ss->pc = (state_t::reg_t)(int64_t)rpc;  // snap to RTL, trust while state re-converges
          // The RTL took a fault the ISS did NOT (e.g. a CACHE op on a mapped addr, which
          // the ISS models as a NOP).  The ISS never ran set_exc_pc, so its EPC is stale;
          // seed it with the RTL's fault EPC ONCE so the RTL's refill/exception handler
          // (now run under trust) reads the right EPC + erets correctly.  This is the
          // exception-entry EPC seed that the removed continuous force-sync used to cover.
          ss->cpr0[14] = g_rtl_epc; ss->cpr0_64[14] = g_rtl_epc;
          g_chk_resync++; resynced = true; g_settle = 16;
        }
      }
    } else {
      // MAIN-LINE (non-exception) PC divergence: a real wrong-PC bug (bad eret target,
      // mis-resolved branch, spurious/missed exception) or accumulated staleness.
      static int shown = 0;
      if(shown < 200) {
        fprintf(stderr, "[checker] PC-DIVERGE ISS=%08x RTL=%08x [MAIN-LINE!] after %llu checked\n",
                (uint32_t)ss->pc, vpc, (unsigned long long)g_chk_insns);
        shown++;
      }
      ss->pc = (state_t::reg_t)(int64_t)rpc;
      g_chk_resync++; resynced = true; g_settle = 16;
    }
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
  std::string kernel, arcs, ckpt_file, cimg_file, iss_seed_file;
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
    else if(a == "--cimg" && i+1 < argc)   cimg_file = argv[++i];
    else if(a == "--verify-ckpt" && i+1 < argc) g_verify_path = argv[++i];
    else if(a == "--checker")              g_checker = true;
    else if(a == "--iss-seed" && i+1 < argc) iss_seed_file = argv[++i];
  }
  std::vector<uint8_t> rx_bytes(rx_str.begin(), rx_str.end());
  if(kernel.empty() && ckpt_file.empty() && cimg_file.empty()) { fprintf(stderr, "usage: %s {--kernel <elf> | --checkpoint <file> | --cimg <file> --arcs <preamble>} [--maxcyc N]\n", argv[0]); return 1; }

  g_mem = (uint8_t*)mmap(nullptr, MEM_SIZE, PROT_READ|PROT_WRITE,
                         MAP_PRIVATE|MAP_ANONYMOUS|MAP_NORESERVE, -1, 0);
  if(g_mem == MAP_FAILED) { perror("mmap ram"); return 1; }

  // Lockstep checker: create the golden ISS now so load_checkpoint can seed its
  // (PA-indexed) memory, matching the interp's va2pa output.
  if(g_checker) {
    g_ss_mem = new sparse_mem();
    g_ss_mem->route_devices = true;   // IP22 System Memory Alias (PA<512KB -> DRAM 0x08000000)
    ss = new state_t(*g_ss_mem);
    initState(ss);
    g_iss_tlb_ext = true;   // ISS TLB is written solely by the RTL mirror (below)
    g_iss_os_mode = true;   // SYSCALL/BREAK trap to 0x180 like the RTL (not halt) -- IRIX userspace
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
    for(int i = 0; i < 32; i++) g_rf[i] = g_ckpt.gpr[i];   // seed RTL regfile shadow
    seed_checker();
    setup_verify();
  } else if(!cimg_file.empty()) {
    // silicon-style resume: .cimg pages -> g_mem (ARM's job), + the 'preamble' arcs blob
    // (ckpt2preamble.py) restores regs/CP0/TLB and ERETs to the checkpoint PC.  NO DPI.
    load_cimg(cimg_file.c_str());
    if(g_checker && !iss_seed_file.empty()) {   // seed the golden ISS regs/CP0/TLB, then gate
      FILE *sf = fopen(iss_seed_file.c_str(), "rb");
      if(sf && fread(&g_ckpt, 1, sizeof(g_ckpt), sf) == sizeof(g_ckpt) && g_ckpt.magic == CKPT_MAGIC) {
        g_have_ckpt = true; seed_checker();
        g_chk_gate_pc = (uint32_t)g_ckpt.pc; g_chk_active_gate = false;
        fprintf(stderr, "[iss-seed] ISS seeded from %s; lockstep gated until pc=%08x\n", iss_seed_file.c_str(), g_chk_gate_pc);
      } else fprintf(stderr, "[iss-seed] FAILED to read %s\n", iss_seed_file.c_str());
      if(sf) fclose(sf);
    }
    if(arcs.empty()) { fprintf(stderr, "--cimg needs --arcs <preamble.bin>\n"); return 1; }
    load_blob(arcs.c_str(), arcs_addr);   // preamble @0x1fc00000 (reset vector fetches it)
    entry = kentry = start_pc ? start_pc : 0xbfc00000u;
    setup_verify();   // g_ckpt.icnt was set by load_cimg; target offset by the preamble below
    fprintf(stderr, "[cimg] preamble-resume: RTL boots @0x%08x, preamble installs state\n", (uint32_t)entry);
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
                                           : ckpt_pc_sext((uint64_t)g_ckpt.pc);

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
  uint32_t req_owner = 0;   // arbiter grant latched at accept: 0=CPU 1=DMA
  uint32_t req_phys  = 0;   // 29-bit GUEST phys latched at accept (for the ISS-mem mirror)
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
  // No-retire watchdog: if the core goes this many cycles without retiring an
  // instruction it is wedged (e.g. the ip22_eeprom_read deadlock) -- bail out with
  // a diagnostic instead of spinning to --maxcyc. 0 disables. Env NO_RETIRE_LIMIT.
  const uint64_t NO_RETIRE_LIMIT = getenv("NO_RETIRE_LIMIT") ? strtoull(getenv("NO_RETIRE_LIMIT"), nullptr, 0) : 65536;
  uint64_t retired = 0, last_pc = 0, last_retire_cyc = 0;
  bool deadlock = false;
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
#ifdef HENRY_TB_GO_DEBUG
    g_probe_cyc = cyc;  // A/B DIAG: expose cyc to dpi_a0_probe
#endif
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

    if(tb->retire_valid) { retired++; last_pc = tb->retire_pc; last_retire_cyc = cyc; g_cur_retire_pc = tb->retire_pc; }
    else if(NO_RETIRE_LIMIT && (cyc - last_retire_cyc) > NO_RETIRE_LIMIT) {
      fprintf(stderr, "[tb] NO-RETIRE WATCHDOG: %llu cycles with no retirement "
              "(cyc=%llu retired=%llu last_pc=0x%llx head_pc=0x%08x head_status=0x%02x). WEDGED.\n",
              (unsigned long long)(cyc - last_retire_cyc), (unsigned long long)cyc,
              (unsigned long long)retired, (unsigned long long)last_pc,
              (uint32_t)tb->dbg_head_pc, (uint32_t)tb->dbg_head_status);
      deadlock = true; halted = true;
    }

    if(tb->retire_valid && tb->retire_reg_valid) g_rf[tb->retire_reg_ptr & 31] = tb->retire_reg_data;
    if(tb->retire_two_valid && tb->retire_reg_two_valid) g_rf[tb->retire_reg_two_ptr & 31] = tb->retire_reg_two_data;

    { /* PRFAULT_PROBE=<file>: comprehensive capture, hypothesis-agnostic. Keep a
       * ring of the last N retired (pc,reg,data); when IRIX's trap sees prfault
       * RETURN A SIGNAL (retire 0x880f30fc `beqz a5,...` with a5(=r9,n32)!=0 ==
       * the fault it could NOT resolve -> SIGSEGV), dump the ring + a5(signal)/
       * s4(faultaddr,r20)/s1(proc,r17). The ring holds prfault's whole execution
       * + its VM-state loads, so we can see WHY it failed regardless of theory.
       * Fires only on a prfault failure (rare) -> tiny; last dump = the coredump. */
      static const char *pf_name = getenv("PRFAULT_PROBE");
      static const uint64_t RN = 400000;
      static uint32_t *r_pc = pf_name ? new uint32_t[RN] : nullptr;
      static int8_t   *r_rg = pf_name ? new int8_t[RN]   : nullptr;
      static uint64_t *r_dt = pf_name ? new uint64_t[RN] : nullptr;
      static uint64_t r_i = 0;
      static FILE *pf = pf_name ? fopen(pf_name, "w") : nullptr;
      static uint64_t n_fail = 0;
      if(pf) {
        auto rec = [&](uint32_t pc, bool rv, int rp, uint64_t rd){
          r_pc[r_i%RN] = pc; r_rg[r_i%RN] = (rv && (rp&31)) ? (rp&31) : -1;
          r_dt[r_i%RN] = rd; r_i++; };
        if(tb->retire_valid)     rec((uint32_t)tb->retire_pc, tb->retire_reg_valid, tb->retire_reg_ptr, tb->retire_reg_data);
        if(tb->retire_two_valid) rec((uint32_t)tb->retire_two_pc, tb->retire_reg_two_valid, tb->retire_reg_two_ptr, tb->retire_reg_two_data);
        bool hit_trig = (tb->retire_valid && (uint32_t)tb->retire_pc == 0x880f30fcu)
                     || (tb->retire_two_valid && (uint32_t)tb->retire_two_pc == 0x880f30fcu);
        if(hit_trig && (g_rf[9] & 0xffffffffull) != 0) {
          n_fail++;
          fprintf(pf, "\n=== PRFAULT-FAIL #%llu cyc=%llu  a5/signal=%lld  s4/faultaddr=%llx  s1/proc=%llx  (last %llu retires) ===\n",
                  (unsigned long long)n_fail, (unsigned long long)cyc, (long long)g_rf[9],
                  (unsigned long long)g_rf[20], (unsigned long long)g_rf[17],
                  (unsigned long long)(r_i < RN ? r_i : RN));
          uint64_t start = (r_i > RN) ? (r_i - RN) : 0;
          for(uint64_t k = start; k < r_i; k++)
            fprintf(pf, "%x %d %llx\n", r_pc[k%RN], (int)r_rg[k%RN], (unsigned long long)r_dt[k%RN]);
          fflush(pf);
        }
      }
    }

    { /* BADVA_PROBE: on each new cause-2/3 (TLB L/S) fault, re-derive the faulting
       * EA = base_reg + offset from the load/store at EPC (delay-slot aware) and
       * compare to the RTL's BadVAddr at 8KB granularity -- exactly IRIX's
       * badva_isbogus test (0x880f6f30). A mismatch => the RTL's hardware BadVAddr
       * (or the base reg) disagrees with the instruction => IRIX SIGSEGVs. Logs
       * only on mismatch, so it's tiny. Reads insn only for kseg0/1 EPC. */
      static const bool bvp = getenv("BADVA_PROBE") != nullptr;
      static uint64_t prev_key = ~0ull;
      if(bvp) {
        uint32_t cause = (uint32_t)tb->cause;
        uint64_t key = (tb->epc << 6) ^ (uint64_t)cause ^ (tb->badvaddr << 20);
        if((cause == 2 || cause == 3) && key != prev_key) {
          prev_key = key;
          uint32_t epc = (uint32_t)tb->epc;
          uint64_t badv = tb->badvaddr;
          auto rdi = [&](uint32_t va, bool *ok)->uint32_t {
            if(va >= 0x80000000u && va < 0xc0000000u) { bool bad=false; uint32_t o=fpga_map(va & 0x1fffffffu, &bad); *ok=!bad; return bad?0:be32(g_mem+o); }
            *ok=false; return 0; };
          bool ok=false; uint32_t insn = rdi(epc, &ok);
          uint32_t fpc = epc;
          if(ok) {
            uint32_t op = insn >> 26;
            bool is_br = (op==0 && ((insn&0x3f)==8 || (insn&0x3f)==9)) /* jr/jalr */
                       || op==1 /* regimm b* */ || (op>=2 && op<=7) || (op>=0x14 && op<=0x17);
            if(is_br) { bool ok2=false; uint32_t d=rdi(epc+4,&ok2); if(ok2){ insn=d; fpc=epc+4; } }
            op = insn >> 26;
            bool is_mem = (op>=0x20 && op<=0x2e) || op==0x30 || op==0x31 || op==0x34
                       || op==0x35 || op==0x37 || op==0x38 || op==0x39 || op==0x3c || op==0x3d || op==0x3f;
            if(is_mem) {
              int base = (insn >> 21) & 31;
              int64_t off = (int64_t)(int16_t)(insn & 0xffff);
              uint64_t ea = (uint64_t)g_rf[base] + off;
              if((ea & ~0x1fffull) != (badv & ~0x1fffull)) {
                static const char *rn[32]={"r0","at","v0","v1","a0","a1","a2","a3","a4","a5","a6","a7","t0","t1","t2","t3","s0","s1","s2","s3","s4","s5","s6","s7","t8","t9","k0","k1","gp","sp","s8","ra"};
                fprintf(stderr, "[BADVA] cyc=%llu MISMATCH cause=%u epc=%08x fpc=%08x insn=%08x base=%s(%016llx) off=%lld => ea=%016llx  vs RTL badv=%016llx  (diff=%lld)\n",
                        (unsigned long long)cyc, cause, epc, fpc, insn, rn[base],
                        (unsigned long long)g_rf[base], (long long)off,
                        (unsigned long long)ea, (unsigned long long)badv, (long long)(ea - badv));
              }
            }
          }
        }
      }
    }

#ifdef HENRY_TB_TRACE
    { /* RTLTRACE=<file>: per-retired-insn "pc reg val" (interp valt format) for
       * offline diff vs interp --restore --valt/--pctraceout. Starts after
       * RTLTRACE_PC (the ckpt pc) first retires; RTLTRACE_N caps the line count.
       * reg = -1 unless a non-r0 GPR was written (matches interp's changed-reg
       * convention). RTLTRACE_USERONLY = only pc<0x80000000; RTLTRACE_KTLB also
       * captures the locore TLB handlers. Build with -DHENRY_TB_TRACE to enable
       * (off by default -- this is the co-sim retire-trace infra). */
      static const char *tf = getenv("RTLTRACE");
      static FILE *rf = tf ? fopen(tf, "w") : nullptr;
      static const uint32_t startpc = getenv("RTLTRACE_PC") ? (uint32_t)strtoull(getenv("RTLTRACE_PC"),0,0) : 0;
      static const uint64_t cap = getenv("RTLTRACE_N") ? strtoull(getenv("RTLTRACE_N"),0,0) : 40000000ULL;
      static const bool useronly = getenv("RTLTRACE_USERONLY") != nullptr;  /* emit only pc<0x80000000 */
      static const bool ktlb = getenv("RTLTRACE_KTLB") != nullptr;  /* also capture kernel TLB-handler ranges */
      static bool armed = (startpc == 0);
      static uint64_t emitted = 0;
      auto emit1 = [&](uint32_t pc, bool rv, int rp, uint64_t rd) {
        /* emit userspace (pc<0x80000000) always; with RTLTRACE_KTLB also emit the
         * exception vectors + locore TLB handlers, so a full boot records the PTE
         * the tlb_mod handler loads at 0x88013d20 and whether it takes the V=0
         * SEGV path (0x88013e20). Without RTLTRACE_USERONLY/KTLB, emit everything. */
        bool khandler = (pc >= 0x80000000u && pc < 0x80000240u) ||
                        (pc >= 0x88002000u && pc < 0x88015000u);
        if(useronly && pc >= 0x80000000u && !(ktlb && khandler)) return;
        int reg = (rv && (rp & 31)) ? (rp & 31) : -1;
        fprintf(rf, "%x %d %llx\n", pc, reg, (unsigned long long)(reg<0?0:rd)); emitted++;
      };
      if(rf && emitted < cap) {
        if(tb->retire_valid) {
          if(!armed && (uint32_t)tb->retire_pc == startpc) armed = true;
          if(armed) emit1((uint32_t)tb->retire_pc, tb->retire_reg_valid, tb->retire_reg_ptr, tb->retire_reg_data);
        }
        if(tb->retire_two_valid && armed && emitted < cap)
          emit1((uint32_t)tb->retire_two_pc, tb->retire_reg_two_valid, tb->retire_reg_two_ptr, tb->retire_reg_two_data);
      }
    }
#endif // HENRY_TB_TRACE

    { // PCHASH: rolling FNV-1a over retired PCs (older retire_pc, then younger
      // retire_two_pc), matched to interp_mips's per-icnt hash to find the first
      // RTL/ISS PC divergence.  Independent of --checker.
      static const bool g_pchash = getenv("PCHASH") != nullptr;
      if(g_pchash) {
        static uint64_t h = 1469598103934665603ULL, n = 0;
        static const char *pd = getenv("PCDUMP");   // "lo:hi" -> raw "P <pc>" for structural diff
        static uint64_t pd_lo = 0, pd_hi = 0; static bool pd_init = false;
        if(!pd_init) { pd_init = true; if(pd) sscanf(pd, "%lu:%lu", &pd_lo, &pd_hi); }
        if(tb->retire_valid) {
          h = (h ^ (uint32_t)tb->retire_pc) * 1099511628211ULL; n++;
          if((n & 0xffff) == 0)
            fprintf(stderr, "[pchash] icnt=%llu hash=%016llx pc=%08x\n",
                    (unsigned long long)n, (unsigned long long)h, (uint32_t)tb->retire_pc);
          if(pd && n >= pd_lo && n < pd_hi) fprintf(stderr, "P %08x\n", (uint32_t)tb->retire_pc);
        }
        if(tb->retire_two_valid) {
          h = (h ^ (uint32_t)tb->retire_two_pc) * 1099511628211ULL; n++;
          if((n & 0xffff) == 0)
            fprintf(stderr, "[pchash] icnt=%llu hash=%016llx pc=%08x\n",
                    (unsigned long long)n, (unsigned long long)h, (uint32_t)tb->retire_two_pc);
          if(pd && n >= pd_lo && n < pd_hi) fprintf(stderr, "P %08x\n", (uint32_t)tb->retire_two_pc);
        }
      }
    }
    { static const char *pe = getenv("PREAMBLE_PC");   // preamble-resume: report first hit of the ckpt PC
      static const uint32_t pc = pe ? (uint32_t)strtoull(pe,0,0) : 0;
      static bool hit = false;
      if(pc && !hit && tb->retire_valid && (uint32_t)tb->retire_pc == pc) {
        hit = true;
        if(g_verify_path) g_verify_target += retired;   // don't count the preamble's own insns
        fprintf(stderr, "[preamble] REACHED ckpt pc=%08x after %llu retired (state restored; verify@%llu)\n",
                pc, (unsigned long long)retired, (unsigned long long)g_verify_target);
      } }
    if(g_verify_path && retired >= g_verify_target) {
      fprintf(stderr, "[verify] reached %llu retired insns @cyc=%llu rtl_pc=%016llx -- comparing\n",
              (unsigned long long)retired, (unsigned long long)cyc, (unsigned long long)tb->retire_pc);
      verify_against_checkpoint(g_verify_path);
      break;
    }
    { static const bool sd = getenv("SPINDBG") != nullptr;   // trace the 0x880e1b40 poll loop
      static int sn = 0;
      if(sd && tb->retire_valid && (uint32_t)tb->retire_pc == 0x880e1b40 && (sn++ & 0x3fff) == 0) {
        uint32_t a2 = (uint32_t)g_rf[6];
        auto rd = [&](uint32_t va)->uint32_t { uint32_t pa=(va>=0x80000000u&&va<0xc0000000u)?(va&0x1fffffff):va;
          bool bad=false; uint32_t o=fpga_map(pa,&bad); return bad?0xbadf00du:be32(g_mem+o); };
        fprintf(stderr, "[spin] cyc=%llu a2=%08x [a2+0]=%08x [a2+16]=%08x [a2+128]=%08x  gp=%08x ra=%08x\n",
                (unsigned long long)cyc, a2, rd(a2), rd(a2+16), rd(a2+128),
                (uint32_t)g_rf[28], (uint32_t)g_rf[31]);
      } }

    // ---- full-GPR snapshot at the near-NULL store fault. go SIGSEGVs at
    // `sw zero,0(v0)` (delay slot @0x120024dd4, EPC=branch 0x120024dd0),
    // v0 = a5(r9) + ((s2(r18)+s0(r16))<<2). a5 committed-good, so the index or a
    // read-side clobber is the culprit -- dump every committed GPR + last-writer
    // PC so we can compute exactly where v0 went to 4. ----
    // (bug #41 diagnostic, resolved; compile in with -DHENRY_TB_GO_DEBUG)
#ifdef HENRY_TB_GO_DEBUG
    {
      static uint64_t g_gpr[32] = {0}, g_gpr_pc[32] = {0};
      if(tb->retire_valid && tb->retire_reg_valid) { int r=tb->retire_reg_ptr; g_gpr[r]=tb->retire_reg_data; g_gpr_pc[r]=tb->retire_pc; }
      if(tb->retire_two_valid && tb->retire_reg_two_valid) { int r=tb->retire_reg_two_ptr; g_gpr[r]=tb->retire_reg_two_data; g_gpr_pc[r]=tb->retire_two_pc; }
      // retire ring: last 256 retired (pc, reg, data) per port, to reconstruct
      // the exact dynamic path into the faulting store.
      static uint64_t g_ring_pc[256]; static int g_ring_reg[256]; static uint64_t g_ring_d[256]; static int g_ri=0;
      if(tb->retire_valid) { g_ring_pc[g_ri&255]=tb->retire_pc; g_ring_reg[g_ri&255]=tb->retire_reg_valid?tb->retire_reg_ptr:-1; g_ring_d[g_ri&255]=tb->retire_reg_data; g_ri++; }
      if(tb->retire_two_valid) { g_ring_pc[g_ri&255]=tb->retire_two_pc; g_ring_reg[g_ri&255]=tb->retire_reg_two_valid?tb->retire_reg_two_ptr:-1; g_ring_d[g_ri&255]=tb->retire_reg_two_data; g_ri++; }
      static int g_fault_seen = 0;
      bool hit = ((tb->epc & 0xffffffffffull) == 0x120024dd0ull) && (tb->cause == 3) && (tb->badvaddr <= 0x1000ull);
      if(hit && !g_fault_seen) {
        static const char *nm[32]={"r0","at","v0","v1","a0","a1","a2","a3","a4","a5","a6","a7","t0","t1","t2","t3","s0","s1","s2","s3","s4","s5","s6","s7","t8","t9","k0","k1","gp","sp","s8","ra"};
        fprintf(stderr, "[gpr!] cyc=%llu near-NULL store (badv=0x%llx). committed GPRs:\n", (unsigned long long)cyc, (unsigned long long)tb->badvaddr);
        for(int r=0;r<32;r++)
          fprintf(stderr, "   %s(r%d)=0x%llx  (wr@0x%llx)\n", nm[r], r, (unsigned long long)g_gpr[r], (unsigned long long)g_gpr_pc[r]);
        fprintf(stderr, "[ring] last 200 retired (pc reg<=data):\n");
        for(int k=200;k>=1;k--){ int i=(g_ri-k)&255; if(!g_ring_pc[i]) continue;
          if(g_ring_reg[i]>=0) fprintf(stderr, "   0x%08llx  r%d<=0x%llx\n", (unsigned long long)(g_ring_pc[i]&0xffffffffffull), g_ring_reg[i], (unsigned long long)g_ring_d[i]);
          else fprintf(stderr, "   0x%08llx\n", (unsigned long long)(g_ring_pc[i]&0xffffffffffull)); }
      }
      g_fault_seen = hit;
    }
#endif // HENRY_TB_GO_DEBUG

    // monitor `step N`: re-pause once N more instructions have retired
    if(g_mon_step_to && retired >= g_mon_step_to) {
      g_mon_paused = true; g_mon_step_to = 0;
      char b[128]; snprintf(b, sizeof(b), "[stepped] retired=%llu rtl_pc=%016llx\r\nmon> ",
                            (unsigned long long)retired, (unsigned long long)tb->retire_pc);
      mon_send(b);
    }

    // ---- lockstep co-sim checker (mirrors r9999/top.cc:686-800) ----
    if(g_checker && ss && !g_chk_active_gate && tb->retire_valid && (uint32_t)tb->retire_pc == g_chk_gate_pc) {
      g_chk_active_gate = true;   // preamble-resume: lockstep starts at the ckpt PC (skip preamble)
      seed_checker();             // RE-SEED the ISS at the ckpt state now (undo any boot-seed during the preamble)
      fprintf(stderr, "[checker] lockstep ACTIVE + ISS re-seeded at ckpt pc=%08x\n", g_chk_gate_pc);
    }
    if(g_checker && ss && g_chk_active_gate) {
      ss->cpr0[CPR0_COUNT] = (uint32_t)tb->cp0_count;      // keep mfc0 $9 in sync
      // Track the RTL's exception CP0 regs so the ISS's handler control-flow
      // follows the RTL (the co-sim scope is GPRs/data, not CP0 modeling).
      // DO NOT continuously force EPC: tb->epc is the core's EXCEPTION EPC (frozen at
      // fault time), NOT the CP0 EPC register.  A handler that does `mtc0 EPC` to set a
      // nested/context-switch return address (e.g. TLBL in dnlc_enter_fast -> reschedule
      // -> return to sthread_launch) updates the CP0 EPC, but forcing ss EPC=tb->epc each
      // cycle CLOBBERS that restore -> the ISS erets to the stale fault PC (the chk#16.1M
      // wall).  The ISS self-manages EPC via its own set_exc_pc (sync faults) + raise_int
      // (async) + mtc0/eret -- same as Status below.  (was: ss->cpr0[14]=tb->epc)
      g_rtl_epc = (uint32_t)tb->epc;   // still tracked, for raise_int's async entry EPC
      // NOTE: do NOT force Status here -- the ISS must see its OWN pre-fault EXL so
      // exc_vector picks the refill vector (0x000/0x080) vs general (0x180) correctly.
      // (Forcing EXL=1 post-fault made the ISS pick 0x180 -> false TLB-DELTAs.)  The
      // ISS self-manages Status via mtc0/eret; its exceptions set BadVAddr/EPC too.
      ss->cpr0[8]  = (uint32_t)tb->badvaddr; ss->cpr0_64[8]  = tb->badvaddr;   // BadVAddr
      g_rtl_cause  = (uint32_t)tb->cause;    g_rtl_badv = tb->badvaddr;         // exc ctx for checker_step
      g_rtl_cause_ip = (uint32_t)tb->cause_ip;                                   // real IP bits for raise_int
      // Continuously mirror Cause.IP[7:0] (bits 15:8) from the RTL's w_ip: the ISS
      // only models the software IP bits (its own mtc0 Cause) and never the timer/
      // device bits, so an ISR that re-reads Cause.IP to dispatch would diverge.
      // Preserve the ISS's own ExcCode/BD (only overwrite the IP field).
      ss->cpr0[13] = (ss->cpr0[13] & ~0x0000ff00u) | (((uint32_t)tb->cause_ip & 0xffu) << 8);
      // IRQ + synchronous exceptions are now taken inside checker_step at the vector
      // retire (clean lockstep + TLB-exception-delta detection), not via a premature
      // raise_int on the took_irq commit cycle.
      if(tb->retire_valid)
        checker_step(tb->retire_pc, tb->retire_reg_valid, tb->retire_reg_ptr, tb->retire_reg_data);
      drain_store_check();
      if(g_store_diverged) {
        static const bool no_sc_stop = getenv("NOSTORECHECK") != nullptr;
        fprintf(stderr, "[STORE-CHECK] store divergence\n");
        if(!no_sc_stop) break;
        g_store_diverged = false;   // shotgun: keep the GPR/PC checker running the full window
      }
      if(tb->retire_two_valid)
        checker_step(tb->retire_two_pc, tb->retire_reg_two_valid, tb->retire_reg_two_ptr, tb->retire_reg_two_data);
      // Apply the RTL's TLBWI/TLBWR writes (lossless FIFO) -- the SOLE writer of the ISS TLB
      // (the ISS's own tlbwi/tlbwr are suppressed via g_iss_tlb_ext), so the two 48-entry TLBs
      // stay bit-identical.  A single-entry buffer dropped back-to-back wirepda writes -> the
      // ISS missed the wired PDA entry -> spurious refill; the queue fixes it.
      while(ss && !g_pend_tlb.empty()) {
        const pend_tlb_t &p = g_pend_tlb.front();
        iss_apply_tlb_write(ss, p.idx, p.ehi, p.elo0, p.elo1, p.pm);
        g_pend_tlb.pop_front();
      }
    }

    // ---- go a0-corruption trace (approach B checkpoint; diagnostic) ----
    // (bug #41 diagnostic, resolved; compile in with -DHENRY_TB_GO_DEBUG)
#ifdef HENRY_TB_GO_DEBUG
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
#endif // HENRY_TB_GO_DEBUG

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
      else if(g_stream_pos >= g_total && (g_pos + g_chunk >= g_total)) {
        // SHORT READ: all data streamed on the final chunk, but the descriptor
        // byte-count exceeds it (e.g. INQUIRY: 36 bytes into a 64-byte BC), so the
        // engine stalls in S_R_DISK and never pulses dma_done.  Post the completion
        // now so the shim's ((scsi_rsp_seq==r_req_seq) & dma_rd_stalled) branch aborts
        // the stalled engine -- otherwise CIP|BSY stay set (aux=0x30) and the driver
        // hangs forever (later wedging wd93reset's CIP-wait poll).  Matches the
        // non-FAITHFUL path's post-on-drain, which this rewrite dropped.
        g_pos = g_total; g_streaming = false; g_active = false;
        g_pending_rsp.completion = SCSI_DONE_COMPLETE;
        g_pending_rsp.scsi_status = ST_SELECT_TRANSFER_SUCCESS;
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
      req_phys    = phys;                       // latch guest-PA for the checker ISS-mem mirror
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
      req_op    = tb->mem_req_opcode;
      req_mask  = tb->mem_req_mask;
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
        static const bool descwatch = getenv("DESCWATCH") != nullptr;
        if(descwatch) {
          uint32_t la = (uint32_t)((req_addr & MEM_MASK) & 0x0ffffff0u);
          if(la == 0x003e4000u || la == 0x083e4000u || req_sd[0] == 0x883e4800u)
            fprintf(stderr, "[descwr] cyc=%llu owner=%s addr=%08llx mask=%04x d=%08x %08x %08x %08x\n",
                    (unsigned long long)cyc, req_owner ? "DMA" : "CPU",
                    (unsigned long long)(req_addr & MEM_MASK),
                    (unsigned)req_mask, req_sd[0], req_sd[1], req_sd[2], req_sd[3]);
        }
        for(int i = 0; i < 16; i++) {
          if((req_mask >> i) & 1) {
            uint64_t a = (req_addr + i) & MEM_MASK;
            uint8_t  by = (req_sd[i>>2] >> (8*(i&3))) & 0xff;
            if(req_is_halt && by)
              halted = true;
            g_mem[a] = by;
            /* Checker: keep the golden ISS memory RTL-authoritative for CONTENT.
             * req_owner is a dead stub (no RTL owner signal), so we cannot tell DMA
             * from CPU writes here -- but mirroring ALL opcode-7 writes is safe: a
             * CPU-store divergence is caught by drain_store_check's queue value-compare
             * (pc+addr+data) BEFORE this mirror, and DMA payload is deterministic disk
             * content that cannot mask the TLB/context-switch bug.  This closes the DMA
             * co-sim gap (disk-loaded code/data the ISS otherwise never sees). */
            if(g_checker && g_ss_mem)
              *g_ss_mem->get_raw_ptr((uint64_t)req_phys + i) = by;
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
    { static const bool g_do_tip = getenv("TIP") != nullptr;   // commit-stall attribution
      if(g_do_tip) {
        if(tb->retire_valid || tb->retire_two_valid) {
          double total = (double)(tb->retire_valid ? 1 : 0) + (double)(tb->retire_two_valid ? 1 : 0);
          if(tb->retire_valid) { g_tip[(uint32_t)tb->retire_pc] += 1.0 / total; }
          if(tb->retire_two_valid) { g_tip[(uint32_t)tb->retire_two_pc] += 1.0 / total; }
        }
        else { g_tip[(uint32_t)tb->dbg_head_pc] += 1.0; }   // stalled: charge the ROB head
      }
    }
    if(cyc && (cyc % (1UL<<24)) == 0) {
      tip_dump("periodic");
      fprintf(stderr, "[tb] cyc %llu  retired %llu  last_pc 0x%llx  head_pc 0x%llx  "
              "cause=%u epc=0x%llx badv=0x%llx sr=0x%08x irq=%u\n",
              (unsigned long long)cyc, (unsigned long long)retired,
              (unsigned long long)last_pc, (unsigned long long)tb->dbg_head_pc,
              (unsigned)tb->cause, (unsigned long long)tb->epc,
              (unsigned long long)tb->badvaddr, (unsigned)tb->status_reg, (unsigned)tb->took_irq);
    }
    if(tb->got_bad_addr) { printf("\n[tb] got_bad_addr at cycle %llu\n", (unsigned long long)cyc); }
  }

  tip_dump("final");
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
  printf("\n[tb] %s\n", deadlock ? "NO-RETIRE WATCHDOG tripped (wedged)"
                        : halted ? "halted (magic-halt store)" : "reached max cycles");
  for(uint64_t pa : dump_pas) dump_pa(pa);
  if(trace) { fclose(trace); fprintf(stderr, "[tb] wrote retired-PC trace to %s\n", trace_file.c_str()); }
  delete tb;
  return 0;
}
