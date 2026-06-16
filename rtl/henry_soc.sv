// -----------------------------------------------------------------------------
// henry_soc.sv -- Henry IP22 SoC top level.
//
// Wraps the r9999 core (core_l1d_l1i) and inlines RTL models of the boot-critical
// IP22 devices, translated from the r9999 C++ functional models:
//   * MC   -- memory controller     @ phys 0x1fa00000           (from sgi_mc.cc)
//   * HPC3/IOC2 register window      @ phys 0x1fb80000           (from sgi_hpc.cc)
//   * SCC  -- Z8530 serial console   @ phys 0x1fbd9830 (in HPC)  (from sgi_scc.cc)
//
// The core's L2-miss memory bus (mem_req_*/mem_rsp_*, 16-byte cache lines) flows
// through this module.  Requests that land on a modeled device are serviced here;
// every other request is PASSED THROUGH unchanged to the external memory bus, so
// the SoC can sit in front of RAM / an AXI bridge / the cosim memory.
//
// Memory protocol (from r9999 top.cc): mem_req_opcode==4 is a line load (return
// the 16-byte line as four 32-bit words), anything else is a store gated by the
// 16-bit byte mask; one request outstanding at a time; mem_rsp_valid pulses with
// the result.  MC/HPC are accessed a word at a time (word w at addr+4*w is real
// iff its 4-bit mask nibble == 0xF).  The SCC is byte-granular.
//
// Console: the SCC UART TX and the core's CP0-reg7 putchar stream are merged into
// one SoC-owned FIFO exposed on the existing putchar_fifo_* port -- so IRIX serial
// output (SCC) and r9999-native console output both emerge from the same port.
// -----------------------------------------------------------------------------
`include "machine.vh"

module henry_soc
  #(// MC MEMCFG0 (bank0 config) as STORED in the register.  The big-endian kernel
    // reads bswap32(stored): 0x00002023 -> 0x23200000 = 16 MB @ 0x08000000 (IRIX
    // 6.5.22 boot).  For 128 MB use 0x0000203f (-> 0x3f200000), e.g. Linux.
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
   output logic                  took_irq
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

   // core's CP0-reg7 putchar FIFO (now drained internally into the SoC console)
   logic [7:0]            cp_out;
   logic                  cp_empty;
   logic                  cp_pop;

   // ---- region decode (physical address) ----
   //   MC : 0x1fa00000 .. 0x1fafffff (1 MB)    HPC: 0x1fb80000 .. 0x1fbfffff (512 KB)
   //   SCC: 0x1fbd9830 .. 0x1fbd983f (16 B, carved out of the HPC window)
   wire w_is_mc  = (c_req_addr[31:20] == 12'h1fa);
   wire w_is_scc = (c_req_addr[31:4]  == 28'h1fbd983);
   wire w_is_hpc = (c_req_addr[31:19] == 13'h3f7) & ~w_is_scc;  // 0x1fb80000>>19
   wire w_is_dev = w_is_mc | w_is_hpc | w_is_scc;
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

      .retire_reg_ptr(), .retire_reg_data(), .retire_reg_valid(),
      .retire_reg_two_ptr(), .retire_reg_two_data(), .retire_reg_two_valid(),
      .retire_valid(retire_valid), .retire_two_valid(retire_two_valid),
      .retire_pc(retire_pc), .retire_two_pc(retire_two_pc),
      .retire_op(), .retire_two_op(),
      .branch_pc(), .branch_pc_valid(), .branch_fault(),
      .l1i_cache_accesses(), .l1i_cache_hits(),
      .l1d_cache_accesses(), .l1d_cache_hits(),
      .l2_cache_accesses(), .l2_cache_hits(),
      .got_break(got_break), .got_ud(got_ud), .got_bad_addr(got_bad_addr),
      .core_state(), .l1i_state(), .l1d_state(), .l2_state(), .l2_rsp_state(),
      .inflight(), .epc(epc), .status_reg(status_reg), .badvaddr(badvaddr), .cause(cause),
      .l1i_flush_done(), .l1d_flush_done(), .l2_flush_done(),
      .took_irq(took_irq), .cp0_count(),
      .dbg_head_pc(dbg_head_pc), .dbg_head_fetch_cycle(), .dbg_head_alloc_cycle(),
      .dbg_serialize_cycle(), .dbg_cycle(), .dbg_oldest_first_pending(),
      .dbg_trace_index('0), .dbg_trace_data(), .dbg_trace_wptr()
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
   //  MC -- memory controller (from sgi_mc.cc).  Register window @0x1fa00000;
   //  big-endian IRIX reads the +4/+c alias, so register select ignores bit 2:
   //  index = (offs>>3)&1.
   // =====================================================================
   // MC sysid/rev @0x1fa0001c.  MAME's kernel lw sees 0x00000013; the core's BE
   // lw bswaps device words, so store 0x13000000 (was 0x00000003 -> kernel saw
   // 0x03000000, wrong; a value-only bug the PC-diff misses, caught by the
   // tests/devregs check).  Low nibble = MC rev (3); rev<5 keeps the 22/14 shifts.
   localparam [31:0] MC_SYSID = 32'h13000000;

   logic [31:0] r_cpu_control [0:1];
   logic [31:0] r_memcfg      [0:1];
   logic [31:0] r_cpu_mem_acc, r_gio_mem_acc, r_rpss_div, r_gio64_arb;
   logic [31:0] r_rpss;                          // free-running RPSS counter
   logic [31:0] r_eeprom_ctrl;

   always_ff @(posedge clk) r_rpss <= reset ? 32'd0 : (r_rpss + 32'd1);

   // combinational MC register read (offs = addr & 0x1ffff)
   function automatic [31:0] mc_read(input [16:0] offs);
      logic [31:0] x;
      begin
         x = 32'd0;
         case(offs)
           17'h0000, 17'h0004, 17'h0008, 17'h000c: x = r_cpu_control[(offs>>3)&1];
           17'h0018, 17'h001c:                     x = MC_SYSID;
           17'h00c4, 17'h00cc:                     x = r_memcfg[(offs>>3)&1];
           17'h00d4:                               x = r_cpu_mem_acc;
           17'h00dc:                               x = r_gio_mem_acc;
           17'h0030:                               x = 32'h00000010;       // EEPROM: SDATAI high
           17'h1004:                               x = r_rpss / 32'd10;    // RPSS free-running
           default:                                x = 32'd0;
         endcase
         mc_read = x;
      end
   endfunction

   // =====================================================================
   //  HPC3 / IOC2 register window (from sgi_hpc.cc).  Offset = addr & 0x7ffff.
   // =====================================================================
   localparam [31:0] IOC2_SYSID = 32'h26000000;  // 0x26 = guinness/Indy board id
                                                 // (kernel bswaps device reads -> sees 0x26)
   logic [31:0] r_hpc_intstat, r_hpc_misc;

   function automatic [31:0] hpc_read(input [18:0] offs);
      logic [31:0] x;
      begin
         x = 32'd0;
         case(offs)
           19'h30000: x = r_hpc_intstat;
           19'h30004: x = r_hpc_misc;
           19'h59858: x = IOC2_SYSID;            // IOC2 SYSID @0x1fbd9858 (getsysid):
                                                 // 0x1fbd9858 & 0x7ffff = 0x59858 (was 0x58000,
                                                 // wrong offset -> getsysid mis-detected the board,
                                                 // MAME_QUESTIONS Q6). Value 0x26000000 -> kernel
                                                 // lw sees bswap = 0x00000026 (SYSID in bits[7:0]).
           default:   x = 32'd0;
         endcase
         hpc_read = x;
      end
   endfunction

   // =====================================================================
   //  SCC -- Z8530 serial console (from sgi_scc.cc).  16-byte window, byte
   //  granular, "ab_dc" order: byte b is a DATA register iff (b>>2)&1, else a
   //  CONTROL register.  Control reads return RR0 = Tx-empty|all-sent (0x44) so
   //  IRIX's du driver always thinks it can transmit; data writes are console TX.
   // =====================================================================
   localparam [7:0] SCC_RR0 = 8'h44;  // RR0_TX_EMPTY(0x04) | RR0_ALL_SENT(0x40)

   // =====================================================================
   //  Device request FSM: one outstanding at a time (matches the core bus).
   //  Latch the device request, wait DEV_LAT cycles, then drive the response.
   //  Stores take effect when latched.
   // =====================================================================
   logic                 r_dev_busy;
   logic [$clog2(DEV_LAT+1)-1:0] r_dev_cnt;
   logic                 r_dev_load;
   logic [127:0]         r_dev_rdata;

   wire w_dev_accept = c_req_valid & w_is_dev & ~r_dev_busy;

   // per-word full-word predicate (word w's 4-bit byte-mask nibble == 0xF)
   function automatic logic word_sel(input [15:0] mask, input int w);
      word_sel = (mask[4*w +: 4] == 4'hf);
   endfunction

   // SCC TX extraction (combinational): emit the masked DATA-register byte
   logic       scc_tx_valid;
   logic [7:0] scc_tx_byte;
   integer     b;
   always_comb begin
      scc_tx_valid = 1'b0;
      scc_tx_byte  = 8'h0;
      if(w_dev_accept & w_is_scc & ~w_is_load) begin
         for(b = 0; b < 16; b = b + 1)
           if(c_req_mask[b] & (((b>>2)&1) == 1)) begin
              scc_tx_valid = 1'b1;
              scc_tx_byte  = c_req_store_data[8*b +: 8];
           end
      end
   end

   integer i;
   always_ff @(posedge clk) begin
      if(reset) begin
         r_dev_busy <= 1'b0;
         r_dev_cnt  <= '0;
         r_dev_load <= 1'b0;
         r_dev_rdata<= '0;
         r_cpu_control[0] <= 32'd0; r_cpu_control[1] <= 32'd0;
         r_memcfg[0] <= MEMCFG0;
         r_memcfg[1] <= 32'd0;
         r_cpu_mem_acc <= 32'd0; r_gio_mem_acc <= 32'd0;
         r_rpss_div <= 32'd0; r_gio64_arb <= 32'd0; r_eeprom_ctrl <= 32'd0;
         r_hpc_intstat <= 32'd0; r_hpc_misc <= 32'd0;
      end
      else begin
         // accept a new device request
         if(w_dev_accept) begin
`ifdef SOC_DEV_TRACE
            $display("[soc-dev] %s %s addr=%h mask=%h sdata=%h",
                     w_is_mc ? "MC " : (w_is_hpc ? "HPC" : "SCC"),
                     w_is_load ? "ld" : "st", c_req_addr, c_req_mask, c_req_store_data);
`endif
            r_dev_busy <= 1'b1;
            r_dev_cnt  <= DEV_LAT[$clog2(DEV_LAT+1)-1:0];
            r_dev_load <= w_is_load;
            if(w_is_scc) begin
               // byte-granular: CONTROL reads -> RR0, DATA reads -> 0.
               for(i = 0; i < 16; i = i + 1)
                 r_dev_rdata[8*i +: 8] <= (c_req_mask[i] & (((i>>2)&1)==0)) ? SCC_RR0 : 8'h00;
               // DATA writes (console TX) handled combinationally -> console FIFO.
            end
            else begin
               // word-granular MC/HPC
               for(i = 0; i < 4; i = i + 1) begin
                  if(word_sel(c_req_mask, i)) begin
                     if(w_is_mc)
                       r_dev_rdata[32*i +: 32] <= mc_read((c_req_addr[16:0]) + 17'(4*i));
                     else
                       r_dev_rdata[32*i +: 32] <= hpc_read((c_req_addr[18:0]) + 19'(4*i));
                  end
                  else
                    r_dev_rdata[32*i +: 32] <= 32'd0;
               end
               if(!w_is_load) begin
                  for(i = 0; i < 4; i = i + 1) begin
                     if(word_sel(c_req_mask, i)) begin
                        if(w_is_mc)
                          mc_write(c_req_addr[16:0] + 17'(4*i), c_req_store_data[32*i +: 32]);
                        else
                          hpc_write(c_req_addr[18:0] + 19'(4*i), c_req_store_data[32*i +: 32]);
                     end
                  end
               end
            end
         end
         else if(r_dev_busy) begin
            if(r_dev_cnt == '0)
              r_dev_busy <= 1'b0;            // response delivered this cycle (see below)
            else
              r_dev_cnt <= r_dev_cnt - 1'b1;
         end
      end
   end

   // device store actions (tasks operate on the register flops above)
   task automatic mc_write(input [16:0] offs, input [31:0] x);
      case(offs)
        17'h0000, 17'h0004, 17'h0008, 17'h000c: r_cpu_control[(offs>>3)&1] <= x;
        17'h002c:                               r_rpss_div    <= x;
        17'h0084:                               r_gio64_arb   <= x;
        17'h00c4, 17'h00cc:                     r_memcfg[(offs>>3)&1] <= x;
        17'h00d4:                               r_cpu_mem_acc <= x;
        17'h00dc:                               r_gio_mem_acc <= x;
        17'h0030:                               r_eeprom_ctrl <= x;
        default: /* ec/fc error-status clear + unhandled: ignore */ ;
      endcase
   endtask

   task automatic hpc_write(input [18:0] offs, input [31:0] x);
      case(offs)
        19'h30004: r_hpc_misc <= x & 32'h3;
        default:   /* pbus/enet/scsi/pio windows: write-absorb */ ;
      endcase
   endtask

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

   wire        enq_scc  = scc_tx_valid & ~con_full;
   wire        enq_core = ~enq_scc & ~cp_empty & ~con_full;
   assign      cp_pop   = enq_core;                      // pop core FIFO only when consumed
   wire        do_enq   = enq_scc | enq_core;
   wire [7:0]  enq_byte = enq_scc ? scc_tx_byte : cp_out;

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
