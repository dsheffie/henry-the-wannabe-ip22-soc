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

module henry_soc
  #(// MC MEMCFG0 (bank0 cfg) as STORED: BE lw -> bswap.  0x00002023 -> 0x23200000
    // = 16 MB @ 0x08000000 (IRIX).  For 128 MB use 0x0000203f (-> 0x3f200000).
    parameter [31:0] MEMCFG0 = 32'h0000_2023
    )
  (input  logic                  clk,
   input  logic                  reset,
   input  logic                  extern_irq,

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
   output logic [`M_WIDTH-1:0]   epc,
   output logic [31:0]           status_reg,
   output logic [`M_WIDTH-1:0]   badvaddr,
   output logic [4:0]            cause,
   output logic                  took_irq,
   // retire register writeback taps (64-bit-address-bug localization)
   output logic [4:0]            retire_reg_ptr,
   output logic [`M_WIDTH-1:0]   retire_reg_data,
   output logic [4:0]            retire_reg_two_ptr,
   output logic [`M_WIDTH-1:0]   retire_reg_two_data,
   // FSM-state + trace-buffer taps (were tied off in the AXI wrapper)
   output logic [4:0]            core_state,
   output logic [2:0]            l1i_state,
   output logic [3:0]            l1d_state,
   output logic [3:0]            l2_state,
   output logic [3:0]            l2_rsp_state,
   output logic [`LG_ROB_ENTRIES:0] inflight,
   input  logic [11:0]           dbg_trace_index,
   output logic [31:0]           dbg_trace_data,
   output logic [8:0]            dbg_trace_wptr
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

   // =====================================================================
   //  r9999 core
   // =====================================================================
   core_l1d_l1i cpu
     (.clk(clk),
      .reset(reset),
      .retire_allowed(1'b1),
      .putchar_fifo_out(cp_out),
      .putchar_fifo_empty(cp_empty),
      .putchar_fifo_pop(cp_pop),
      .putchar_fifo_wptr(),
      .putchar_fifo_rptr(),
      .extern_irq(extern_irq),
      .single_step(1'b0),
      .step(1'b0),
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

      .retire_reg_ptr(retire_reg_ptr), .retire_reg_data(retire_reg_data), .retire_reg_valid(),
      .retire_reg_two_ptr(retire_reg_two_ptr), .retire_reg_two_data(retire_reg_two_data), .retire_reg_two_valid(),
      .retire_valid(retire_valid), .retire_two_valid(retire_two_valid),
      .retire_pc(retire_pc), .retire_two_pc(retire_two_pc),
      .retire_op(), .retire_two_op(),
      .branch_pc(), .branch_pc_valid(), .branch_fault(),
      .l1i_cache_accesses(), .l1i_cache_hits(),
      .l1d_cache_accesses(), .l1d_cache_hits(),
      .l2_cache_accesses(), .l2_cache_hits(),
      .got_break(got_break), .got_ud(got_ud), .got_bad_addr(got_bad_addr),
      .core_state(core_state), .l1i_state(l1i_state), .l1d_state(l1d_state), .l2_state(l2_state), .l2_rsp_state(l2_rsp_state),
      .inflight(inflight), .epc(epc), .status_reg(status_reg), .badvaddr(badvaddr), .cause(cause),
      .l1i_flush_done(), .l1d_flush_done(), .l2_flush_done(),
      .took_irq(took_irq), .cp0_count(),
      .dbg_head_pc(dbg_head_pc), .dbg_head_fetch_cycle(), .dbg_head_alloc_cycle(),
      .dbg_serialize_cycle(), .dbg_cycle(), .dbg_oldest_first_pending(),
      .dbg_trace_index(dbg_trace_index), .dbg_trace_data(dbg_trace_data), .dbg_trace_wptr(dbg_trace_wptr)
      );

   // =====================================================================
   //  Pass-through: requests that miss every modeled device go to the
   //  external memory bus unchanged.
   // =====================================================================
   assign mem_req_valid      = c_req_valid & ~w_is_dev;
   assign mem_req_addr       = c_req_addr;
   assign mem_req_store_data = c_req_store_data;
   assign mem_req_opcode     = c_req_opcode;
   assign mem_req_mask       = c_req_mask;

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

   wire [127:0] w_rd_mc, w_rd_hpc3, w_rd_ioc;
   wire         w_scc_tx_valid;
   wire [7:0]   w_scc_tx_byte;

   mc #(.MEMCFG0(MEMCFG0)) u_mc
     (.clk(clk), .reset(reset),
      .sel(w_dev_accept & w_is_mc), .is_store(~w_is_load),
      .offs(c_req_addr[16:0]), .mask(c_req_mask), .wdata(c_req_store_data),
      .rdata(w_rd_mc));

   hpc3 u_hpc3
     (.clk(clk), .reset(reset),
      .sel(w_dev_accept & w_is_hpc3), .is_store(~w_is_load),
      .offs(c_req_addr[18:0]), .mask(c_req_mask), .wdata(c_req_store_data),
      .rdata(w_rd_hpc3));

   ioc u_ioc
     (.clk(clk), .reset(reset),
      .sel(w_dev_accept & w_is_ioc), .is_store(~w_is_load),
      .offs(c_req_addr[7:0]), .mask(c_req_mask), .wdata(c_req_store_data),
      .con_full(con_full),   // SCC RR0 Tx-ready reflects console-FIFO backpressure
      .rdata(w_rd_ioc), .scc_tx_valid(w_scc_tx_valid), .scc_tx_byte(w_scc_tx_byte));

   wire [127:0] w_dev_sel_rdata = w_is_mc ? w_rd_mc : (w_is_ioc ? w_rd_ioc : w_rd_hpc3);

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
   assign c_rsp_valid     = w_dev_rsp | mem_rsp_valid;
   assign c_rsp_bad       = w_dev_rsp ? 1'b0 : mem_rsp_bad;
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
