// -----------------------------------------------------------------------------
// henry_soc.sv -- Henry IP22 SoC top level.
//
// Wraps the r9999 core (core_l1d_l1i) and integrates RTL models of the IP22
// devices, structured to roughly match the real Indy chips:
//   * mc.sv   -- memory controller    @ phys 0x1fa00000
//   * hpc3.sv -- HPC3 peripheral ctlr  @ phys 0x1fb80000 .. 0x1fbfffff
//   * ioc.sv  -- IOC2 (SYSID + Z8530 SCC console) @ phys 0x1fbd9800 .. 0x1fbd98ff
//
// The core's L2-miss memory bus (mem_req_*/mem_rsp_*, 16-byte cache lines) flows
// through this module.  Requests that decode to a device are routed to that
// device's slave (a common interface: sel/is_store/offs/mask/wdata -> rdata; each
// device handles its own per-word/byte access).  Everything else is PASSED
// THROUGH unchanged to the external memory bus (-> RAM/AXI/cosim).
//
// Memory protocol (from r9999 top.cc): opcode==4 is a 16-byte line load (return
// four words), else a store gated by the 16-bit byte mask; mem_req_addr is
// 16-byte aligned; one request outstanding; mem_rsp_valid pulses the result.
//
// Console: the SCC UART TX (from ioc.sv) and the core's CP0-reg7 putchar stream
// are merged into one SoC-owned FIFO on the putchar_fifo_* port.
// -----------------------------------------------------------------------------
`include "machine.vh"

// WD33C93 + HPC3 SCSI control shim (scsi_shim.sv); the ARM serves the disk image
// through the staging rings.  MUTUALLY EXCLUSIVE with hpc3.sv `ENABLE_HPC3_DMA
// (off) -- both claim the HPC3 DMA channel window @0x10000.
// Seeq 8003 + HPC3 ENET DMA control shim (enet_shim.sv).  Shares the HPC3 window
// with scsi_shim (disjoint offsets); ENET IRQ -> IOC2 local0 bit3; MC DMA -> local0 bit4.
// Device data moves through the staging rings (docs/arm-device-protocol.md): the
// ARM never touches guest memory.  dma_engine walks the ENET and SCSI descriptor
// chains and moves their data (one memory port, one byte mover).  It reaches memory
// through a dma_snoop_shim (PRE-WBINV / access / POST-WBINV on the core's
// inclusive-L2 snoop port), so an r9999 with the WBINV snoop port is required.
// The SCSI command itself still goes through the scsi_req_*/scsi_rsp_* mailbox.

module henry_soc
  #(// MC MEMCFG0 (bank0 cfg) as STORED: BE lw -> bswap.  0x0000203f -> 0x3f200000
    // = 128 MB @ 0x08000000 (IRIX); was 0x00002023 -> 0x23200000 = 16 MB.
    parameter [31:0] MEMCFG0 = 32'h0000_203f
    )
  (input  logic                  clk,
   input  logic                  reset,

   // debug control (wired from the AXI control reg; previously stubbed off)
   input  logic                  single_step,
   input  logic                  step,
   // HW_TOPDOWN counters (r9999 core_l1d_l1i): pmu_value follows pmu_sel two cycles later
   input  logic [4:0]            pmu_sel,
   output logic [47:0]           pmu_value,
   input  logic                  bp_enable,     // arms the resettable fault-trap
   input  logic                  fault_clear,   // clear fault-trap latch + re-arm + un-freeze
   input  logic [31:0]           bp_pc,         // driver-programmable breakpoint PC
   input  logic [31:0]           bp_wp_addr,    // driver-programmable store-address watchpoint VA
   input  logic [31:0]           bp_wp_val,     // expected corrupt store value (freeze-on)
   input  logic                  bp_fault_only, // freeze ONLY on a fault at bp_pc (ctrl bit19)
   input  logic                  rt_oneshot,    // rewind+arm the retire ring for one pass (ctrl bit22)
   input  logic                  l2_nocache,    // set-before-go: L2 behaves as no-cache (ctrl bit20)
   input  logic                  trace_arm,     // arm the DRAM control-flow deep trace (ctrl bit21)
   input  logic [7:0]            trace_target_asid, // ASID filter target (record only this process)
   input  logic                  trace_filter_en,   // enable the ASID filter
   input  logic                  trace_loadval,     // deep trace records {pc,val} load records (ctrl bit14)
   input  logic                  trace_throttle,    // stall retirement on trace FIFO high-water -> lossless (ctrl bit13)
   input  logic                  trace_pcfilt,      // record+throttle only be-text-range PCs (ctrl bit12)

   // SCC serial Rx: host/TB pushes a byte -> IOC2 SCC Rx FIFO -> INT3 serial IRQ (IP2)
   input  logic                  scc_rx_valid,
   input  logic [7:0]            scc_rx_byte,
   output logic                  scc_rx_full,   // SCC Rx FIFO full -> ARM/PS flow-control (poll before push)

   // boot launch handshake (testbench/boot-ROM points the core at the entry)
   input  logic                  resume,
   input  logic [`M_WIDTH-1:0]   resume_pc,
   output logic                  ready_for_resume,

   // external memory bus -- non-device requests pass through here (-> RAM/AXI/cosim)
   output logic                  mem_req_valid,
   output logic [`PA_WIDTH-1:0]  mem_req_addr,
   output logic [127:0]          mem_req_store_data,
   output logic [4:0]            mem_req_opcode,
   output logic [15:0]           mem_req_mask,
   input  logic                  mem_rsp_valid,
   input  logic                  mem_rsp_bad,
   input  logic [127:0]          mem_rsp_load_data,
   /* lane 1 of the AXI master (AXI ID 1, concurrent with the CPU's lane 0 above):
    * the DMA engine + gio_window ring writer / MC fill.  Same contract as lane 0
    * (one request outstanding, valid drops between requests); opcodes 4/7 = 16B,
    * 5/6 = 64B burst read/write with the data in [511:0]. */
   output logic                  mem2_req_valid,
   output logic [`PA_WIDTH-1:0]  mem2_req_addr,
   output logic [511:0]          mem2_req_store_data,
   output logic [4:0]            mem2_req_opcode,
   output logic [15:0]           mem2_req_mask,
   input  logic                  mem2_rsp_valid,
   input  logic                  mem2_rsp_bad,
   input  logic [511:0]          mem2_rsp_load_data,

   // console: merged SCC-UART + core-putchar stream, exposed for a host sink
   output logic [7:0]            putchar_fifo_out,
   output logic                  putchar_fifo_empty,
   input  logic                  putchar_fifo_pop,
   output logic [3:0]            putchar_fifo_wptr,
   output logic [3:0]            putchar_fifo_rptr,

   // a few status taps
   output logic                  got_break,
   output logic                  got_ud,
   output logic                  got_bad_addr,
   output logic                  retire_valid,
   output logic [`M_WIDTH-1:0]   retire_pc,
   output logic                  retire_two_valid,
   output logic [`M_WIDTH-1:0]   retire_two_pc,
   output logic [`M_WIDTH-1:0]   dbg_head_pc,
   output logic [31:0] 		 dbg_head_status,
   output logic [`M_WIDTH-1:0]   epc,
   output logic [31:0]           status_reg,
   output logic [`M_WIDTH-1:0]   badvaddr,
   output logic [4:0]            cause,
   output logic [2:0]            dbg_frozen,
   output logic [31:0]           dbg_wp_data,
   output logic [7:0]            cause_ip,
   output logic                  took_irq,
   // retire register writeback taps (64-bit-address-bug localization)
   output logic [4:0]            retire_reg_ptr,
   output logic [`M_WIDTH-1:0]   retire_reg_data,
   output logic [4:0]            retire_reg_two_ptr,
   output logic [`M_WIDTH-1:0]   retire_reg_two_data,
   output logic                  retire_reg_valid,
   output logic                  retire_reg_two_valid,
   output logic [4:0]            retire_fp_reg_ptr,
   output logic [`M_WIDTH-1:0]   retire_fp_reg_data,
   output logic                  retire_fp_reg_valid,
   output logic [4:0]            retire_fp_reg_two_ptr,
   output logic [`M_WIDTH-1:0]   retire_fp_reg_two_data,
   output logic                  retire_fp_reg_two_valid,
   output logic [4:0]            retire_fcr_reg_ptr,
   output logic [`M_WIDTH-1:0]   retire_fcr_reg_data,
   output logic                  retire_fcr_reg_valid,
   output logic [4:0]            retire_fcr_reg_two_ptr,
   output logic [`M_WIDTH-1:0]   retire_fcr_reg_two_data,
   output logic                  retire_fcr_reg_two_valid,
   output logic [7:0]            retire_op,      // retiree opcodes (loadval co-sim validation)
   output logic [7:0]            retire_two_op,
   output logic [31:0]           retire_load_addr,     // retiring loads' effective VA (loadval addr)
   output logic [31:0]           retire_load_addr_two,
   output logic [31:0]           wf_epc,               // wild-fault latch: EPC of the poison deref
   output logic [31:0]           wf_badv,              // wild-fault latch: BadVaddr = the poison pointer P
   output logic [31:0]           wf_stat,              // {wild-fault count[15:0], 11'd0, cause[4:0]}
   output logic [31:0]           cp0_count,
   // FSM-state + trace-buffer taps (were tied off in the AXI wrapper)
   output logic [4:0]            core_state,
   output logic [2:0]            l1i_state,
   output logic [3:0]            l1d_state,
   output logic [3:0]            l2_state,
   output logic [3:0]            l2_rsp_state,
   output logic [`LG_ROB_ENTRIES:0] inflight,
   output logic [31:0] dbg_rob_inflight,
   input  logic [19:0]           dbg_trace_index,
   output logic [63:0]           l1i_cache_accesses,
   output logic [63:0]           l1i_cache_hits,
   output logic [63:0]           l1d_cache_accesses,
   output logic [63:0]           l1d_cache_hits,
   output logic [63:0]           l2_cache_accesses,
   output logic [63:0]           l2_cache_hits,
   output logic [31:0]           dbg_trace_data,
   output logic [15:0]           dbg_trace_wptr,
   output logic [31:0]           trace_ring_wptr,   // DRAM deep-trace: bytes written since arm
   output logic                  trace_overflow,    // DRAM deep-trace: a record was dropped (sticky)
   output logic [7:0]            cur_asid,          // current EntryHi ASID (readback for be-ASID discovery)
   // ---- SCSI shim mailbox (scsi_shim.sv): request out / completion in ----
   // FPGA: map to AXI-lite slv_regs; sim: henry_tb reads req_* / drives rsp_*.
   output logic [31:0]           scsi_req_seq,
   output logic [31:0]           scsi_req_nbdp,
   output logic [31:0]           scsi_req_xfer_len,
   output logic [127:0]          scsi_req_cdb,
   output logic [7:0]            scsi_req_dest,
   output logic [7:0]            scsi_req_lun,
   output logic                  scsi_req_to_device,
   input  logic [31:0]           scsi_rsp_seq,
   input  logic [31:0]           scsi_rsp_residual,
   input  logic [7:0]            scsi_rsp_scsi_status,
   input  logic [7:0]            scsi_rsp_tgt_status,
   input  logic [15:0]           scsi_sel_delay,      // programmable shim select->data delay (AXI reg)
   // ---- scsi_dma engine: disk data moves through the staging rings (scsi_stage) ----
   output logic                  scsi_dma_done,      // engine finished the chain (TB sync)
   output logic [31:0]           scsi_dbg,           // shim debug viz (AXI PMU readback)
   // ---- ENET shim mailbox (enet_shim.sv): Seeq 8003 + HPC3 ENET DMA channels ----
   // Completions come from dma_engine; these are exported for AXI debug readback.
   output logic [31:0]           enet_tx_req_seq,    // TX doorbell (++ per transmit)
   output logic [31:0]           enet_tx_nbdp,       // TX descriptor-chain head (phys)
   output logic [31:0]           enet_rx_arm_seq,    // ++ when guest arms rx_ctrl ACTIVE
   output logic [31:0]           enet_rx_nbdp,       // RX ring head (phys)
   // ---- staging-ring doorbells from the ARM (docs/arm-device-protocol.md) ----
   input  logic [31:0]           ring_tx_cons,       // ENET TX completions consumed
   input  logic [31:0]           ring_rx_prod,       // ENET RX frames staged
   input  logic [31:0]           ring_scsi_cq_cons,  // SCSI completions consumed
   input  logic [31:0]           ring_scsi_rd_beats, // beats staged for the next SCSI READ
   input  logic [31:0]           ring_scsi_rd_seq,   // ...for this command (written after beats)
   // ---- ARM-served GIO window (gio_window.sv, docs/newport-on-henry.md) ----
   input  logic [31:0]           gio_cons,           // capture-ring records the ARM has consumed
   input  logic [31:0]           gio_ans_lo,         // read answer lanes 0-3
   input  logic [31:0]           gio_ans_hi,         // read answer lanes 4-7
   input  logic [31:0]           gio_ans_seq,        // recno of the READ answered (written last)
   input  logic [15:0]           gio_irq,            // [7:0] -> INT3 local1 sources (7 = VRETRACE), [8] -> mappable 4 (8042)
   output logic [31:0]           gio_prod,           // debug: records published
   output logic [31:0]           vdma_stat0,         // MC VDMA usage: {non-fill starts[23:0], last mode[7:0]}
   output logic [31:0]           vdma_stat1,         // MC VDMA usage: {fill starts[15:0], other DMA reg writes[15:0]}
   input  logic [4:0]            gfx_perf_sel,       // graphics-path counter select: [4:1] counter, [0] 0=low 32 / 1=high 16
   output logic [31:0]           gfx_perf_data,      // read 0x02: the selected counter half
   output logic                  gio_pend,           // debug: a load is waiting for the ARM
   output logic [31:0]           gio_pend_seq,
   output logic [47:0]           enet_station,       // programmed station MAC (for RX filter)
   output logic [7:0]            enet_rx_cmd,        // Seeq RX command (match mode)
   output logic [31:0]           enet_dbg,           // ENET shim debug viz (AXI PMU readback)
   /* whole-cache flush + invalidate requested by the ARM (L1I, L1D, then L2; dirty
    * lines written back).  Level input: a 0->1 edge starts one flush. */
   input  logic                  ext_flush_ctl,
   /* page list (DMA buffers): push up to N_XF_PAGES physical page numbers, then `go`
    * runs one core page op per page -- ext_pg_drop=0: write back + invalidate (before
    * a transfer), 1: drop without write back (after a deposit).  More pages than
    * that is the ARM's cue to use the whole-cache flush instead. */
   input  logic                  ext_pg_push,        // 1-cycle: append ext_pg_ppn
   input  logic [31:0]           ext_pg_ppn,
   input  logic                  ext_pg_go,          // 1-cycle: walk the list
   input  logic                  ext_pg_drop,
   output logic [31:0]           ext_flush_stat,     // {completed[15:0], dirty[13:0], 1'b0, busy}
   output logic [31:0]           ext_flush_cycles    // cycles the last flush / page list took
   );

   localparam int unsigned DEV_LAT = 2;   // device response latency (cycles)

   // ---- core <-> SoC interposer wires ----
   logic                  c_req_valid;
   logic [`PA_WIDTH-1:0]  c_req_addr;
   logic [127:0]          c_req_store_data;
   logic [4:0]            c_req_opcode;
   logic [15:0]           c_req_mask;
   logic                  c_req_uncached;   /* uncached op (at the ROB head, never wrong-path) */
   logic                  c_rsp_valid;
   logic                  c_rsp_bad;
   logic [127:0]          c_rsp_load_data;

   // core's CP0-reg7 putchar FIFO (drained internally into the SoC console)
   logic [7:0]            cp_out;
   logic                  cp_empty;
   logic                  cp_pop;

   // ---- address decode (physical, mem_req_addr is 16-byte aligned) ----
   //   MC  : 0x1fa00000 .. 0x1fafffff (1 MB)
   //   IOC2: 0x1fbd9800 .. 0x1fbd98ff (256 B, carved out of HPC3)
   //   HPC3: 0x1fb80000 .. 0x1fbfffff (512 KB) minus IOC2
   wire w_is_mc   = (c_req_addr[31:20] == 12'h1fa);
   /* IOC2 8042 keyboard/mouse controller (data 0x1fbd9843, command/status 0x1fbd9847):
    * ARM-served through the gio_window ring (space 1).  The rest of that line
    * (0x48..0x4f) stays with ioc.sv. */
   wire w_is_kbd  = (c_req_addr[31:4] == 28'h1fbd984) & (|c_req_mask[7:0]);
   wire w_is_ioc  = (c_req_addr[31:8]  == 24'h1fbd98) & ~w_is_kbd;
   /* ds1386 battery-backed RAM (the Indy NVRAM: environment + station MAC) is plain
    * DRAM the ARM populates, not an HPC3 register: 0x1fbe0040 .. 0x1fbe7fff (the clock,
    * regs 0x00-0x0f, stays in hpc3.sv).  Undecoded here, the CPU access falls through
    * to DRAM at the device-window offset (the same path as the PROM image). */
   wire w_is_bbram = (c_req_addr[31:15] == 17'h03f7c) & (c_req_addr[14:6] != 9'd0);  // 0x1fbe0000>>15
   wire w_is_hpc3 = (c_req_addr[31:19] == 13'h3f7) & ~w_is_ioc & ~w_is_kbd & ~w_is_bbram;   // 0x1fb80000>>19
   wire w_is_gio;                                                    // gio_window: 0x1f0f0000 .. 0x1f0f1fff
   /* GIO space with nothing behind it (docs/bus-errors.md): the MC times the access
    * out -- loads complete with a bus error when CPUCTRL1.ABORT_EN is set, stores are
    * absorbed; either way the MC latches GIO_ERROR_ADDR/STAT.  Covers the GIO slots
    * (minus present windows) and HPC3 chip 1 (0x1fb00000): an Indy has only chip 0,
    * and Linux probes the graphics slot only after chip 1's PBDMA read bus-errors. */
   wire w_is_gio_empty = (((c_req_addr[31:0] >= 32'h1f000000) & (c_req_addr[31:0] < 32'h1fa00000)) |
			  ((c_req_addr[31:0] >= 32'h1fb00000) & (c_req_addr[31:0] < 32'h1fb80000))) & ~w_is_gio;
   /* PROM memory sizing (ip24prom 0xbfc01070/0xbfc01640): the PROM makes ONE bank valid at
    * base 0x20000000 (MEMCFG field base 0x80, 4 MB units) and probes it uncached -- walking
    * ones (a mismatch = no SIMMs), then aliasing for the size.  henry backs banks 0/1 only
    * (2 x 128 MB = the 256 MB at 0x08000000..0x17ffffff); banks 2/3 are empty.  In the probe
    * window, bank 0/1 reach their DRAM (offset mod 128 MB, so the alias test sizes them at
    * 128 MB) and anything else is empty memory -- loads read 0, stores vanish, no bus error.
    * Without this every bank probed present and IRIX was told 512 MB, half of it unbacked. */
   wire [31:0] w_memcfg0, w_memcfg1;   /* CPU order: bank0 [31:16], bank1 [15:0] */
   wire w_hi_win   = (c_req_addr[`PA_WIDTH-1:28] == (`PA_WIDTH-28)'(2));
   wire w_hi_bank0 = w_memcfg0[29] & (w_memcfg0[23:16] == 8'h80);
   wire w_hi_bank1 = w_memcfg0[13] & (w_memcfg0[7:0] == 8'h80);
   wire w_is_nomem = w_hi_win & ~w_hi_bank0 & ~w_hi_bank1;
   /* Reserved PAs (MC spec, physical address map): 0x18000000-0x1effffff and everything
    * from 0x30000000 up.  The AXI fold passes these through unchanged, and below addrmask
    * they would reach the board DRAM past the guest's 256 MB -- where the ARM keeps the
    * staging rings, the GIO capture ring and the trace area.  Decode them here instead:
    * an uncached load gets a bus error, an uncached store is absorbed, and the MC latches
    * CPU_ERROR_ADDR/STAT (ADDR) either way, as an Indy's MC does for an address that maps
    * to no memory.  CACHED traffic here reads zeros / is dropped with no error: a cached
    * fill can belong to a wrong-path load (garbage PA[35:32]), and an MC latch + bus-error
    * interrupt cannot be squashed -- that panicked 64-bit Linux in the atkbd probe. */
   wire w_is_nomap = ((c_req_addr >= `PA_WIDTH'(36'h18000000)) & (c_req_addr < `PA_WIDTH'(36'h1f000000))) |
		     (c_req_addr[`PA_WIDTH-1:28] >= (`PA_WIDTH-28)'(3));
   wire w_is_dev  = w_is_mc | w_is_hpc3 | w_is_ioc | w_is_kbd | w_is_gio | w_is_gio_empty | w_is_nomem | w_is_nomap;
   wire w_is_load = (c_req_opcode == 5'd4);

`ifdef SCSI_CLOBBER_TRACE
   // SCSI/DMA-clobber debug ([creq]/[dram], address-hardwired to 0x0841d/hpc3). Was
   // under `ifdef VERILATOR so it fired on every sim run; gated behind its own define.
   // TEMP: trace the GLOBAL ORDER of the core's external stores (c_req is
   // one-outstanding, program order): descriptor cache-writeback (->DRAM @0x0841d)
   // vs uncached HPC3/SCSI command MMIO (->device).  Answers: does the descriptor
   // flush reach the memory interface BEFORE the device sees the command?
   reg r_crev_dbg;
   always_ff @(posedge clk) begin
      r_crev_dbg <= c_req_valid;
      if(c_req_valid & ~r_crev_dbg & (c_req_opcode == 5'd7) &
         ((c_req_addr[31:12] == 20'h0841d) | w_is_hpc3))
        $display("[creq] op7 addr=%08x %s d0=%08x d1=%08x", c_req_addr[31:0],
                 w_is_hpc3 ? "DEV " : "DESC", c_req_store_data[31:0], c_req_store_data[63:32]);
   end
   // TEMP: DRAM-level traffic for the INQUIRY buffer line (engine write via master 1,
   // CPU refill read via master 0) -- op7=store(engine) op4=load(CPU refill).
   reg r_mrev_dbg;
   always_ff @(posedge clk) begin
      r_mrev_dbg <= mem_req_valid;
      if(mem_req_valid & ~r_mrev_dbg & (mem_req_addr[35:8] == 28'h0083dcb))
        $display("[dram] op=%0d addr=%09x d0=%08x", mem_req_opcode, mem_req_addr,
                 mem_req_store_data[31:0]);
   end
`endif

   // =====================================================================
   //  r9999 core
   // =====================================================================
   // INT3 (IOC2 interrupt mux) drives the 5 CPU hardware interrupt pins.
   wire w_int3_ip2, w_int3_ip3, w_int3_ip4, w_int3_ip5, w_int3_ip6;
   // ---- DMA-coherence snoop ------------------------------------------------
   // A DMA master writes DRAM behind the CPU caches, and IRIX cannot invalidate
   // r9999's L2 (Config.SC hides it -> the kernel issues zero SD ops), so nothing
   // in software can drop a stale L2 line for an address a device just wrote.
   // dma_snoop_shim owns the core's snoop port: it write-back-invalidates each
   // line in the inclusive L2 (which probes the L1D) before a DMA access, and
   // again after a DMA write.
   wire                 w_snoop_valid;
   wire [`PA_WIDTH-1:0] w_snoop_addr;
   wire                 w_snoop_ack;
   wire                 w_snoop_done;   /* the L2 finished the snoop (inclusive-L2 core) */
   wire                 w_snoop_wbinv;  /* snoop op: 1 = WBINV, 0 = DROP/discard */

   /* ================= ARM-requested whole-cache flush =================
    * The core already has the flush + invalidate sequencer behind ext_flush_req /
    * ext_flush_done (the one the CPU's CACHE_FLUSH uses).  The ARM raises
    * ext_flush_ctl (AXI control bit) around its DMA helper ops; each 0->1 edge
    * starts one flush, and ext_flush_stat / ext_flush_cycles let it poll for
    * completion and measure what a flush costs.  An edge while a flush is still
    * running is ignored -- the ARM waits for the completed count to move.
    *
    * The page list shares the sequencer: `go` issues ext_flush_req once per listed
    * page (the core latches the page and op with the request) and counts ONE
    * completion when the last page is done.  Pushes and `go` are ignored while busy;
    * a push past N_XF_PAGES sets overflow, and a `go` with overflow does the whole
    * flush instead (always correct).  `go` consumes the list. */
   localparam LG_XF_PAGES = 4;
   localparam N_XF_PAGES = 1 << LG_XF_PAGES;
   logic [`PA_WIDTH-`LG_PG_SZ-1:0] r_xf_pg [N_XF_PAGES-1:0];
   logic [LG_XF_PAGES:0]  r_xf_npg, n_xf_npg;       /* pages in the list */
   logic [LG_XF_PAGES-1:0] r_xf_idx, n_xf_idx;      /* page being flushed */
   logic        r_xf_ovf, n_xf_ovf;
   logic        r_xf_whole, n_xf_whole;
   logic        r_xf_drop, n_xf_drop;
   wire [15:0]  w_xf_dirty;
   logic        r_ext_flush_ctl, r_ext_flush_ctl_d;
   logic        r_ext_flush_req, n_ext_flush_req;
   logic        r_ext_flush_busy, n_ext_flush_busy;
   logic [15:0] r_ext_flush_cnt, n_ext_flush_cnt;
   logic [30:0] r_ext_flush_cyc, n_ext_flush_cyc;
   logic [30:0] r_ext_flush_last, n_ext_flush_last;
   wire         w_ext_flush_done;
   /* register the control bit before edge-detecting it: it comes from the AXI
    * slave, and a combinational edge off a raw input is also invisible to a
    * testbench that changes inputs without an eval before the clock edge. */
   wire         w_ext_flush_edge = r_ext_flush_ctl & ~r_ext_flush_ctl_d;

   always_ff @(posedge clk)
     begin
        if(reset)
          begin
             r_ext_flush_ctl   <= 1'b0;
             r_ext_flush_ctl_d <= 1'b0;
             r_ext_flush_req   <= 1'b0;
             r_ext_flush_busy  <= 1'b0;
             r_ext_flush_cnt   <= 16'd0;
             r_ext_flush_cyc   <= 31'd0;
             r_ext_flush_last  <= 31'd0;
             r_xf_npg          <= 'd0;
             r_xf_idx          <= 'd0;
             r_xf_ovf          <= 1'b0;
             r_xf_whole        <= 1'b1;
             r_xf_drop         <= 1'b0;
          end
        else
          begin
             r_ext_flush_ctl   <= ext_flush_ctl;
             r_ext_flush_ctl_d <= r_ext_flush_ctl;
             r_ext_flush_req   <= n_ext_flush_req;
             r_ext_flush_busy  <= n_ext_flush_busy;
             r_ext_flush_cnt   <= n_ext_flush_cnt;
             r_ext_flush_cyc   <= n_ext_flush_cyc;
             r_ext_flush_last  <= n_ext_flush_last;
             r_xf_npg          <= n_xf_npg;
             r_xf_idx          <= n_xf_idx;
             r_xf_ovf          <= n_xf_ovf;
             r_xf_whole        <= n_xf_whole;
             r_xf_drop         <= n_xf_drop;
          end
     end // always_ff

   always_ff @(posedge clk)
     begin
        if(ext_pg_push & !r_ext_flush_busy & !r_xf_npg[LG_XF_PAGES])
          begin
             r_xf_pg[r_xf_npg[LG_XF_PAGES-1:0]] <= ext_pg_ppn[`PA_WIDTH-`LG_PG_SZ-1:0];
          end
     end // always_ff

   always_comb
     begin
        n_ext_flush_req  = 1'b0;
        n_ext_flush_busy = r_ext_flush_busy;
        n_ext_flush_cnt  = r_ext_flush_cnt;
        n_ext_flush_cyc  = r_ext_flush_cyc;
        n_ext_flush_last = r_ext_flush_last;
        n_xf_npg         = r_xf_npg;
        n_xf_idx         = r_xf_idx;
        n_xf_ovf         = r_xf_ovf;
        n_xf_whole       = r_xf_whole;
        n_xf_drop        = r_xf_drop;
        if(ext_pg_push & !r_ext_flush_busy)
          begin
             if(r_xf_npg[LG_XF_PAGES])
               begin
                  n_xf_ovf = 1'b1;
               end
             else
               begin
                  n_xf_npg = r_xf_npg + 'd1;
               end
          end
        if(w_ext_flush_edge & !r_ext_flush_busy)
          begin
             n_ext_flush_req  = 1'b1;
             n_ext_flush_busy = 1'b1;
             n_ext_flush_cyc  = 31'd0;
             n_xf_whole       = 1'b1;
          end
        else if(ext_pg_go & !r_ext_flush_busy)
          begin
             n_ext_flush_cyc  = 31'd0;
             n_xf_whole       = r_xf_ovf;
             n_xf_drop        = ext_pg_drop;
             n_xf_idx         = 'd0;
             n_xf_npg         = 'd0;
             n_xf_ovf         = 1'b0;
             if(r_xf_ovf | (r_xf_npg != 'd0))
               begin
                  n_ext_flush_req  = 1'b1;
                  n_ext_flush_busy = 1'b1;
                  /* hold the page count for the walk; consumed when it completes */
                  n_xf_npg         = r_xf_npg;
               end
             else
               begin
                  /* empty list: nothing to flush, complete at once */
                  n_ext_flush_cnt  = r_ext_flush_cnt + 16'd1;
                  n_ext_flush_last = 31'd0;
               end
          end
        else if(r_ext_flush_busy)
          begin
             n_ext_flush_cyc = r_ext_flush_cyc + 31'd1;
             if(w_ext_flush_done)
               begin
                  if(!r_xf_whole & ({1'b0, r_xf_idx} != (r_xf_npg - 'd1)))
                    begin
                       n_xf_idx        = r_xf_idx + 'd1;
                       n_ext_flush_req = 1'b1;
                    end
                  else
                    begin
                       n_ext_flush_busy = 1'b0;
                       n_ext_flush_cnt  = r_ext_flush_cnt + 16'd1;
                       n_ext_flush_last = r_ext_flush_cyc + 31'd1;
                       n_xf_npg         = 'd0;
                    end
               end
          end
     end // always_comb

   assign ext_flush_stat   = {r_ext_flush_cnt,
                              (w_xf_dirty > 16'h3fff) ? 14'h3fff : w_xf_dirty[13:0],
                              1'b0, r_ext_flush_busy};
   assign ext_flush_cycles = {1'b0, r_ext_flush_last};

   core_l1d_l1i cpu
     (.clk(clk),
      .reset(reset),
      .retire_allowed(~w_trace_stall),
      .putchar_fifo_out(cp_out),
      .putchar_fifo_empty(cp_empty),
      .putchar_fifo_pop(cp_pop),
      .putchar_fifo_wptr(),
      .putchar_fifo_rptr(),
      .ip2(w_int3_ip2),
      .ip3(w_int3_ip3),
      .ip4(w_int3_ip4),
      .ip5(w_int3_ip5),
      .ip6(w_int3_ip6),
      .single_step(single_step),
      .step(step),
      .pmu_sel(pmu_sel),
      .pmu_value(pmu_value),
      .bp_enable(bp_enable),
      .fault_clear(fault_clear),
      .bp_pc(bp_pc),
      .bp_wp_addr(bp_wp_addr),
      .bp_wp_val(bp_wp_val),
      .bp_fault_only(bp_fault_only), .rt_oneshot(rt_oneshot),
      .l2_nocache(l2_nocache),
      .in_flush_mode(),
      .ext_flush_req(r_ext_flush_req),
      .ext_flush_done(w_ext_flush_done),
      .ext_flush_ppn(r_xf_pg[r_xf_idx]),
      .ext_flush_whole(r_xf_whole),
      .ext_flush_drop(r_xf_drop),
      .ext_flush_dirty_cnt(w_xf_dirty),
      .resume(resume),
      .resume_pc(resume_pc),
      .ready_for_resume(ready_for_resume),

      .mem_req_valid(c_req_valid),
      .mem_req_addr(c_req_addr),
      .mem_req_store_data(c_req_store_data),
      .mem_req_opcode(c_req_opcode),
      .mem_req_mask(c_req_mask),
      .mem_req_uncached(c_req_uncached),
      .mem_rsp_valid(c_rsp_valid),
      .mem_rsp_bad(c_rsp_bad),
      .mem_rsp_load_data(c_rsp_load_data),

      .retire_reg_ptr(retire_reg_ptr), .retire_reg_data(retire_reg_data), .retire_reg_valid(retire_reg_valid),
      .retire_reg_two_ptr(retire_reg_two_ptr), .retire_reg_two_data(retire_reg_two_data), .retire_reg_two_valid(retire_reg_two_valid),
      .retire_fp_reg_ptr(retire_fp_reg_ptr),
      .retire_fp_reg_data(retire_fp_reg_data),
      .retire_fp_reg_valid(retire_fp_reg_valid),
      .retire_fp_reg_two_ptr(retire_fp_reg_two_ptr),
      .retire_fp_reg_two_data(retire_fp_reg_two_data),
      .retire_fp_reg_two_valid(retire_fp_reg_two_valid),
      .retire_fcr_reg_ptr(retire_fcr_reg_ptr),
      .retire_fcr_reg_data(retire_fcr_reg_data),
      .retire_fcr_reg_valid(retire_fcr_reg_valid),
      .retire_fcr_reg_two_ptr(retire_fcr_reg_two_ptr),
      .retire_fcr_reg_two_data(retire_fcr_reg_two_data),
      .retire_fcr_reg_two_valid(retire_fcr_reg_two_valid),
      .retire_valid(retire_valid), .retire_two_valid(retire_two_valid),
      .retire_pc(retire_pc), .retire_two_pc(retire_two_pc),
      .asid(w_core_asid),
      .retire_op(retire_op), .retire_two_op(retire_two_op),
      .retire_load_addr(retire_load_addr), .retire_load_addr_two(retire_load_addr_two),
      .wf_epc(wf_epc), .wf_badv(wf_badv), .wf_stat(wf_stat),
      .branch_pc(), .branch_pc_valid(), .branch_fault(),
      /* were left UNCONNECTED: the core counts fine, henry_soc discarded the
       * outputs, and the AXI wrapper fed the read mux literal 'd0 -- so every
       * cache counter read 0 on silicon.  A silently no-op instrument. */
      .l1i_cache_accesses(l1i_cache_accesses), .l1i_cache_hits(l1i_cache_hits),
      .l1d_cache_accesses(l1d_cache_accesses), .l1d_cache_hits(l1d_cache_hits),
      .l2_cache_accesses(l2_cache_accesses),   .l2_cache_hits(l2_cache_hits),
      .got_break(got_break), .got_ud(got_ud), .got_bad_addr(got_bad_addr),
      .core_state(core_state), .l1i_state(l1i_state), .l1d_state(l1d_state), .l2_state(l2_state), .l2_rsp_state(l2_rsp_state),
      .inflight(inflight), .dbg_rob_inflight(dbg_rob_inflight), .epc(epc), .status_reg(status_reg), .badvaddr(badvaddr), .cause(cause), .cause_ip(cause_ip), .dbg_frozen(dbg_frozen), .dbg_wp_data(dbg_wp_data),
      .l1i_flush_done(), .l1d_flush_done(), .l2_flush_done(),
      .snoop_req_valid(w_snoop_valid),
      .snoop_req_addr(w_snoop_addr),
      .snoop_req_ack(w_snoop_ack),
      .snoop_req_wbinv(w_snoop_wbinv),   /* r9999 inclusive L2: 1 = WBINV (probe L1D, write back); 0 = DROP */
      .snoop_done(w_snoop_done),
      .took_irq(took_irq), .cp0_count(cp0_count),
      .dbg_head_pc(dbg_head_pc), .dbg_head_status(dbg_head_status), .dbg_head_fetch_cycle(), .dbg_head_alloc_cycle(),
      .dbg_serialize_cycle(), .dbg_cycle(), .dbg_oldest_first_pending(),
      .dbg_trace_index(dbg_trace_index), .dbg_trace_data(dbg_trace_data), .dbg_trace_wptr(dbg_trace_wptr)
      );

   // =====================================================================
   //  Pass-through: requests that miss every modeled device go to the
   //  external memory bus unchanged.
   // =====================================================================
   // IP22 "System Memory Alias" (mc.pdf 4): physical 0x0..0x7ffff (low 512 KB)
   // aliases into the bottom of Low Local Memory @ 0x08000000, so the CPU
   // exception vectors (phys 0x0/0x80) and the SPB the FSBL copies to phys 0x1000
   // are backed by real DRAM. Remap mem-bound low addresses (set bit 27); device
   // addresses are all >= 0x1f000000 so they are unaffected.
   wire w_sysmem_alias       = (c_req_addr[`PA_WIDTH-1:19] == '0);
   // =====================================================================
   //  DRAM arbiter (mem_arbiter.sv): a parameterized weighted round-robin that
   //  multiplexes the CPU and the HPC3 DMA engine onto the single external memory
   //  port.  One outstanding; the external AXI master requires mem_req_valid to
   //  DROP to 0 between requests, so the arbiter forces a TURN (valid-low) cycle
   //  after every response (the henry_tb DRAM model enforces this 0->1 edge too).
   //  Weighting + master count are set at the instantiation below.
   // =====================================================================
   wire w_cpu_dram_req = c_req_valid & ~w_is_dev;

   // HPC3 DMA master -- driven by u_hpc3 (mem-to-mem copy engine).
   wire                 w_dma_req_valid;
   wire [`PA_WIDTH-1:0] w_dma_req_addr;
   wire [127:0]         w_dma_req_store_data;
   wire [4:0]           w_dma_req_opcode;
   wire [15:0]          w_dma_req_mask;

   // shim phase SM -> engine control (data-phase trigger)
   wire        w_sdma_go, w_sdma_to_dev, w_sdma_abort;
   wire [31:0] w_sdma_nbdp;
   // arbiter master 1: the SCSI DMA engine.
   /* were dangling: the engine already computes ch_active (busy) and the XIE pulse,
    * which is exactly what hd0.cntl needs -- nothing consumed them before. */
   wire                 w_eng_busy, w_eng_irq;
   wire                 w_hpc_scsi_intr;   /* HPC3 XIE (DMA-complete) level */
   wire                 w_eng_req_valid, w_eng_done, w_eng_rd_stalled;
   wire [`PA_WIDTH-1:0] w_eng_req_addr;
   wire [127:0]         w_eng_req_store_data;
   wire [4:0]           w_eng_req_opcode;
   wire [15:0]          w_eng_req_mask;
   /* the SCSI engine's side of its dma_snoop_shim (coherent-DMA build) */
   wire                 w_sdn_req_valid;
   wire [`PA_WIDTH-1:0] w_sdn_req_addr;
   wire [127:0]         w_sdn_req_store_data;
   wire [4:0]           w_sdn_req_opcode;
   wire [15:0]          w_sdn_req_mask;
   wire                 w_seng_rsp_valid;
   wire [511:0]         w_seng_rsp_load_data;
   wire                 w_dma_owner_enet;   /* dma_engine: an ENET channel owns master 1 (logging) */
   wire                 w_m1_req_valid      = w_sdn_req_valid;
   wire [`PA_WIDTH-1:0] w_m1_req_addr       = w_sdn_req_addr;
   wire [127:0]         w_m1_req_store_data = w_sdn_req_store_data;
   wire [4:0]           w_m1_req_opcode     = w_sdn_req_opcode;
   wire [15:0]          w_m1_req_mask       = w_sdn_req_mask;

   // CPU master address: apply the IP22 System Memory Alias before arbitration.
   // ... and the PROM's bank-probe window onto the probed bank's DRAM (bank0 -> 0x08000000,
   // bank1 -> 0x10000000; empty banks never get here, they are w_is_nomem devices).
   wire [`PA_WIDTH-1:0] w_cpu_req_addr = w_sysmem_alias
                          ? {c_req_addr[`PA_WIDTH-1:28], 1'b1, c_req_addr[26:0]}
                          : w_hi_win
                          ? {{(`PA_WIDTH-29){1'b0}}, w_hi_bank1, w_hi_bank0, c_req_addr[26:0]}
                          : c_req_addr;

   // ---- DRAM control-flow deep trace (master 2): streams a compressed userspace
   // control-flow trace to the IP22 "Reserved / Future GIO Space" region, which
   // sgi_mode passes through IDENTITY to free DRAM (0x18000000..0x1EFFFFFF, all
   // <= addrmask).  Ring = 64 MB at 0x18000000; the ARM reads it at c_addr[base].
   localparam [`PA_WIDTH-1:0] TRACE_BASE = `PA_WIDTH'(36'h018000000);
   // 112 MB = the whole IP22 GIO-reserved free region 0x18000000..0x1EFFFFFF (<= addrmask).
   // Non-2^k so dram_trace wraps via compare; big enough that be's crash (during
   // reconfigure, ~96MB of trace) fits with no wrap -> ring stays linearly decodable.
   localparam [`PA_WIDTH-1:0] TRACE_SIZE = `PA_WIDTH'(36'h007000000);   // 112 MB (circular)
   wire [7:0]           w_core_asid;      // current EntryHi ASID exported by the core
   assign cur_asid = w_core_asid;         // readback so the driver can capture be's ASID at crash
   wire                 w_trace_stall;    // dram_trace FIFO high-water -> pause retirement (lossless)
   wire                 w_trace_req_valid;
   wire [`PA_WIDTH-1:0] w_trace_req_addr;
   wire [511:0]         w_trace_req_store_data;   /* 512: the ring writer's 64B bursts */
   wire [4:0]           w_trace_req_opcode;
   wire [15:0]          w_trace_req_mask;

   /* ENABLE_DRAM_TRACE: the DRAM deep trace is OPT-IN (off by default).  It never
    * produced a usable trace (decode proven, golden never aligned) and it costs LUTs
    * the timing-bound builds need.  Off, master 2 of the arbiter is simply always idle
    * -- exactly what it already was whenever trace_arm was 0 -- and the retire stall
    * and the AXI readback (ring wptr, overflow) read 0. */
`ifdef ENABLE_DRAM_TRACE
   dram_trace u_trace
     (.clk(clk), .reset(reset),
      .arm(trace_arm),
      .ring_base(TRACE_BASE), .ring_size(TRACE_SIZE),
      .retire0_valid(retire_valid),     .retire0_pc(retire_pc),
      .retire1_valid(retire_two_valid), .retire1_pc(retire_two_pc),
      .retire0_op(retire_op),        .retire0_reg_valid(retire_reg_valid),     .retire0_val(retire_reg_data),
      .retire1_op(retire_two_op),    .retire1_reg_valid(retire_reg_two_valid), .retire1_val(retire_reg_two_data),
      .retire0_addr(retire_load_addr), .retire1_addr(retire_load_addr_two),
      .loadval_mode(trace_loadval),
      .throttle_en(trace_throttle), .trace_stall(w_trace_stall),
      .pc_range_en(trace_pcfilt),
      .asid(w_core_asid), .target_asid(trace_target_asid), .filter_en(trace_filter_en),
      .trace_req_valid(w_trace_req_valid),           .trace_req_addr(w_trace_req_addr),
      .trace_req_store_data(w_trace_req_store_data[127:0]), .trace_req_opcode(w_trace_req_opcode),
      .trace_req_mask(w_trace_req_mask),
      .trace_rsp_valid(w_arb_rsp_valid[2]),          .trace_rsp_bad(mem2_rsp_bad),
      .trace_ring_wptr(trace_ring_wptr), .trace_overflow(trace_overflow));
   /* gio_window needs arbiter master 2 too: the two cannot be built together */
   assign w_trace_req_store_data[511:128] = '0;   /* the trace engine writes 16B */
   GIO_WINDOW_AND_DRAM_TRACE_BOTH_NEED_ARBITER_MASTER_2 u_master2_conflict();
`else
   assign w_trace_stall          = 1'b0;
   assign trace_ring_wptr        = 'd0;
   assign trace_overflow         = 1'b0;
`endif


   // Parameterized weighted round-robin arbiter: master 0 = CPU, 1 = DMA, 2 = trace.
   // NSLOT=8, SLOT_MAP gives CPU slots 0..5, DMA slot 6, trace slot 7 -> CPU:DMA:trace
   // = 6:1:1.  Trace is low-weight (its FIFO absorbs bursts) so it cannot starve CPU
   // line fills.  Add masters / retune by the parameters (see mem_arbiter.sv).
   /* WAS [2:0] while the arbiter below is N(4) and ENET is master 3, so
    * `w_mem_rsp_enet = w_arb_rsp_valid[3]` read a bit that does not exist and
    * synthesized to CONSTANT 0 (netlist mipscore.v:15842/15910).  enet_dma's FSM
    * advances only on dma_rsp_valid, so the first tx_go latched dma_req_valid and
    * the engine re-requested its TX descriptor FOREVER -- ~3.1M AXI reads/s on one
    * address -- starving the CPU off this arbiter until nothing retired at all.
    * Captured on silicon 2026-09-14 (db08ab69, IRIX): enet_tx_nbdp == the hammered
    * address, l2 IDLE, l1i parked in WAIT_FOR_NOT_FULL.  Widening also revives the
    * ENET L2 snoop, which is gated on the same dead signal. */
   wire [2:0] w_arb_rsp_valid;
   /* ENET and SCSI share master 1: one dma_engine behind one dma_snoop_shim.
    * Slots: CPU x5, DMA x2 (the two engines' former 1+1), master 2 (gio_window / MC
    * fill) x1. */
   /* Two AXI lanes (two AXI IDs, concurrent): lane 0 = the CPU alone; lane 1 =
    * master 1 (DMA) x2 slots + master 2 (gio_window / MC fill / trace) x1.  Each
    * lane is still one-outstanding with the valid-low TURN cycle.  The master
    * blocks a cross-lane access to a 64B line the other lane is writing (or a
    * write to a line it is accessing).  w_arb_rsp_valid keeps the old 3-master
    * numbering so the consumers below are unchanged. */
   wire [1:0] w_arb1_rsp_valid;
   mem_arbiter #(.N(1), .NSLOT(1), .LG_N(1), .SLOT_MAP(1'b0)) u_arb0
     (.clk(clk), .reset(reset),
      .m_req_valid     (w_cpu_dram_req),
      .m_req_addr      (w_cpu_req_addr),
      .m_req_store_data(c_req_store_data),
      .m_req_opcode    (c_req_opcode),
      .m_req_mask      (c_req_mask),
      .m_rsp_valid     (w_arb_rsp_valid[0]),
      .m_rsp_load_data (),
      .m_rsp_bad       (),
      .mem_req_valid(mem_req_valid),           .mem_req_addr(mem_req_addr),
      .mem_req_store_data(mem_req_store_data), .mem_req_opcode(mem_req_opcode),
      .mem_req_mask(mem_req_mask),
      .mem_rsp_valid(mem_rsp_valid),           .mem_rsp_load_data(mem_rsp_load_data),
      .mem_rsp_bad(mem_rsp_bad));
   mem_arbiter #(.N(2), .NSLOT(3), .LG_N(1), .SLOT_MAP(3'b100), .DW(512)) u_arb1
     (.clk(clk), .reset(reset),
      .m_req_valid     ({w_trace_req_valid,      w_m1_req_valid}),
      .m_req_addr      ({w_trace_req_addr,       w_m1_req_addr}),
      .m_req_store_data({w_trace_req_store_data, 384'd0, w_m1_req_store_data}),
      .m_req_opcode    ({w_trace_req_opcode,     w_m1_req_opcode}),
      .m_req_mask      ({w_trace_req_mask,       w_m1_req_mask}),
      .m_rsp_valid     (w_arb1_rsp_valid),
      .m_rsp_load_data (),
      .m_rsp_bad       (),
      .mem_req_valid(mem2_req_valid),           .mem_req_addr(mem2_req_addr),
      .mem_req_store_data(mem2_req_store_data), .mem_req_opcode(mem2_req_opcode),
      .mem_req_mask(mem2_req_mask),
      .mem_rsp_valid(mem2_rsp_valid),           .mem_rsp_load_data(mem2_rsp_load_data),
      .mem_rsp_bad(mem2_rsp_bad));
   assign w_arb_rsp_valid[2:1] = w_arb1_rsp_valid;

   wire w_mem_rsp_cpu = w_arb_rsp_valid[0];   // master 0 = CPU
   wire w_mem_rsp_dma = w_arb_rsp_valid[1];   // master 1 = DMA (ENET + SCSI)

`ifdef ARB_TRACE
   /* sim-only: one line per completed DRAM access (master, PA, opcode, mask), for
    * diffing traffic across arbiter/DMA changes.  Sampled on the response edge (as
    * LOG_DMA_PA explains, a combinational response pulse is gone by negedge).
    * Master 1: e = ENET, s = SCSI owner of the shared DMA port. */
   logic [63:0] r_arbtr_cyc;
   always_ff @(posedge clk)
     begin
	r_arbtr_cyc <= reset ? 64'd0 : (r_arbtr_cyc + 64'd1);
	if(w_arb_rsp_valid[0])
	  begin
	     $display("[arb] %0d m0 %x op%0d m%04x", r_arbtr_cyc, w_cpu_req_addr, c_req_opcode, c_req_mask);
	  end
	if(w_arb_rsp_valid[1])
	  begin
	     $display("[arb] %0d m1%s %x op%0d m%04x", r_arbtr_cyc, w_dma_owner_enet ? "e" : "s",
		      w_m1_req_addr, w_m1_req_opcode, w_m1_req_mask);
	  end
	if(w_arb_rsp_valid[2])
	  begin
	     $display("[arb] %0d m2 %x op%0d m%04x", r_arbtr_cyc, w_trace_req_addr, w_trace_req_opcode, w_trace_req_mask);
	  end
     end // always_ff
`endif

   // =====================================================================
   //  ENET DMA engine (arbiter master 3).  Replaces the host-served path in
   //  which henry_tb / the ARM wrote the guest's RX buffers DIRECTLY, invisible
   //  to the L2.  Now every ENET byte lands via the same ordered DRAM port the
   //  CPU uses, so the snoop FIFO above sees it and the L2 cannot serve a stale
   //  line for a buffer the NIC just filled.
   // =====================================================================
   /* enet_shim completion inputs, driven by the ring engine */
   wire [31:0]          w_shim_tx_rsp_seq, w_shim_rx_rsp_seq, w_shim_rx_crbdp, w_shim_tx_crbdp;

   /* TX doorbell: enet_shim bumps enet_tx_req_seq when the guest kicks a transmit.
    * Edge-detect it here -- with the engine present the RTL consumes the doorbell
    * itself instead of handing it to the host servicer. */
   logic [31:0] r_enet_tx_seq;
   wire         w_enet_tx_go = (r_enet_tx_seq != enet_tx_req_seq);
   always_ff@(posedge clk)
     begin
	r_enet_tx_seq <= reset ? 32'd0 : enet_tx_req_seq;
     end

   /* inclusive-L2 coherence: the engine's accesses go through dma_snoop_shim, which
    * WBINV-snoops each line before the access and again after a write (and
    * owns the core's L2 snoop port).  ENET is a channel of the unified dma_engine
    * (u_dma, below), which shares that shim with SCSI. */
   /* RX ring position.  The shim's rx_nbdp is the GUEST's register: it only changes
    * when the driver (re)arms the channel, so feeding it straight to the engine put
    * every frame in the same descriptor and RX stalled after one frame (the guest
    * waits on the next descriptor).  Real HPC3 advances NBDP as it walks the ring:
    * reload on an arm (enet_rx_arm_seq edge), advance to the engine's next
    * descriptor on each delivered frame.  An arm in the same cycle wins. */
   logic [31:0] r_enet_rx_arm_seq;
   logic [31:0] r_enet_rx_pos;
   wire  [31:0] w_enet_rx_next_nbdp;
   wire         w_enet_rx_arm = (r_enet_rx_arm_seq != enet_rx_arm_seq);
   /* bypass: the engine is back in S_IDLE in the rx_done cycle and may start a
    * latched frame then, before r_enet_rx_pos has advanced */
   wire  [31:0] w_enet_rx_pos = w_enet_rx_arm ? enet_rx_nbdp :
				enet_dma_rx_done ? w_enet_rx_next_nbdp :
				r_enet_rx_pos;
   always_ff@(posedge clk)
     begin
	if(reset)
	  begin
	     r_enet_rx_arm_seq <= 32'd0;
	     r_enet_rx_pos <= 32'd0;
	  end
	else
	  begin
	     r_enet_rx_arm_seq <= enet_rx_arm_seq;
	     r_enet_rx_pos <= w_enet_rx_pos;
	  end
     end // always_ff

   /* staging rings: the ARM never touches guest memory; the engine (u_dma's ENET
    * channels) owns the walk, BC write-back, CRBDP and completion. */
   wire        enet_dma_rx_done, enet_dma_tx_done;
   wire [31:0] enet_dma_crbdp;
   wire [31:0] w_ering_tx_crbdp;
   /* completion to enet_shim without the ARM: echo the kicked sequence at chain done
    * (the shim then clears ACTIVE and raises the TX IRQ), count RX deliveries */
   logic [31:0] r_ering_tx_kick, r_ering_tx_echo, r_ering_rx_seq;
   always_ff@(posedge clk)
     begin
	if(reset)
	  begin
	     r_ering_tx_kick <= 32'd0;
	     r_ering_tx_echo <= 32'd0;
	     r_ering_rx_seq  <= 32'd0;
	  end
	else
	  begin
	     r_ering_tx_kick <= w_enet_tx_go ? enet_tx_req_seq : r_ering_tx_kick;
	     r_ering_tx_echo <= enet_dma_tx_done ? r_ering_tx_kick : r_ering_tx_echo;
	     r_ering_rx_seq  <= r_ering_rx_seq + {31'd0, enet_dma_rx_done};
	  end
     end // always_ff
   assign w_shim_tx_rsp_seq = r_ering_tx_echo;
   assign w_shim_rx_rsp_seq = r_ering_rx_seq;
   assign w_shim_rx_crbdp   = enet_dma_crbdp;
   assign w_shim_tx_crbdp   = w_ering_tx_crbdp;

   // ---- DMA-coherence snoop: SCSI + ENET producers -------------------------
   // Push the line address of every DMA *store* that DRAM actually completed.
   // Sampled on the RESPONSE, not on req_valid: the arbiter is one-outstanding
   // and a master holds its request asserted until granted, so counting
   // assertions would push the same line many times.  scsi_dma drives its
   // request combinationally from r_state and only advances on dma_rsp_valid,
   // so w_m1_req_addr/opcode still describe the completing access this cycle.
   // opcode 5'd7 = line store (5'd4 = line load, which needs no invalidate).
   wire w_dma_store_done  = w_mem_rsp_dma  & (w_m1_req_opcode   == 5'd7);

   /* LOG_DMA_PA: log every DMA line-store PA (SCSI + ENET) so a corrupt value read
    * back from memory can be checked against DMA traffic to the SAME physical line.
    * Motivation: the xlog_find_zeroed crash (EPC 8820b62c, `lw a0,4(s2)') traces back
    * to `ld s2,48(sp)' -- s2 was READ FROM MEMORY, not computed, so the question is
    * whether DMA (or a stale line) clobbered that stack slot.  Answering it needs the
    * set of physical addresses DMA actually wrote.
    * Taken off *_store_done: the arbiter RESPONSE, one pulse per completed line store.
    * Sim-only ($display); no effect on the synthesizable path. */
`ifdef LOG_DMA_PA
   /* henry_soc has no cycle counter of its own; keep a local one so the log is
    * correlatable with the [tb] cyc prints and the retire trace. */
   logic [63:0] r_dmapa_cyc;
   always_ff@(posedge clk)
     begin
        r_dmapa_cyc <= reset ? 64'd0 : (r_dmapa_cyc + 64'd1);
     end // always_ff
   /* posedge, NOT the usual negedge logging idiom -- deliberately, and MEASURED:
    *   - negedge always_ff DOES fire here (both-edge canary), and the verilated C++
    *     dispatches both edges correctly (_sequent__TOP__8 on rising, __15 on falling).
    *   - but logging THIS signal on both edges in one run gave posedge 17, negedge 0.
    * w_dma_store_done is combinational off the arbiter response, true w.r.t. the state
    * ENTERING the posedge; Verilator re-settles comb logic against the post-posedge
    * state, so the pulse is already gone by the negedge dispatch.  A one-cycle comb
    * pulse must be sampled on the edge that produces it.  (negedge stays correct for
    * REGISTERED state -- that is what the other 36 negedge loggers sample.) */
   always_ff@(posedge clk)
     begin
        if(w_dma_store_done)
          begin
             $display("[dmapa] cyc=%0d master=%s pa=%x", r_dmapa_cyc, w_dma_owner_enet ? "enet" : "scsi", w_m1_req_addr);
          end
     end // always_ff
`endif


   // =====================================================================
   //  Device request FSM: one outstanding at a time (matches the core bus).
   //  On accept the selected device's combinational rdata is latched, then the
   //  response is delivered after DEV_LAT cycles.  Stores take effect on accept
   //  (the device slaves write on sel & is_store).
   // =====================================================================
   logic                          r_dev_busy;
   logic [$clog2(DEV_LAT+1)-1:0]   r_dev_cnt;
   logic [127:0]                   r_dev_rdata;

   wire w_dev_accept = c_req_valid & w_is_dev & ~r_dev_busy;

   // ---- arbiter master 2 is shared by the GIO window and the MC fill engine ----
   wire                 w_gio_req_valid;
   wire [`PA_WIDTH-1:0] w_gio_req_addr;
   wire [4:0]           w_gio_req_opcode;
   wire [511:0]         w_gio_req_store_data;
   wire [15:0]          w_gio_req_mask;
   wire                 w_gio_rsp_valid;
   wire                 w_mcdma_req_valid;
   wire [`PA_WIDTH-1:0] w_mcdma_req_addr;
   wire [127:0]         w_mcdma_req_store_data;
   wire                 w_mcdma_rsp_valid;

   /* MC VDMA (memory -> GIO): the MC starts it, dma_engine moves it into the GIO window */
   wire                 w_vdma_go, w_vdma_done;
   wire [31:0]          w_vdma_memadr, w_vdma_size, w_vdma_stride, w_vdma_count, w_vdma_gio;
   wire [3:0][31:0]     w_vdma_tlb_hi, w_vdma_tlb_lo;
   wire [31:0]          w_vdma_memadr_end;
   wire                 w_vdma_rec_valid, w_vdma_rec_ready;
   wire [63:0]          w_vdma_rec_lanes;
   wire [31:0]          w_vdma_rec_addr;
   wire                 w_mc_dma_irq;
   wire                 w_vdma_begin;     /* MC: a VDMA transfer is starting (the start store's cycle) */

   // ---- ARM-served GIO window (arbiter master 2): the Newport REX3 slot ----
   /* DISABLE_NEWPORT: build without graphics.  The REX3 window is not decoded, so
    * it falls into w_is_gio_empty and times out like an Indy with no graphics board
    * (IRIX/Linux probe the slot and come up on the serial console), and the Newport
    * IRQs (INT3 local1, incl. VRETRACE) are tied off so the ARM model cannot raise
    * them.  MC VDMA goes too (only Newport uses it): mc.sv completes memory -> GIO
    * at once and dma_engine pins its VDMA channel idle.  The 8042 (space 1) still
    * rides the window. */
   wire         w_gio_hit;
`ifdef DISABLE_NEWPORT
   assign w_is_gio = 1'b0;
   wire [7:0]   w_gio_local1 = 8'd0;
`else
   assign w_is_gio = w_gio_hit;
   wire [7:0]   w_gio_local1 = gio_irq[7:0];
`endif
   wire         w_gio_done;
   wire [127:0] w_gio_rdata;
   gio_window u_gio
     (.clk(clk), .reset(reset),
      .sel(w_dev_accept & (w_is_gio | w_is_kbd)), .is_store(~w_is_load), .space(w_is_kbd),
      .addr(c_req_addr[31:0]),
      .mask(c_req_mask), .wdata(c_req_store_data),
      .hit(w_gio_hit), .done(w_gio_done), .rdata(w_gio_rdata),
      .dma_begin(w_vdma_begin), .dma_end(w_vdma_done), .dma_valid(w_vdma_rec_valid), .dma_addr(w_vdma_rec_addr), .dma_lanes(w_vdma_rec_lanes),
      .dma_ready(w_vdma_rec_ready),
      .cons(gio_cons), .ans_lo(gio_ans_lo), .ans_hi(gio_ans_hi), .ans_seq(gio_ans_seq),
      .prod(gio_prod), .pend(gio_pend), .pend_seq(gio_pend_seq),
      .mem_req_valid(w_gio_req_valid), .mem_req_addr(w_gio_req_addr),
      .mem_req_opcode(w_gio_req_opcode), .mem_req_store_data(w_gio_req_store_data),
      .mem_req_mask(w_gio_req_mask),
      .mem_rsp_valid(w_gio_rsp_valid));

   wire [127:0] w_rd_mc, w_rd_hpc3, w_rd_iocdev, w_rd_int3;
   wire         w_scc_tx_valid;
   wire [7:0]   w_scc_tx_byte;
   wire         w_scc_tx_int;   // SCC Tx-buffer-empty IRQ (joins rx on map_src[5])

   /* the byte address of an access: line base + its first enabled byte lane */
   logic [3:0] t_first_lane;
   always_comb
     begin
	t_first_lane = 4'd0;
	for(integer b = 15; b >= 0; b = b - 1)
	  begin
	     if(c_req_mask[b])
	       begin
		  t_first_lane = 4'(b);
	       end
	  end
     end
   wire w_mc_abort_en, w_mc_buserr;
   wire w_gio_timeout = w_dev_accept & w_is_gio_empty & w_mc_abort_en;
   wire w_cpu_nomap   = w_dev_accept & w_is_nomap & c_req_uncached;
   mc #(.MEMCFG0(MEMCFG0)) u_mc
     (.clk(clk), .reset(reset),
      .sel(w_dev_accept & w_is_mc), .is_store(~w_is_load),
      .offs(c_req_addr[16:0]), .mask(c_req_mask), .wdata(c_req_store_data),
      .rdata(w_rd_mc),
      .gio_err(w_gio_timeout), .gio_err_addr({c_req_addr[31:4], t_first_lane}),
      .cpu_err(w_cpu_nomap), .cpu_err_addr({c_req_addr[31:4], t_first_lane}),
      .abort_en(w_mc_abort_en), .buserr(w_mc_buserr),
      .memcfg0(w_memcfg0), .memcfg1(w_memcfg1),
      .dma_req_valid(w_mcdma_req_valid), .dma_req_addr(w_mcdma_req_addr),
      .dma_req_store_data(w_mcdma_req_store_data), .dma_rsp_valid(w_mcdma_rsp_valid),
      .v_go(w_vdma_go), .v_memadr(w_vdma_memadr), .v_size(w_vdma_size), .v_stride(w_vdma_stride),
      .v_count(w_vdma_count), .v_gio(w_vdma_gio), .v_tlb_hi(w_vdma_tlb_hi), .v_tlb_lo(w_vdma_tlb_lo),
      .v_done(w_vdma_done), .v_memadr_end(w_vdma_memadr_end), .v_begin(w_vdma_begin), .dma_irq(w_mc_dma_irq),
      .vdma_stat0(vdma_stat0), .vdma_stat1(vdma_stat1));

   /* Master-2 mux.  The arbiter is one-outstanding and a master holds its request
    * until answered, so the owner is LOCKED from the cycle a request is presented
    * until its response (else the other could take the answer).  The GIO window wins
    * a tie: a held CPU load waits on it, while the fill engine only runs at boot. */
   logic r_m2_busy, n_m2_busy;
   logic r_m2_mc, n_m2_mc;
   logic t_m2_mc;
`ifndef ENABLE_DRAM_TRACE
   always_comb
     begin
        t_m2_mc   = r_m2_busy ? r_m2_mc : (~w_gio_req_valid & w_mcdma_req_valid);
        n_m2_busy = r_m2_busy;
        n_m2_mc   = r_m2_mc;
        if(w_arb_rsp_valid[2])
          begin
             n_m2_busy = 1'b0;
          end
        else if(w_trace_req_valid)
          begin
             n_m2_busy = 1'b1;
             n_m2_mc   = t_m2_mc;
          end
     end // always_comb
   assign w_trace_req_valid      = t_m2_mc ? w_mcdma_req_valid      : w_gio_req_valid;
   assign w_trace_req_addr       = t_m2_mc ? w_mcdma_req_addr       : w_gio_req_addr;
   assign w_trace_req_opcode     = t_m2_mc ? 5'd7                   : w_gio_req_opcode;
   assign w_trace_req_store_data = t_m2_mc ? {384'd0, w_mcdma_req_store_data} : w_gio_req_store_data;
   assign w_trace_req_mask       = t_m2_mc ? 16'hffff               : w_gio_req_mask;
   assign w_gio_rsp_valid        = w_arb_rsp_valid[2] & ~t_m2_mc;
   assign w_mcdma_rsp_valid      = w_arb_rsp_valid[2] &  t_m2_mc;
`else
   always_comb
     begin
        t_m2_mc   = 1'b0;
        n_m2_busy = 1'b0;
        n_m2_mc   = 1'b0;
     end // always_comb
   assign w_gio_rsp_valid   = 1'b0;
   assign w_mcdma_rsp_valid = 1'b0;
`endif
   always_ff @(posedge clk)
     begin
        if(reset)
          begin
             r_m2_busy <= 1'b0;
             r_m2_mc   <= 1'b0;
          end
        else
          begin
             r_m2_busy <= n_m2_busy;
             r_m2_mc   <= n_m2_mc;
          end
     end // always_ff

   hpc3 u_hpc3
     (.clk(clk), .reset(reset),
      .sel(w_dev_accept & w_is_hpc3), .is_store(~w_is_load),
      .offs(c_req_addr[18:0]), .mask(c_req_mask), .wdata(c_req_store_data),
      .rdata(w_rd_hpc3),
      /* SCSI0 DMA channel status -> hd0.bc / hd0.cntl.  The engine has no residual
       * output yet, so bc reads 0 (== chain complete), which is what it read before. */
      .scsi0_dma_busy(w_eng_busy), .scsi0_dma_irq(w_eng_irq), .scsi0_dma_bc(14'd0),
      .scsi0_hpc_intr(w_hpc_scsi_intr),
      // mem-to-mem DMA master -> DRAM arbiter
      .dma_req_valid(w_dma_req_valid),
      .dma_req_addr(w_dma_req_addr),
      .dma_req_opcode(w_dma_req_opcode),
      .dma_req_store_data(w_dma_req_store_data),
      .dma_req_mask(w_dma_req_mask),
      .dma_rsp_valid(w_mem_rsp_dma),
      .dma_rsp_load_data(mem2_rsp_load_data[127:0]));

   // ---- SCSI control shim (WD33C93 + HPC3 SCSI DMA channel); host-served disk ----
   // Shares the HPC3 window sel; its rdata ORs into w_rd_hpc3 (disjoint offsets).
   // INTRQ -> IOC2 local0 bit1 (SCSI0) -> IP2.
   wire [127:0] w_rd_scsi;
   wire         w_scsi_intrq;
   scsi_shim u_scsi
     (.clk(clk), .reset(reset),
      .sel(w_dev_accept & w_is_hpc3), .is_store(~w_is_load),
      .offs(c_req_addr[18:0]), .mask(c_req_mask), .wdata(c_req_store_data),
      .rdata(w_rd_scsi),
      .scsi_req_seq(scsi_req_seq), .scsi_req_nbdp(scsi_req_nbdp),
      .scsi_req_xfer_len(scsi_req_xfer_len), .scsi_req_cdb(scsi_req_cdb),
      .scsi_req_dest(scsi_req_dest), .scsi_req_lun(scsi_req_lun),
      .scsi_req_to_device(scsi_req_to_device),
      .scsi_rsp_seq(scsi_rsp_seq), .scsi_rsp_residual(scsi_rsp_residual),
      .scsi_rsp_scsi_status(scsi_rsp_scsi_status), .scsi_rsp_tgt_status(scsi_rsp_tgt_status),
      .sel_delay(scsi_sel_delay),
      // scsi_dma engine control (phase 2b wires these to the scsi_dma instance +
      // arbiter master 1; for now the engine is not yet instantiated -> done tied 0)
      .dma_go(w_sdma_go), .dma_nbdp(w_sdma_nbdp), .dma_to_device(w_sdma_to_dev),
      .dma_done(w_eng_done), .dma_rd_stalled(w_eng_rd_stalled), .dma_abort(w_sdma_abort),
      .scsi_intrq(w_scsi_intrq),
      .dbg(scsi_dbg));

   // ---- ENET control shim (Seeq 8003 + HPC3 ENET DMA channels); host-served tap ----
   // Shares the HPC3 window sel; its rdata ORs into the HPC3 mux (disjoint offsets).
   // ENET RX/TX channel IRQ -> IOC2 local0 bit3 (ENET) -> IP2.
   wire [127:0] w_rd_enet;
   wire         w_enet_intrq;
   enet_shim u_enet
     (.clk(clk), .reset(reset),
      .sel(w_dev_accept & w_is_hpc3), .is_store(~w_is_load),
      .offs(c_req_addr[18:0]), .mask(c_req_mask), .wdata(c_req_store_data),
      .rdata(w_rd_enet),
      .enet_tx_req_seq(enet_tx_req_seq), .enet_tx_nbdp(enet_tx_nbdp),
      .enet_tx_rsp_seq(w_shim_tx_rsp_seq),
      .enet_rx_arm_seq(enet_rx_arm_seq), .enet_rx_nbdp(enet_rx_nbdp),
      .enet_rx_rsp_seq(w_shim_rx_rsp_seq), .enet_rx_crbdp(w_shim_rx_crbdp), .enet_tx_crbdp(w_shim_tx_crbdp),
      .enet_station(enet_station), .enet_rx_cmd(enet_rx_cmd),
      .enet_intrq(w_enet_intrq), .dbg(enet_dbg));

   // ---- SCSI DMA engine: the ordered DRAM agent that walks the descriptor chain
   //      and moves data. ----
   /* staging rings (docs/arm-device-protocol.md): the disk side is served from the
    * staging region by the engine itself (w_eng_* is its memory port into the DMA
    * mux).  The ARM never touches guest memory and no longer sizes chains: each
    * chain posts a completion. */
   /* the unified DMA engine: SCSI, ENET TX and ENET RX channels on one memory port
    * and one byte mover (descriptor walks, staged-data moves, completion rings).
    * Inclusive-L2 coherence: its accesses go through one PRE-WBINV / access /
    * POST-WBINV wrapper (dma_snoop_shim) on arbiter master 1, so disk and network
    * data never meet a stale cached line; the shim owns the core's L2 snoop port. */
   wire [1:0]           w_dma_owner;
   dma_engine u_dma
     (.clk(clk), .reset(reset),
      .go(w_sdma_go), .nbdp(w_sdma_nbdp), .to_device(w_sdma_to_dev), .cancel(w_sdma_abort),
      .busy(w_eng_busy), .done(w_eng_done), .irq(w_eng_irq), .rd_stalled(w_eng_rd_stalled),
      .rd_beats(ring_scsi_rd_beats), .rd_seq(ring_scsi_rd_seq), .req_seq(scsi_req_seq),
      .cq_cons(ring_scsi_cq_cons),
      .tx_cons(ring_tx_cons), .rx_prod(ring_rx_prod),
      .tx_go(w_enet_tx_go), .tx_nbdp(enet_tx_nbdp),
      .tx_done(enet_dma_tx_done), .tx_crbdp(w_ering_tx_crbdp),
      .rx_armed(w_enet_rx_pos != 32'd0), .rx_nbdp(w_enet_rx_pos),
      .rx_done(enet_dma_rx_done), .rx_dropped(),
      .rx_crbdp(enet_dma_crbdp), .rx_next_nbdp(w_enet_rx_next_nbdp),
      .v_go(w_vdma_go), .v_memadr(w_vdma_memadr), .v_size(w_vdma_size), .v_stride(w_vdma_stride),
      .v_count(w_vdma_count), .v_gio(w_vdma_gio), .v_tlb_hi(w_vdma_tlb_hi), .v_tlb_lo(w_vdma_tlb_lo),
      .v_done(w_vdma_done), .v_memadr_end(w_vdma_memadr_end),
      .v_rec_valid(w_vdma_rec_valid), .v_rec_lanes(w_vdma_rec_lanes), .v_rec_addr(w_vdma_rec_addr),
      .v_rec_ready(w_vdma_rec_ready),
      .dn_req_valid(w_eng_req_valid), .dn_req_addr(w_eng_req_addr), .dn_req_opcode(w_eng_req_opcode),
      .dn_req_store_data(w_eng_req_store_data), .dn_req_mask(w_eng_req_mask),
      .dn_rsp_valid(w_seng_rsp_valid), .dn_rsp_load_data(w_seng_rsp_load_data),
      .owner(w_dma_owner));
   assign scsi_dma_done    = w_eng_done;
   assign w_dma_owner_enet = (w_dma_owner != 2'd0);
   dma_snoop_shim u_dma_snoop
     (.clk(clk), .reset(reset),
      .up_req_valid(w_eng_req_valid), .up_req_addr(w_eng_req_addr),
      .up_req_opcode(w_eng_req_opcode), .up_req_store_data(w_eng_req_store_data),
      .up_req_mask(w_eng_req_mask),
      .up_rsp_valid(w_seng_rsp_valid), .up_rsp_load_data(w_seng_rsp_load_data),
      .dn_req_valid(w_sdn_req_valid), .dn_req_addr(w_sdn_req_addr),
      .dn_req_opcode(w_sdn_req_opcode), .dn_req_store_data(w_sdn_req_store_data),
      .dn_req_mask(w_sdn_req_mask),
      .dn_rsp_valid(w_mem_rsp_dma), .dn_rsp_load_data(mem2_rsp_load_data),
      .snp_req_valid(w_snoop_valid), .snp_req_addr(w_snoop_addr), .snp_req_wbinv(w_snoop_wbinv),
      .snp_req_ack(w_snoop_ack), .snp_done(w_snoop_done));

   ioc u_ioc
     (.clk(clk), .reset(reset),
      .sel(w_dev_accept & w_is_ioc), .is_store(~w_is_load),
      .offs(c_req_addr[7:0]), .mask(c_req_mask), .wdata(c_req_store_data),
      .con_full(con_full),   // SCC RR0 Tx-ready reflects console-FIFO backpressure
      .rdata(w_rd_iocdev), .scc_tx_valid(w_scc_tx_valid), .scc_tx_byte(w_scc_tx_byte),
      .timer0_irq(w_ioc_timer0),
      .scc_rx_push(scc_rx_valid), .scc_rx_data(scc_rx_byte), .rx_avail(w_scc_rx_avail),
      .rx_full(scc_rx_full), .scc_tx_int(w_scc_tx_int));

   // INT3 interrupt multiplexor: shares the IOC2 access window (its registers sit
   // at lines 0x80/0x90/0xa0; ioc reads 0 there, so the rdatas simply OR). Live
   // sources: the 8254 counter0 -> Timer0 -> IP4, and the SCC serial line
   // (map_src[5] = Serial DUART, Rx-avail OR Tx-buffer-empty) -> MAP_INT0 -> IP2.
   // Other device source lines are tied 0.
   wire w_ioc_timer0;
   wire w_scc_rx_avail;
   int3 u_int3
     (.clk(clk), .reset(reset),
      .sel(w_dev_accept & w_is_ioc), .is_store(~w_is_load),
      .offs(c_req_addr[7:0]), .mask(c_req_mask), .wdata(c_req_store_data),
      .rdata(w_rd_int3),
      .local0_src({2'd0, w_mc_dma_irq, w_enet_intrq, 1'b0, w_scsi_intrq | w_hpc_scsi_intr, 1'b0}), .local1_src(w_gio_local1),  // local0[3]=ENET [1]=SCSI0; local1 = ARM-driven (gio_window devices)
      .map_src({2'd0, w_scc_rx_avail | w_scc_tx_int, gio_irq[8], 4'd0}),  // bit5 = Serial DUART (SCC Rx|Tx), bit4 = 8042 kbd/mouse (ARM-driven)
      .buserr({1'b0, w_mc_buserr, 1'b0}),   // [1] = MC bus error (docs/bus-errors.md)
      .timer0_irq(w_ioc_timer0), .timer1_irq(1'b0),
      .ip2(w_int3_ip2), .ip3(w_int3_ip3), .ip4(w_int3_ip4),
      .ip5(w_int3_ip5), .ip6(w_int3_ip6));

   wire [127:0] w_rd_ioc = w_rd_iocdev | w_rd_int3;
   wire [127:0] w_dev_sel_rdata = (w_is_gio_empty | w_is_nomem | w_is_nomap) ? 128'd0 :
				  w_is_mc ? w_rd_mc : (w_is_ioc ? w_rd_ioc : (w_rd_hpc3 | w_rd_scsi | w_rd_enet));

   /* a gio_window access completes when the window says so (stores once queued,
    * loads once the ARM has answered), not after DEV_LAT */
   logic r_dev_gio;
   logic r_dev_bad;     /* this device load timed out on GIO or hit a reserved PA: bus error */
   always_ff @(posedge clk) begin
      if(reset) begin
         r_dev_gio <= 1'b0;
         r_dev_bad <= 1'b0;
      end
      else if(w_dev_accept) begin
         r_dev_gio <= w_is_gio | w_is_kbd;
         r_dev_bad <= (w_gio_timeout | w_cpu_nomap) & w_is_load;
      end
   end

   always_ff @(posedge clk) begin
      if(reset) begin
         r_dev_busy  <= 1'b0;
         r_dev_cnt   <= '0;
         r_dev_rdata <= '0;
      end
      else if(w_dev_accept) begin
`ifdef SOC_DEV_TRACE
         $display("[soc-dev] %s %s addr=%h mask=%h sdata=%h",
                  w_is_mc ? "MC " : (w_is_ioc ? "IOC" : "HPC"),
                  w_is_load ? "ld" : "st", c_req_addr, c_req_mask, c_req_store_data);
`endif
         r_dev_busy  <= 1'b1;
         r_dev_cnt   <= DEV_LAT[$clog2(DEV_LAT+1)-1:0];
         r_dev_rdata <= w_dev_sel_rdata;
      end
      else if(r_dev_busy & r_dev_gio) begin
         if(w_gio_done)
           r_dev_busy <= 1'b0;
      end
      else if(r_dev_busy) begin
         if(r_dev_cnt == '0)
           r_dev_busy <= 1'b0;
         else
           r_dev_cnt <= r_dev_cnt - 1'b1;
      end
   end

   // =====================================================================
   //  Response mux: device response vs. external (pass-through) response.
   // =====================================================================
   wire w_dev_rsp = r_dev_busy & (r_dev_gio ? w_gio_done : (r_dev_cnt == '0));
   assign c_rsp_valid     = w_dev_rsp | w_mem_rsp_cpu;
   assign c_rsp_bad       = w_dev_rsp ? r_dev_bad : (w_mem_rsp_cpu & mem_rsp_bad);
   assign c_rsp_load_data = w_dev_rsp ? (r_dev_gio ? w_gio_rdata : r_dev_rdata) : mem_rsp_load_data;

   // =====================================================================
   //  Graphics-path counters (48b, free-running from reset; the ARM reads
   //  deltas through gfx_perf_sel / read 0x02).  They split where a Newport
   //  frame's time goes on the PL side:
   //   0 cycles
   //   1 CPU GIO stores accepted          2 cycles a CPU GIO access is outstanding
   //   3 ring writer waiting on AXI       4 ring writes completed (records + prod)
   //   5 VDMA busy (go .. done)           6 VDMA engine waiting on a memory read (incl. snoop)
   //   7 VDMA record waiting on the ring  8 VDMA records accepted by the ring
   // =====================================================================
   localparam int N_GFX_PERF = 9;
   logic [47:0] r_gfx_perf [0:N_GFX_PERF-1];
   logic [N_GFX_PERF-1:0] t_gfx_inc;
   logic        r_vdma_busy;
   always_ff @(posedge clk) begin
      if(reset)
        r_vdma_busy <= 1'b0;
      else if(w_vdma_go)
        r_vdma_busy <= 1'b1;
      else if(w_vdma_done)
        r_vdma_busy <= 1'b0;
   end
   always_comb begin
      t_gfx_inc[0] = 1'b1;
      t_gfx_inc[1] = w_dev_accept & w_is_gio & ~w_is_load;
      t_gfx_inc[2] = r_dev_busy & r_dev_gio;
      t_gfx_inc[3] = w_gio_req_valid & ~w_gio_rsp_valid;
      t_gfx_inc[4] = w_gio_req_valid & w_gio_rsp_valid;
      t_gfx_inc[5] = r_vdma_busy;
      t_gfx_inc[6] = w_eng_req_valid & (w_dma_owner == 2'd3) & ~w_seng_rsp_valid;
      t_gfx_inc[7] = w_vdma_rec_valid & ~w_vdma_rec_ready;
      t_gfx_inc[8] = w_vdma_rec_valid & w_vdma_rec_ready;
   end
   always_ff @(posedge clk) begin
      for(int i = 0; i < N_GFX_PERF; i++) begin
         if(reset)
           r_gfx_perf[i] <= '0;
         else if(t_gfx_inc[i])
           r_gfx_perf[i] <= r_gfx_perf[i] + 48'd1;
      end
   end
   always_comb begin
      if(gfx_perf_sel[4:1] < 4'(N_GFX_PERF))
        gfx_perf_data = gfx_perf_sel[0] ? {16'd0, r_gfx_perf[gfx_perf_sel[4:1]][47:32]} : r_gfx_perf[gfx_perf_sel[4:1]][31:0];
      else
        gfx_perf_data = 32'hdead0000 | {27'd0, gfx_perf_sel};
   end

   // =====================================================================
   //  SoC console FIFO (8-deep) -- exposed on the putchar_fifo_* port.
   //  Producers: the SCC UART TX (priority) and the core's putchar FIFO
   //  (drained when the SCC isn't enqueuing).  Consumer: putchar_fifo_pop.
   // =====================================================================
   logic [7:0] r_con_mem [0:7];
   logic [3:0] r_con_wptr, r_con_rptr;
   wire        con_empty = (r_con_wptr == r_con_rptr);
   wire        con_full  = (r_con_wptr[2:0] == r_con_rptr[2:0]) &
                           (r_con_wptr[3]  != r_con_rptr[3]);

   wire        enq_scc  = w_scc_tx_valid & ~con_full;
   wire        enq_core = ~enq_scc & ~cp_empty & ~con_full;
   assign      cp_pop   = enq_core;                      // pop core FIFO only when consumed
   wire        do_enq   = enq_scc | enq_core;
   wire [7:0]  enq_byte = enq_scc ? w_scc_tx_byte : cp_out;

   always_ff @(posedge clk) begin
      if(reset) begin
         r_con_wptr <= 4'd0;
         r_con_rptr <= 4'd0;
      end
      else begin
         if(do_enq) begin
            r_con_mem[r_con_wptr[2:0]] <= enq_byte;
            r_con_wptr <= r_con_wptr + 4'd1;
         end
         if(putchar_fifo_pop & ~con_empty)
           r_con_rptr <= r_con_rptr + 4'd1;
      end
   end

   assign putchar_fifo_out   = r_con_mem[r_con_rptr[2:0]];
   assign putchar_fifo_empty = con_empty;
   assign putchar_fifo_wptr  = r_con_wptr;
   assign putchar_fifo_rptr  = r_con_rptr;

endmodule // henry_soc
