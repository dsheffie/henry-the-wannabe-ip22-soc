`include "machine.vh"
// -----------------------------------------------------------------------------
// dram_trace.sv -- control-flow deep trace to a reserved DRAM ring.
//
// Purpose: the 32K BRAM flight recorder (core.sv ENABLE_RETIRE_TRACE) is too
// shallow to span the birth->crash window of the `be` corruption (the fork is
// >64K insns back).  This streams a COMPRESSED control-flow trace of the whole
// run to a reserved DRAM region, multiplexed onto the SAME external AXI MC via
// a third mem_arbiter master, so backward alignment vs the golden trace can
// find where silicon's PC stream first diverges.
//
// Codec (control-flow only -- finds the fork; values are a later phase):
//   * USERSPACE ONLY (pc[63:31]==0): kernel/interrupt insns are dropped -- they
//     don't change the userspace instruction sequence, and this halves the data
//     and gives the clean userspace stream the offline aligner consumes.
//   * On each NON-sequential userspace retiree (pc != last_pc+4) emit an 8-byte
//     record {from_pc[31:0], to_pc[31:0]}.  Sequential runs (incl. not-taken
//     branches and MIPS delay slots) are implicit and refilled offline (fixed 4B).
//   * Two records are packed per 128-bit beat and drained to a CIRCULAR ring.
//
// The FIFO absorbs bursts; on overflow a record is DROPPED and a sticky gap flag
// set -- the trace NEVER back-pressures retirement (mirrors the BRAM recorder's
// w_rt_stall=0), so it cannot alter the timing-sensitive bug.
//
// Master interface matches mem_arbiter.sv:26-34 (one outstanding, hold req until
// rsp).  opcode 7 = store, mask 16'hffff = full 16-byte line.
// -----------------------------------------------------------------------------
module dram_trace
  (input  logic                     clk,
   input  logic                     reset,
   input  logic                     arm,            // 1 = capture+drain; 0 = idle+reset ptrs
   input  logic [`PA_WIDTH-1:0]     ring_base,      // DRAM byte offset of the ring (16B aligned)
   input  logic [`PA_WIDTH-1:0]     ring_mask,      // (size-1) byte mask for circular wrap (2^k-1)

   // per-retire taps (program order: head then next-head)
   input  logic                     retire0_valid,
   input  logic [63:0]              retire0_pc,
   input  logic                     retire1_valid,
   input  logic [63:0]              retire1_pc,

   // mem_arbiter master port (one outstanding, fire + response pulse)
   output logic                     trace_req_valid,
   output logic [`PA_WIDTH-1:0]     trace_req_addr,
   output logic [127:0]             trace_req_store_data,
   output logic [4:0]               trace_req_opcode,
   output logic [15:0]              trace_req_mask,
   input  logic                     trace_rsp_valid,
   input  logic                     trace_rsp_bad,

   // status (readable by the ARM via a control reg)
   output logic [31:0]              trace_ring_wptr,   // bytes written since arm (pre-wrap count)
   output logic                     trace_overflow);   // sticky: a record was dropped

   localparam int FIFO_LG = 6;                 // 64 x 128-bit beats
   localparam int FIFO_N  = (1 << FIFO_LG);

   // ---------------- record generation (control-flow encode) ----------------
   // A userspace retiree at pc is "sequential" iff pc == r_last_pc + 4.  The
   // first captured retiree after arm has no predecessor -> seed r_last_pc and
   // do NOT emit (r_seeded gates it).
   logic [31:0]  r_last_pc, n_last_pc;
   logic         r_seeded,  n_seeded;

   // up to two records produced this cycle (one per retiree)
   logic         t_rec0_we, t_rec1_we;
   logic [63:0]  t_rec0,    t_rec1;            // {from_pc, to_pc}

`ifdef TRACE_ALL_PC
   // co-sim validation: capture EVERY retire (kernel + user) so the encoder can be
   // checked on boot code without booting to userspace.  Deployed build omits this.
   wire w_r0_user = retire0_valid;
   wire w_r1_user = retire1_valid;
`else
   wire w_r0_user = retire0_valid & (retire0_pc[63:31] == 33'd0);
   wire w_r1_user = retire1_valid & (retire1_pc[63:31] == 33'd0);
`endif
   wire [31:0] w_r0_pc = retire0_pc[31:0];
   wire [31:0] w_r1_pc = retire1_pc[31:0];

   always_comb
     begin
        n_last_pc = r_last_pc;
        n_seeded  = r_seeded;
        t_rec0_we = 1'b0;
        t_rec1_we = 1'b0;
        t_rec0    = 64'd0;
        t_rec1    = 64'd0;
        // retiree 0
        if(w_r0_user)
          begin
             if(r_seeded & (w_r0_pc != (n_last_pc + 32'd4)))
               begin
                  t_rec0_we = 1'b1;
                  t_rec0    = {n_last_pc, w_r0_pc};
               end
             n_last_pc = w_r0_pc;
             n_seeded  = 1'b1;
          end
        // retiree 1 (uses the post-retiree0 last_pc)
        if(w_r1_user)
          begin
             if(n_seeded & (w_r1_pc != (n_last_pc + 32'd4)))
               begin
                  t_rec1_we = 1'b1;
                  t_rec1    = {n_last_pc, w_r1_pc};
               end
             n_last_pc = w_r1_pc;
             n_seeded  = 1'b1;
          end
     end // always_comb

   always_ff @(posedge clk)
     begin
        if(reset | ~arm)
          begin
             r_last_pc <= 32'd0;
             r_seeded  <= 1'b0;
          end
        else
          begin
             r_last_pc <= n_last_pc;
             r_seeded  <= n_seeded;
          end
     end // always_ff

   // ---------------- pack two 8-byte records into a 128-bit beat -------------
   // r_hold holds a lone record waiting for its pair.  Producing beats:
   //   hold empty + 2 recs  -> emit {rec1, rec0}
   //   hold empty + 1 rec   -> hold = rec
   //   hold full  + 1 rec   -> emit {rec, hold}
   //   hold full  + 2 recs  -> emit {rec0, hold}; hold = rec1
   logic [63:0]  r_hold, n_hold;
   logic         r_hold_v, n_hold_v;
   logic         t_beat_we;
   logic [127:0] t_beat;

   always_comb
     begin
        n_hold    = r_hold;
        n_hold_v  = r_hold_v;
        t_beat_we = 1'b0;
        t_beat    = 128'd0;
        case({t_rec1_we, t_rec0_we})
          2'b01:       // one record (rec0)
            begin
               if(r_hold_v)
                 begin
                    t_beat_we = 1'b1;
                    t_beat    = {t_rec0, r_hold};
                    n_hold_v  = 1'b0;
                 end
               else
                 begin
                    n_hold    = t_rec0;
                    n_hold_v  = 1'b1;
                 end
            end
          2'b10:       // one record (rec1)
            begin
               if(r_hold_v)
                 begin
                    t_beat_we = 1'b1;
                    t_beat    = {t_rec1, r_hold};
                    n_hold_v  = 1'b0;
                 end
               else
                 begin
                    n_hold    = t_rec1;
                    n_hold_v  = 1'b1;
                 end
            end
          2'b11:       // two records (rec0 then rec1)
            begin
               if(r_hold_v)
                 begin
                    t_beat_we = 1'b1;
                    t_beat    = {t_rec0, r_hold};   // pair the older hold with rec0
                    n_hold    = t_rec1;             // rec1 waits for the next
                    n_hold_v  = 1'b1;
                 end
               else
                 begin
                    t_beat_we = 1'b1;
                    t_beat    = {t_rec1, t_rec0};
                    n_hold_v  = 1'b0;
                 end
            end
          default: ;   // no records
        endcase
     end // always_comb

   // ---------------- beat FIFO (128-bit) ------------------------------------
   logic [127:0]        r_fifo [FIFO_N-1:0];
   logic [FIFO_LG:0]    r_wr, n_wr;       // extra bit to distinguish full/empty
   logic [FIFO_LG:0]    r_rd, n_rd;
   wire [FIFO_LG:0]     w_cnt   = r_wr - r_rd;
   wire                 w_full  = (w_cnt == FIFO_N[FIFO_LG:0]);
   wire                 w_empty = (w_cnt == 0);
   logic                r_ovf, n_ovf;

   // a beat wants to enter but the FIFO is full -> drop + sticky overflow
   wire w_push = t_beat_we & ~w_full;
   wire w_drop = t_beat_we &  w_full;

   // ---------------- drain: one outstanding store to the ring ---------------
   logic                r_req, n_req;
   logic [`PA_WIDTH-1:0] r_woff, n_woff;    // circular byte offset into the ring
   logic [31:0]         r_bytes, n_bytes;   // total bytes written since arm

   wire w_pop = r_req & trace_rsp_valid;    // store accepted+done -> advance rd ptr

   always_comb
     begin
        n_wr    = r_wr;
        n_rd    = r_rd;
        n_ovf   = r_ovf | w_drop;
        n_req   = r_req;
        n_woff  = r_woff;
        n_bytes = r_bytes;

        if(w_push)
          begin
             n_wr = r_wr + 1'b1;
          end

        if(~r_req)
          begin
             if(~w_empty)
               begin
                  n_req = 1'b1;             // launch a store of the FIFO head
               end
          end
        else if(trace_rsp_valid)
          begin
             n_req   = 1'b0;               // store done: pop, advance ring, count
             n_rd    = r_rd + 1'b1;
             n_woff  = (r_woff + `PA_WIDTH'd16) & ring_mask;
             n_bytes = r_bytes + 32'd16;
          end
     end // always_comb

   always_ff @(posedge clk)
     begin
        if(reset | ~arm)
          begin
             r_wr    <= '0;
             r_rd    <= '0;
             r_ovf   <= 1'b0;
             r_req   <= 1'b0;
             r_woff  <= '0;
             r_bytes <= 32'd0;
             r_hold  <= 64'd0;
             r_hold_v<= 1'b0;
          end
        else
          begin
             r_wr    <= n_wr;
             r_rd    <= n_rd;
             r_ovf   <= n_ovf;
             r_req   <= n_req;
             r_woff  <= n_woff;
             r_bytes <= n_bytes;
             r_hold  <= n_hold;
             r_hold_v<= n_hold_v;
             if(w_push)
               begin
                  r_fifo[r_wr[FIFO_LG-1:0]] <= t_beat;
               end
          end
     end // always_ff

   // ---------------- outputs ------------------------------------------------
   assign trace_req_valid      = r_req;
   assign trace_req_addr       = (ring_base + r_woff);
   assign trace_req_store_data = r_fifo[r_rd[FIFO_LG-1:0]];
   assign trace_req_opcode     = 5'd7;      // store
   assign trace_req_mask       = 16'hffff;  // full 16-byte line
   assign trace_ring_wptr      = r_bytes;
   assign trace_overflow       = r_ovf;

endmodule // dram_trace
