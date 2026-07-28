`include "machine.vh"
// -----------------------------------------------------------------------------
// dram_trace.sv -- COMPRESSED control-flow deep trace to a reserved DRAM ring.
//
// Streams a bit-packed varint control-flow trace of the whole run to a reserved
// DRAM region (multiplexed onto the external AXI MC via a 3rd mem_arbiter
// master) so backward alignment vs the golden trace can find where silicon's PC
// stream first forks (the be corruption fork is >64K insns back, nondeterministic).
//
// Codec (matches the sw prototype trace_codec.py; offline decode = its BitReader):
//   * USERSPACE only (pc[63:31]==0) unless TRACE_ALL_PC.
//   * Stream = a 32-bit SEED pc (first userspace retire), then per retire:
//        '1'                               = sequential (pc == last_pc+4)
//        '0' + LEB128(zigzag(pc-(last+4))) = taken branch (delta)
//     Sequential runs cost 1 bit; small taken deltas ~1-2 bytes.  ~0.3 B/retire
//     vs the 8 B/taken-record of the old uncompressed scheme -> ~5x less DRAM
//     traffic, which is REQUIRED: uncompressed overflowed the drain, wrapped the
//     ring, AND slowed reconfigure past reach of the crash.
//   * Bits packed LSB-first; flushed as 128-bit beats to a CIRCULAR ring.
//
// Never back-pressures retirement (FIFO drop + sticky overflow) so it can't
// perturb the timing-sensitive bug.  Master iface = mem_arbiter.sv (1 outstanding,
// opcode 7 store, mask 16'hffff).
// -----------------------------------------------------------------------------
module dram_trace
  (input  logic                     clk,
   input  logic                     reset,
   input  logic                     arm,
   input  logic [`PA_WIDTH-1:0]     ring_base,
   input  logic [`PA_WIDTH-1:0]     ring_mask,

   input  logic                     retire0_valid,
   input  logic [63:0]              retire0_pc,
   input  logic                     retire1_valid,
   input  logic [63:0]              retire1_pc,

   output logic                     trace_req_valid,
   output logic [`PA_WIDTH-1:0]     trace_req_addr,
   output logic [127:0]             trace_req_store_data,
   output logic [4:0]               trace_req_opcode,
   output logic [15:0]              trace_req_mask,
   input  logic                     trace_rsp_valid,
   input  logic                     trace_rsp_bad,

   output logic [31:0]              trace_ring_wptr,
   output logic                     trace_overflow);

   localparam int FIFO_LG = 6;                 // 64 x 128-bit beats
   localparam int FIFO_N  = (1 << FIFO_LG);

   // ================= per-retire control-flow encode =================
   logic [31:0]  r_last_pc, n_last_pc;
   logic         r_seeded,  n_seeded;

`ifdef TRACE_ALL_PC
   wire w_r0_user = retire0_valid;
   wire w_r1_user = retire1_valid;
`else
   wire w_r0_user = retire0_valid & (retire0_pc[63:31] == 33'd0);
   wire w_r1_user = retire1_valid & (retire1_pc[63:31] == 33'd0);
`endif
   wire [31:0] w_r0_pc = retire0_pc[31:0];
   wire [31:0] w_r1_pc = retire1_pc[31:0];

   // ---- retiree 0 encode (uses r_last_pc/r_seeded) ----
   wire [31:0] w_d0  = w_r0_pc - (r_last_pc + 32'd4);
   wire [32:0] w_zz0 = {w_d0, 1'b0} ^ {33{w_d0[31]}};              // zigzag
   wire [2:0]  w_nb0 = (|w_zz0[32:28]) ? 3'd5 : (|w_zz0[27:21]) ? 3'd4 :
                       (|w_zz0[20:14]) ? 3'd3 : (|w_zz0[13:7])  ? 3'd2 : 3'd1;
   wire [39:0] w_leb0 = { {1'b0, 2'b00, w_zz0[32:28]},            // byte4 (cont=0)
                          {(w_nb0>3'd4), w_zz0[27:21]},           // byte3
                          {(w_nb0>3'd3), w_zz0[20:14]},           // byte2
                          {(w_nb0>3'd2), w_zz0[13:7]},            // byte1
                          {(w_nb0>3'd1), w_zz0[6:0]} };           // byte0 (LSB group)
   // code0 (LSB-first) + bit length
   wire [40:0] w_code0 = ~r_seeded ? {9'd0, w_r0_pc} :            // seed: 32-bit pc
                         (w_d0==32'd0) ? 41'd1 :                  // seq: '1'
                         {w_leb0, 1'b0};                          // taken: '0' + LEB
   wire [6:0]  w_len0  = ~r_seeded ? 7'd32 :
                         (w_d0==32'd0) ? 7'd1 :
                         (7'd1 + {1'b0,w_nb0,3'd0});              // 1 + 8*nb

   // ---- retiree 1 encode (uses the state AFTER retiree 0) ----
   wire [31:0] w_last1   = w_r0_user ? w_r0_pc : r_last_pc;
   wire        w_seeded1 = w_r0_user ? 1'b1    : r_seeded;
   wire [31:0] w_d1  = w_r1_pc - (w_last1 + 32'd4);
   wire [32:0] w_zz1 = {w_d1, 1'b0} ^ {33{w_d1[31]}};
   wire [2:0]  w_nb1 = (|w_zz1[32:28]) ? 3'd5 : (|w_zz1[27:21]) ? 3'd4 :
                       (|w_zz1[20:14]) ? 3'd3 : (|w_zz1[13:7])  ? 3'd2 : 3'd1;
   wire [39:0] w_leb1 = { {1'b0, 2'b00, w_zz1[32:28]},
                          {(w_nb1>3'd4), w_zz1[27:21]},
                          {(w_nb1>3'd3), w_zz1[20:14]},
                          {(w_nb1>3'd2), w_zz1[13:7]},
                          {(w_nb1>3'd1), w_zz1[6:0]} };
   wire [40:0] w_code1 = ~w_seeded1 ? {9'd0, w_r1_pc} :
                         (w_d1==32'd0) ? 41'd1 :
                         {w_leb1, 1'b0};
   wire [6:0]  w_len1  = ~w_seeded1 ? 7'd32 :
                         (w_d1==32'd0) ? 7'd1 :
                         (7'd1 + {1'b0,w_nb1,3'd0});

   // ---- combine the two retirees into one append (code0 low, code1 above) ----
   wire [40:0] w_ec0  = w_r0_user ? w_code0 : 41'd0;
   wire [6:0]  w_el0  = w_r0_user ? w_len0  : 7'd0;
   wire [40:0] w_ec1  = w_r1_user ? w_code1 : 41'd0;
   wire [6:0]  w_el1  = w_r1_user ? w_len1  : 7'd0;
   wire [95:0] w_append = ({55'd0, w_ec1} << w_el0) | {55'd0, w_ec0};
   wire [7:0]  w_applen = {1'b0, w_el0} + {1'b0, w_el1};          // <= 82

   always_comb
     begin
        n_last_pc = r_last_pc;
        n_seeded  = r_seeded;
        if(w_r0_user)
          begin
             n_last_pc = w_r0_pc;
             n_seeded  = 1'b1;
          end
        if(w_r1_user)
          begin
             n_last_pc = w_r1_pc;
             n_seeded  = 1'b1;
          end
     end // always_comb

   // ================= bit accumulator -> 128-bit beats =================
   logic [255:0] r_acc, n_acc;
   logic [8:0]   r_nbits, n_nbits;
   logic         t_beat_we;
   logic [127:0] t_beat;

   always_comb
     begin
        // append new bits at position r_nbits (r_nbits < 128 after any flush)
        logic [255:0] merged;
        logic [8:0]   total;
        merged    = r_acc | ({160'd0, w_append} << r_nbits);
        total     = r_nbits + {1'b0, w_applen};
        t_beat_we = (total >= 9'd128);
        t_beat    = merged[127:0];
        if(t_beat_we)
          begin
             n_acc   = merged >> 128;         // keep the high (unflushed) bits
             n_nbits = total - 9'd128;
          end
        else
          begin
             n_acc   = merged;
             n_nbits = total;
          end
     end // always_comb

   // ================= beat FIFO (128-bit) =================
   logic [127:0]        r_fifo [FIFO_N-1:0];
   logic [FIFO_LG:0]    r_wr, n_wr;
   logic [FIFO_LG:0]    r_rd, n_rd;
   wire [FIFO_LG:0]     w_cnt   = r_wr - r_rd;
   wire                 w_full  = (w_cnt == FIFO_N[FIFO_LG:0]);
   wire                 w_empty = (w_cnt == 0);
   logic                r_ovf, n_ovf;

   wire w_push = t_beat_we & ~w_full;
   wire w_drop = t_beat_we &  w_full;

   // ================= drain: one outstanding store to the ring =================
   logic                r_req, n_req;
   logic [`PA_WIDTH-1:0] r_woff, n_woff;
   logic [31:0]         r_bytes, n_bytes;

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
                  n_req = 1'b1;
               end
          end
        else if(trace_rsp_valid)
          begin
             n_req   = 1'b0;
             n_rd    = r_rd + 1'b1;
             n_woff  = (r_woff + `PA_WIDTH'd16) & ring_mask;
             n_bytes = r_bytes + 32'd16;
          end
     end // always_comb

   always_ff @(posedge clk)
     begin
        if(reset | ~arm)
          begin
             r_last_pc <= 32'd0;
             r_seeded  <= 1'b0;
             r_acc     <= 256'd0;
             r_nbits   <= 9'd0;
             r_wr      <= '0;
             r_rd      <= '0;
             r_ovf     <= 1'b0;
             r_req     <= 1'b0;
             r_woff    <= '0;
             r_bytes   <= 32'd0;
          end
        else
          begin
             r_last_pc <= n_last_pc;
             r_seeded  <= n_seeded;
             r_acc     <= n_acc;
             r_nbits   <= n_nbits;
             r_wr      <= n_wr;
             r_rd      <= n_rd;
             r_ovf     <= n_ovf;
             r_req     <= n_req;
             r_woff    <= n_woff;
             r_bytes   <= n_bytes;
             if(w_push)
               begin
                  r_fifo[r_wr[FIFO_LG-1:0]] <= t_beat;
               end
          end
     end // always_ff

   assign trace_req_valid      = r_req;
   assign trace_req_addr       = (ring_base + r_woff);
   assign trace_req_store_data = r_fifo[r_rd[FIFO_LG-1:0]];
   assign trace_req_opcode     = 5'd7;
   assign trace_req_mask       = 16'hffff;
   assign trace_ring_wptr      = r_bytes;
   assign trace_overflow       = r_ovf;

endmodule // dram_trace
