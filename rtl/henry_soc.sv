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

// WD33C93 + HPC3 SCSI control shim (scsi_shim.sv) for the host-served disk path.
// MUTUALLY EXCLUSIVE with hpc3.sv `ENABLE_HPC3_DMA -- both claim the HPC3 DMA
// channel window @0x10000.  Uncomment here AND comment ENABLE_HPC3_DMA in hpc3.sv.
`define ENABLE_SCSI_SHIM 1
// Seeq 8003 + HPC3 ENET DMA control shim (enet_shim.sv) for the host-served tap
// ethernet path.  Shares the HPC3 window with scsi_shim (disjoint offsets);
// ENET IRQ -> IOC2 local0 bit3.  Serviced by henry_tb (sim) / the ARM PS (FPGA).
`define ENABLE_ENET_SHIM 1
// Lower-level SCSI: the scsi_dma engine (a real ordered DRAM master) walks the
// descriptor chain + moves data, replacing the host-service "offload the whole
// transaction" backdoor.  Occupies arbiter master 1 (mutually exclusive with the
// mem-to-mem hpc3 DMA).  Requires ENABLE_SCSI_SHIM.
//
// RETIRED (2026-06-28): the disk is now serviced by the host/PS through the
// scsi_req_*/scsi_rsp_* mailbox -- the ARM (FPGA) / henry_tb (sim) reads the CDB +
// descriptor pointer, walks the {BP,BC,DP} chain in shared DRAM, and does the disk
// I/O straight into the guest's buffers (see scsi_service.h / scsi_move).  The
// per-beat engine is no longer instantiated; the shim completes on scsi_rsp_seq.
// scsi_dma.sv is kept for its standalone unit test (sim/scsi_dma_test).
`define ENABLE_SCSI_DMA 1

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
   input  logic                  bp_enable,     // arms the resettable fault-trap
   input  logic                  fault_clear,   // clear fault-trap latch + re-arm + un-freeze
   input  logic [31:0]           bp_pc,         // driver-programmable breakpoint PC
   input  logic [31:0]           bp_wp_addr,    // driver-programmable store-address watchpoint VA
   input  logic [31:0]           bp_wp_val,     // expected corrupt store value (freeze-on)
   input  logic                  bp_fault_only, // freeze ONLY on a fault at bp_pc (ctrl bit19)
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
   input  logic [19:0]           dbg_trace_index,
   output logic [31:0]           dbg_trace_data,
   output logic [15:0]           dbg_trace_wptr,
   output logic [31:0]           dbg_rdchk,   /* reader-agreement checker status -> AXI 0x26[21:20] */
   output logic [31:0]           trace_ring_wptr,   // DRAM deep-trace: bytes written since arm
   output logic                  trace_overflow,    // DRAM deep-trace: a record was dropped (sticky)
   output logic [7:0]            cur_asid,          // current EntryHi ASID (readback for be-ASID discovery)
   // ---- SCSI shim mailbox (scsi_shim.sv): request out / completion in ----
   // FPGA: map to AXI-lite slv_regs; sim: henry_tb reads req_* / drives rsp_*.
   // (Tied off unless `ENABLE_SCSI_SHIM.)
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
   // ---- scsi_dma engine disk side: the ARM (PS / sim TB) feeds 16B beats across
   //      the ordered S00 slave-reg leg into a FIFO; the engine (the ONLY agent that
   //      touches MIPS memory) drains it and writes mem[BP] via M00.  READ direction:
   input  logic                  scsi_beat_push,     // 1-cycle: ARM enqueues scsi_beat_data
   input  logic [127:0]          scsi_beat_data,     // the 16-byte beat to enqueue
   output logic                  scsi_beat_full,     // flow control: ARM must not push when set
   output logic                  scsi_disk_wr_en,    // WRITE: engine produces a beat (v1: unused)
   output logic [127:0]          scsi_disk_wr_data,  // WRITE: mem -> disk beat
   output logic                  scsi_dma_done,      // engine finished the chain (TB sync)
   output logic [31:0]           scsi_dbg,           // shim debug viz (AXI PMU readback)
   // ---- enet_dma engine host side: the tap servicer (ARM/TB) pushes 16B beats of
   //      an ALREADY-FORMATTED rx frame ([2 pad][frame][1 status]); the engine is the
   //      ONLY agent that touches MIPS memory, so ENET writes become visible to the
   //      L2 (and the snoop FIFO) instead of bypassing the RTL entirely.
   input  logic                  enet_rx_frame_go,   // 1-cycle: a formatted frame is queued
   input  logic [13:0]           enet_rx_frame_len,  // its length in bytes (2+frame+1)
   input  logic                  enet_rx_beat_push,  // 1-cycle: enqueue enet_rx_beat_data
   input  logic [127:0]          enet_rx_beat_data,
   output logic                  enet_rx_beat_full,  // flow control
   output logic                  enet_tx_beat_valid, // TX: a beat is queued for the host
   input  logic                  enet_tx_beat_pop,   // host consumed it (1-cycle)
   output logic [127:0]          enet_tx_beat_data,
   output logic                  enet_dma_rx_done,   // frame delivered + descriptor released
   output logic                  enet_dma_rx_dropped,// ring full / buffer unusable
   output logic [31:0]           enet_dma_crbdp,     // descriptor just filled
   output logic                  enet_dma_tx_done,   // TX chain complete (host writes the tap)
   // ---- ENET shim mailbox (enet_shim.sv): Seeq 8003 + HPC3 ENET DMA channels ----
   // FPGA: map to AXI-lite slv_regs; sim: henry_tb tap servicer.  (Tied off unless
   // `ENABLE_ENET_SHIM.)  TX = guest-initiated doorbell; RX = service free-runs.
   output logic [31:0]           enet_tx_req_seq,    // TX doorbell (++ per transmit)
   output logic [31:0]           enet_tx_nbdp,       // TX descriptor-chain head (phys)
   input  logic [31:0]           enet_tx_rsp_seq,    // echoes enet_tx_req_seq when sent
   output logic [31:0]           enet_rx_arm_seq,    // ++ when guest arms rx_ctrl ACTIVE
   output logic [31:0]           enet_rx_nbdp,       // RX ring head (phys)
   input  logic [31:0]           enet_rx_rsp_seq,    // ++ by service per injected frame
   input  logic [31:0]           enet_rx_crbdp,      // service-maintained current RX desc
   output logic [47:0]           enet_station,       // programmed station MAC (for RX filter)
   output logic [7:0]            enet_rx_cmd,        // Seeq RX command (match mode)
   output logic [31:0]           enet_dbg            // ENET shim debug viz (AXI PMU readback)
   );

   localparam int unsigned DEV_LAT = 2;   // device response latency (cycles)

   // ---- core <-> SoC interposer wires ----
   logic                  c_req_valid;
   logic [`PA_WIDTH-1:0]  c_req_addr;
   logic [127:0]          c_req_store_data;
   logic [4:0]            c_req_opcode;
   logic [15:0]           c_req_mask;
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
   wire w_is_ioc  = (c_req_addr[31:8]  == 24'h1fbd98);
   wire w_is_hpc3 = (c_req_addr[31:19] == 13'h3f7) & ~w_is_ioc;   // 0x1fb80000>>19
   wire w_is_dev  = w_is_mc | w_is_hpc3 | w_is_ioc;
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
   // ---- DMA-coherence snoop (task #51) -------------------------------------
   // A DMA master writes DRAM behind the CPU caches, and IRIX cannot invalidate
   // r9999's L2 (Config.SC hides it -> the kernel issues zero SD ops), so nothing
   // in software can drop a stale L2 line for an address a device just wrote.
   // snoop_fifo collects every DMA line-store address and feeds the L2's snoop
   // port, which synthesizes a MEM_INVL per entry.
   wire                 w_snoop_valid;
   wire [`PA_WIDTH-1:0] w_snoop_addr;
   wire                 w_snoop_ack;
   wire                 w_snoop_full;

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
      .bp_enable(bp_enable),
      .fault_clear(fault_clear),
      .bp_pc(bp_pc),
      .bp_wp_addr(bp_wp_addr),
      .bp_wp_val(bp_wp_val),
      .bp_fault_only(bp_fault_only),
      .l2_nocache(l2_nocache),
      .in_flush_mode(),
      .resume(resume),
      .resume_pc(resume_pc),
      .ready_for_resume(ready_for_resume),

      .mem_req_valid(c_req_valid),
      .mem_req_addr(c_req_addr),
      .mem_req_store_data(c_req_store_data),
      .mem_req_opcode(c_req_opcode),
      .mem_req_mask(c_req_mask),
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
      .l1i_cache_accesses(), .l1i_cache_hits(),
      .l1d_cache_accesses(), .l1d_cache_hits(),
      .l2_cache_accesses(), .l2_cache_hits(),
      .got_break(got_break), .got_ud(got_ud), .got_bad_addr(got_bad_addr),
      .core_state(core_state), .l1i_state(l1i_state), .l1d_state(l1d_state), .l2_state(l2_state), .l2_rsp_state(l2_rsp_state),
      .inflight(inflight), .epc(epc), .status_reg(status_reg), .badvaddr(badvaddr), .cause(cause), .cause_ip(cause_ip), .dbg_frozen(dbg_frozen), .dbg_wp_data(dbg_wp_data),
      .l1i_flush_done(), .l1d_flush_done(), .l2_flush_done(),
      .snoop_req_valid(w_snoop_valid),
      .snoop_req_addr(w_snoop_addr),
      .snoop_req_ack(w_snoop_ack),
      .took_irq(took_irq), .cp0_count(cp0_count),
      .dbg_head_pc(dbg_head_pc), .dbg_head_status(dbg_head_status), .dbg_head_fetch_cycle(), .dbg_head_alloc_cycle(),
      .dbg_serialize_cycle(), .dbg_cycle(), .dbg_oldest_first_pending(),
      .dbg_trace_index(dbg_trace_index), .dbg_trace_data(dbg_trace_data), .dbg_trace_wptr(dbg_trace_wptr),
      .dbg_rdchk(dbg_rdchk)
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
   // arbiter master 1 select: SCSI DMA engine (ENABLE_SCSI_DMA) vs mem-to-mem hpc3.
   /* were dangling: the engine already computes ch_active (busy) and the XIE pulse,
    * which is exactly what hd0.cntl needs -- nothing consumed them before. */
   wire                 w_eng_busy, w_eng_irq;
   wire                 w_hpc_scsi_intr;   /* HPC3 XIE (DMA-complete) level */
   wire                 w_eng_req_valid, w_eng_done, w_eng_rd_stalled;
   wire [`PA_WIDTH-1:0] w_eng_req_addr;
   wire [127:0]         w_eng_req_store_data;
   wire [4:0]           w_eng_req_opcode;
   wire [15:0]          w_eng_req_mask;
`ifdef ENABLE_SCSI_DMA
   wire                 w_m1_req_valid      = w_eng_req_valid;
   wire [`PA_WIDTH-1:0] w_m1_req_addr       = w_eng_req_addr;
   wire [127:0]         w_m1_req_store_data = w_eng_req_store_data;
   wire [4:0]           w_m1_req_opcode     = w_eng_req_opcode;
   wire [15:0]          w_m1_req_mask       = w_eng_req_mask;
`else
   wire                 w_m1_req_valid      = w_dma_req_valid;
   wire [`PA_WIDTH-1:0] w_m1_req_addr       = w_dma_req_addr;
   wire [127:0]         w_m1_req_store_data = w_dma_req_store_data;
   wire [4:0]           w_m1_req_opcode     = w_dma_req_opcode;
   wire [15:0]          w_m1_req_mask       = w_dma_req_mask;
`endif

   // CPU master address: apply the IP22 System Memory Alias before arbitration.
   wire [`PA_WIDTH-1:0] w_cpu_req_addr = w_sysmem_alias
                          ? {c_req_addr[`PA_WIDTH-1:28], 1'b1, c_req_addr[26:0]}
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
   wire [127:0]         w_trace_req_store_data;
   wire [4:0]           w_trace_req_opcode;
   wire [15:0]          w_trace_req_mask;

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
      .trace_req_store_data(w_trace_req_store_data), .trace_req_opcode(w_trace_req_opcode),
      .trace_req_mask(w_trace_req_mask),
      .trace_rsp_valid(w_arb_rsp_valid[2]),          .trace_rsp_bad(mem_rsp_bad),
      .trace_ring_wptr(trace_ring_wptr), .trace_overflow(trace_overflow));

   // Parameterized weighted round-robin arbiter: master 0 = CPU, 1 = DMA, 2 = trace.
   // NSLOT=8, SLOT_MAP gives CPU slots 0..5, DMA slot 6, trace slot 7 -> CPU:DMA:trace
   // = 6:1:1.  Trace is low-weight (its FIFO absorbs bursts) so it cannot starve CPU
   // line fills.  Add masters / retune by the parameters (see mem_arbiter.sv).
   wire [2:0] w_arb_rsp_valid;
   /* master 3 = ENET DMA.  Slots: CPU x5, SCSI x1, trace x1, ENET x1 -- ENET moves
    * at most an MTU per frame so one slot in eight is ample, and starving the CPU
    * to service a NIC would be the wrong trade. */
   mem_arbiter #(.N(4), .NSLOT(8), .LG_N(2), .SLOT_MAP(16'b11_10_01_00_00_00_00_00)) u_arb
     (.clk(clk), .reset(reset),
      .m_req_valid     ({w_enet_req_valid,      w_trace_req_valid,      w_m1_req_valid,      w_cpu_dram_req}),
      .m_req_addr      ({w_enet_req_addr,       w_trace_req_addr,       w_m1_req_addr,       w_cpu_req_addr}),
      .m_req_store_data({w_enet_req_store_data, w_trace_req_store_data, w_m1_req_store_data, c_req_store_data}),
      .m_req_opcode    ({w_enet_req_opcode,     w_trace_req_opcode,     w_m1_req_opcode,     c_req_opcode}),
      .m_req_mask      ({w_enet_req_mask,       w_trace_req_mask,       w_m1_req_mask,       c_req_mask}),
      .m_rsp_valid     (w_arb_rsp_valid),
      .m_rsp_load_data (),                // CPU/DMA read mem_rsp_load_data directly
      .m_rsp_bad       (),
      .mem_req_valid(mem_req_valid),           .mem_req_addr(mem_req_addr),
      .mem_req_store_data(mem_req_store_data), .mem_req_opcode(mem_req_opcode),
      .mem_req_mask(mem_req_mask),
      .mem_rsp_valid(mem_rsp_valid),           .mem_rsp_load_data(mem_rsp_load_data),
      .mem_rsp_bad(mem_rsp_bad));

   wire w_mem_rsp_cpu = w_arb_rsp_valid[0];   // master 0 = CPU
   wire w_mem_rsp_dma = w_arb_rsp_valid[1];   // master 1 = DMA

   wire w_mem_rsp_enet = w_arb_rsp_valid[3];  // master 3 = ENET DMA

   // =====================================================================
   //  ENET DMA engine (arbiter master 3).  Replaces the host-served path in
   //  which henry_tb / the ARM wrote the guest's RX buffers DIRECTLY, invisible
   //  to the L2.  Now every ENET byte lands via the same ordered DRAM port the
   //  CPU uses, so the snoop FIFO above sees it and the L2 cannot serve a stale
   //  line for a buffer the NIC just filled.
   // =====================================================================
   wire                 w_enet_req_valid;
   wire [`PA_WIDTH-1:0] w_enet_req_addr;
   wire [127:0]         w_enet_req_store_data;
   wire [4:0]           w_enet_req_opcode;
   wire [15:0]          w_enet_req_mask;
   wire                 w_enet_rx_pop, w_enet_rx_empty;
   wire [127:0]         w_enet_rx_rdata;

   /* TX doorbell: enet_shim bumps enet_tx_req_seq when the guest kicks a transmit.
    * Edge-detect it here -- with the engine present the RTL consumes the doorbell
    * itself instead of handing it to the host servicer. */
   logic [31:0] r_enet_tx_seq;
   wire         w_enet_tx_go = (r_enet_tx_seq != enet_tx_req_seq);
   always_ff@(posedge clk)
     begin
	r_enet_tx_seq <= reset ? 32'd0 : enet_tx_req_seq;
     end

   /* TX beats leave the engine as a 1-cycle pulse; the ARM/TB polls over AXI and
    * cannot catch pulses, so buffer them.  Consumer pops via enet_tx_beat_pop. */
   wire         w_enet_tx_fifo_full, w_enet_tx_fifo_empty;
   wire [127:0] w_enet_tx_fifo_rdata;
   wire         w_enet_tx_beat_en_i;
   wire [127:0] w_enet_tx_beat_data_i;
   scsi_beat_fifo u_enet_tx_fifo
     (.clk(clk), .reset(reset),
      .push(w_enet_tx_beat_en_i), .wdata(w_enet_tx_beat_data_i), .full(w_enet_tx_fifo_full),
      .pop(enet_tx_beat_pop), .rdata(w_enet_tx_fifo_rdata), .empty(w_enet_tx_fifo_empty));
   assign enet_tx_beat_data  = w_enet_tx_fifo_rdata;
   assign enet_tx_beat_valid = ~w_enet_tx_fifo_empty;

   scsi_beat_fifo u_enet_rx_fifo
     (.clk(clk), .reset(reset),
      .push(enet_rx_beat_push), .wdata(enet_rx_beat_data), .full(enet_rx_beat_full),
      .pop(w_enet_rx_pop), .rdata(w_enet_rx_rdata), .empty(w_enet_rx_empty));

   enet_dma u_enet_dma
     (.clk(clk), .reset(reset),
      .rx_go(enet_rx_frame_go), .rx_nbdp(enet_rx_nbdp), .rx_len(enet_rx_frame_len),
      .rx_busy(), .rx_done(enet_dma_rx_done), .rx_dropped(enet_dma_rx_dropped),
      .rx_crbdp(enet_dma_crbdp), .rx_next_nbdp(),
      .tx_go(w_enet_tx_go), .tx_nbdp(enet_tx_nbdp), .tx_busy(),
      .tx_done(enet_dma_tx_done), .irq(),
      .dma_req_valid(w_enet_req_valid), .dma_req_addr(w_enet_req_addr),
      .dma_req_opcode(w_enet_req_opcode), .dma_req_store_data(w_enet_req_store_data),
      .dma_req_mask(w_enet_req_mask),
      .dma_rsp_valid(w_mem_rsp_enet), .dma_rsp_load_data(mem_rsp_load_data),
      .rx_rd_en(w_enet_rx_pop), .rx_rd_data(w_enet_rx_rdata),
      .rx_rd_valid(~w_enet_rx_empty),
      .tx_wr_en(w_enet_tx_beat_en_i), .tx_wr_data(w_enet_tx_beat_data_i));

   // ---- DMA-coherence snoop: SCSI + ENET producers -------------------------
   // Push the line address of every DMA *store* that DRAM actually completed.
   // Sampled on the RESPONSE, not on req_valid: the arbiter is one-outstanding
   // and a master holds its request asserted until granted, so counting
   // assertions would push the same line many times.  scsi_dma drives its
   // request combinationally from r_state and only advances on dma_rsp_valid,
   // so w_m1_req_addr/opcode still describe the completing access this cycle.
   // opcode 5'd7 = line store (5'd4 = line load, which needs no invalidate).
   wire w_dma_store_done  = w_mem_rsp_dma  & (w_m1_req_opcode   == 5'd7);
   wire w_enet_store_done = w_mem_rsp_enet & (w_enet_req_opcode == 5'd7);
   /* The arbiter grants one master at a time, so at most one of these can be true
    * in a cycle -- no arbitration needed on the FIFO push port. */
   /* DISABLE_DMA_SNOOP: build-time A/B knob for the DMA->L2 snoop.  Default is
    * unchanged (snoop ON); pass +define+DISABLE_DMA_SNOOP to hold the FIFO push low
    * so the L2 never sees a DMA invalidate.  Added to run the controlled pair against
    * the 4MB-L2 kernel panic -- proving whether the snoop is load-bearing needs an
    * otherwise byte-identical build with it off. */
`ifdef DISABLE_DMA_SNOOP
   wire                 w_snoop_push = 1'b0;
`else
   wire                 w_snoop_push = w_dma_store_done | w_enet_store_done;
`endif
   wire [`PA_WIDTH-1:0] w_snoop_push_addr = w_dma_store_done ? w_m1_req_addr
                                                            : w_enet_req_addr;

   /* LOG_DMA_PA: log every DMA line-store PA (SCSI + ENET) so a corrupt value read
    * back from memory can be checked against DMA traffic to the SAME physical line.
    * Motivation: the xlog_find_zeroed crash (EPC 8820b62c, `lw a0,4(s2)') traces back
    * to `ld s2,48(sp)' -- s2 was READ FROM MEMORY, not computed, so the question is
    * whether DMA (or a stale line) clobbered that stack slot.  Answering it needs the
    * set of physical addresses DMA actually wrote.
    * Deliberately taken off *_store_done (the arbiter RESPONSE, one pulse per completed
    * line store) and NOT off the snoop push -- the push is compiled out by
    * DISABLE_DMA_SNOOP, and the log must work in BOTH arms of that A/B.
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
             $display("[dmapa] cyc=%0d master=scsi pa=%x", r_dmapa_cyc, w_m1_req_addr);
          end
        if(w_enet_store_done)
          begin
             $display("[dmapa] cyc=%0d master=enet pa=%x", r_dmapa_cyc, w_enet_req_addr);
          end
     end // always_ff
`endif

   snoop_fifo #(.LG_DEPTH(4)) u_snoop
     (.clk(clk), .reset(reset),
      .push_valid(w_snoop_push),
      .push_addr(w_snoop_push_addr),
      .full(w_snoop_full),
      .snoop_req_valid(w_snoop_valid),
      .snoop_req_addr(w_snoop_addr),
      .snoop_req_ack(w_snoop_ack));

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

   wire [127:0] w_rd_mc, w_rd_hpc3, w_rd_iocdev, w_rd_int3;
   wire         w_scc_tx_valid;
   wire [7:0]   w_scc_tx_byte;
   wire         w_scc_tx_int;   // SCC Tx-buffer-empty IRQ (joins rx on map_src[5])

   mc #(.MEMCFG0(MEMCFG0)) u_mc
     (.clk(clk), .reset(reset),
      .sel(w_dev_accept & w_is_mc), .is_store(~w_is_load),
      .offs(c_req_addr[16:0]), .mask(c_req_mask), .wdata(c_req_store_data),
      .rdata(w_rd_mc));

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
      .dma_rsp_load_data(mem_rsp_load_data));

   // ---- SCSI control shim (WD33C93 + HPC3 SCSI DMA channel); host-served disk ----
   // Shares the HPC3 window sel; its rdata ORs into w_rd_hpc3 (disjoint offsets).
   // INTRQ -> IOC2 local0 bit1 (SCSI0) -> IP2.
`ifdef ENABLE_SCSI_SHIM
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
`else
   wire [127:0] w_rd_scsi     = 128'd0;
   wire         w_scsi_intrq  = 1'b0;
   assign scsi_dbg            = 32'd0;
   assign scsi_req_seq        = 32'd0;
   assign scsi_req_nbdp       = 32'd0;
   assign scsi_req_xfer_len   = 32'd0;
   assign scsi_req_cdb        = 128'd0;
   assign scsi_req_dest       = 8'd0;
   assign scsi_req_lun        = 8'd0;
   assign scsi_req_to_device  = 1'b0;
   assign w_sdma_go = 1'b0; assign w_sdma_nbdp = 32'd0; assign w_sdma_to_dev = 1'b0;
   assign w_sdma_abort = 1'b0;
`endif

   // ---- ENET control shim (Seeq 8003 + HPC3 ENET DMA channels); host-served tap ----
   // Shares the HPC3 window sel; its rdata ORs into the HPC3 mux (disjoint offsets).
   // ENET RX/TX channel IRQ -> IOC2 local0 bit3 (ENET) -> IP2.
`ifdef ENABLE_ENET_SHIM
   wire [127:0] w_rd_enet;
   wire         w_enet_intrq;
   enet_shim u_enet
     (.clk(clk), .reset(reset),
      .sel(w_dev_accept & w_is_hpc3), .is_store(~w_is_load),
      .offs(c_req_addr[18:0]), .mask(c_req_mask), .wdata(c_req_store_data),
      .rdata(w_rd_enet),
      .enet_tx_req_seq(enet_tx_req_seq), .enet_tx_nbdp(enet_tx_nbdp),
      .enet_tx_rsp_seq(enet_tx_rsp_seq),
      .enet_rx_arm_seq(enet_rx_arm_seq), .enet_rx_nbdp(enet_rx_nbdp),
      .enet_rx_rsp_seq(enet_rx_rsp_seq), .enet_rx_crbdp(enet_rx_crbdp),
      .enet_station(enet_station), .enet_rx_cmd(enet_rx_cmd),
      .enet_intrq(w_enet_intrq), .dbg(enet_dbg));
`else
   wire [127:0] w_rd_enet     = 128'd0;
   wire         w_enet_intrq  = 1'b0;
   assign enet_dbg            = 32'd0;
   assign enet_tx_req_seq     = 32'd0;
   assign enet_tx_nbdp        = 32'd0;
   assign enet_rx_arm_seq     = 32'd0;
   assign enet_rx_nbdp        = 32'd0;
   assign enet_station        = 48'd0;
   assign enet_rx_cmd         = 8'd0;
`endif

   // ---- SCSI DMA engine: the ordered DRAM agent that walks the descriptor chain
   //      and moves data; disk side streams 16B beats to the TB/ARM disk media. ----
`ifdef ENABLE_SCSI_DMA
   // ARM-fed beat FIFO -> engine disk-read port (the engine stalls when empty).
   wire         w_fifo_pop, w_fifo_empty;
   wire [127:0] w_fifo_rdata;
   scsi_beat_fifo u_scsi_beat_fifo
     (.clk(clk), .reset(reset),
      .push(scsi_beat_push), .wdata(scsi_beat_data), .full(scsi_beat_full),
      .pop(w_fifo_pop), .rdata(w_fifo_rdata), .empty(w_fifo_empty));
   scsi_dma u_scsi_dma
     (.clk(clk), .reset(reset),
      .go(w_sdma_go), .nbdp(w_sdma_nbdp), .to_device(w_sdma_to_dev),
      .busy(w_eng_busy), .done(w_eng_done), .irq(w_eng_irq), .rd_stalled(w_eng_rd_stalled),
      .dma_req_valid(w_eng_req_valid), .dma_req_addr(w_eng_req_addr),
      .dma_req_opcode(w_eng_req_opcode), .dma_req_store_data(w_eng_req_store_data),
      .dma_req_mask(w_eng_req_mask),
      .dma_rsp_valid(w_mem_rsp_dma), .dma_rsp_load_data(mem_rsp_load_data),
      .disk_rd_en(w_fifo_pop), .disk_rd_data(w_fifo_rdata), .disk_rd_valid(~w_fifo_empty),
      .cancel(w_sdma_abort),
      .disk_wr_en(scsi_disk_wr_en), .disk_wr_data(scsi_disk_wr_data));
   assign scsi_dma_done = w_eng_done;
`else
   assign w_eng_req_valid = 1'b0, w_eng_req_addr = '0, w_eng_req_store_data = '0,
          w_eng_req_opcode = 5'd0, w_eng_req_mask = 16'd0, w_eng_done = 1'b0,
          w_eng_rd_stalled = 1'b0;
   assign scsi_beat_full = 1'b0, scsi_disk_wr_en = 1'b0, scsi_disk_wr_data = '0,
          scsi_dma_done = 1'b0;
`endif

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
      .local0_src({3'd0, w_enet_intrq, 1'b0, w_scsi_intrq | w_hpc_scsi_intr, 1'b0}), .local1_src(8'd0),  // local0[3]=ENET [1]=SCSI0
      .map_src({2'd0, w_scc_rx_avail | w_scc_tx_int, 5'd0}),  // bit5 = Serial DUART (SCC Rx|Tx)
      .buserr(3'd0),
      .timer0_irq(w_ioc_timer0), .timer1_irq(1'b0),
      .ip2(w_int3_ip2), .ip3(w_int3_ip3), .ip4(w_int3_ip4),
      .ip5(w_int3_ip5), .ip6(w_int3_ip6));

   wire [127:0] w_rd_ioc = w_rd_iocdev | w_rd_int3;
   wire [127:0] w_dev_sel_rdata = w_is_mc ? w_rd_mc : (w_is_ioc ? w_rd_ioc : (w_rd_hpc3 | w_rd_scsi | w_rd_enet));

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
   wire w_dev_rsp = r_dev_busy & (r_dev_cnt == '0);
   assign c_rsp_valid     = w_dev_rsp | w_mem_rsp_cpu;
   assign c_rsp_bad       = w_dev_rsp ? 1'b0 : (w_mem_rsp_cpu & mem_rsp_bad);
   assign c_rsp_load_data = w_dev_rsp ? r_dev_rdata : mem_rsp_load_data;

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
