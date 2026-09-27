`include "machine.vh"
`include "uop.vh"
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
   input  logic [`PA_WIDTH-1:0]     ring_size,   // ring byte size (compare wrap; may be non-2^k)

   input  logic                     retire0_valid,
   input  logic [63:0]              retire0_pc,
   input  logic                     retire1_valid,
   input  logic [63:0]              retire1_pc,

   // ---- load-value capture (loadval_mode) ----
   // When loadval_mode, INSTEAD of the control-flow codec the ring is filled with
   // fixed 8-byte records {pc[31:0], val[31:0]} for every in-filter LOAD retire
   // (val = the retired GPR write = the cache-sourced loaded value; low 32 bits are
   // the n32 pointer/word that carries the `be` poison).  Two 8B records pack one
   // 128-bit beat, so peak push is <=1 beat/cycle (same ceiling as the codec) and
   // the FIFO/drain/ring are reused unchanged.  op selects loads via is_load().
   input  logic [7:0]               retire0_op,
   input  logic                     retire0_reg_valid,
   input  logic [63:0]              retire0_val,
   input  logic [7:0]               retire1_op,
   input  logic                     retire1_reg_valid,
   input  logic [63:0]              retire1_val,
   input  logic [31:0]              retire0_addr,   // effective VA the load READ FROM
   input  logic [31:0]              retire1_addr,
   input  logic                     loadval_mode,

   // Backpressure throttle: when throttle_en, assert trace_stall once the beat FIFO
   // passes a high-water mark so the SoC can pause retirement (retire_allowed) until
   // the drain catches up -> the trace becomes LOSSLESS (no FIFO drop) at the cost of
   // slowing the core during load bursts.  The drain is an independent mem master, so
   // stalling retirement cannot starve it -> no deadlock.
   input  logic                     throttle_en,
   output logic                     trace_stall,

   // PC-range filter: when pc_range_en, record (and thus throttle) ONLY retires whose
   // instruction PC is in be's text range [BE_LO, BE_HI) -> scopes capture + throttle to
   // `be` regardless of ASID, so boot / other processes run free (unfiltered throttle
   // crawls the whole machine).  A load's DATA address is unrestricted (heap/stack ok).
   input  logic                     pc_range_en,

   // ASID filter: when filter_en, record ONLY retires of the process whose
   // EntryHi ASID == target_asid (isolates the crashing `be` so the fixed ring
   // holds be-only history, deep enough to reach the corruption fork).  asid is
   // the current EntryHi ASID; retire0/1 are the same cycle => same process.
   input  logic [7:0]               asid,
   input  logic [7:0]               target_asid,
   input  logic                     filter_en,

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

   wire w_asid_ok = ~filter_en | (asid == target_asid);
`ifdef TRACE_ALL_PC
   wire w_r0_user = retire0_valid & w_asid_ok & w_r0_inrange;
   wire w_r1_user = retire1_valid & w_asid_ok & w_r1_inrange;
`else
   wire w_r0_user = retire0_valid & (retire0_pc[63:31] == 33'd0) & w_asid_ok & w_r0_inrange;
   wire w_r1_user = retire1_valid & (retire1_pc[63:31] == 33'd0) & w_asid_ok & w_r1_inrange;
`endif
   wire [31:0] w_r0_pc = retire0_pc[31:0];
   wire [31:0] w_r1_pc = retire1_pc[31:0];

   // be text range for the PC-range filter (be/be.so/cg.so/libc/rld all live here).
   // Overridable via +define for co-sim validation on non-be workloads (e.g. boot).
`ifndef BE_LO
 `define BE_LO 32'h0e000000
`endif
`ifndef BE_HI
 `define BE_HI 32'h10200000
`endif
   localparam [31:0] BE_LO = `BE_LO;
   localparam [31:0] BE_HI = `BE_HI;
   wire w_r0_inrange = ~pc_range_en | ((retire0_pc[31:0] >= BE_LO) & (retire0_pc[31:0] < BE_HI));
   wire w_r1_inrange = ~pc_range_en | ((retire1_pc[31:0] >= BE_LO) & (retire1_pc[31:0] < BE_HI));

   // ---- load records (loadval_mode): 16B {pc,val,addr} per in-filter LOAD retire ----
   // A retiree qualifies if it is an in-filter userspace retire (w_rN_user) that wrote a
   // GPR (reg_valid) via a load opcode (is_load).  Each load is ONE 128-bit beat
   // {32'd0, addr[31:0], val[31:0], pc[31:0]} -> decoder reads pc, val, addr.  Up to 2
   // loads/cycle -> up to 2 beats, absorbed by the BANKED FIFO below (two 1-write BRAMs,
   // records split even/odd by global sequence -> each bank <=1 write/cycle).
   wire         w_r0_ld = loadval_mode & w_r0_user & retire0_reg_valid & is_load(opcode_t'(retire0_op));
   wire         w_r1_ld = loadval_mode & w_r1_user & retire1_reg_valid & is_load(opcode_t'(retire1_op));
   wire [127:0] w_ldbeat0 = {32'd0, retire0_addr, retire0_val[31:0], w_r0_pc};
   wire [127:0] w_ldbeat1 = {32'd0, retire1_addr, retire1_val[31:0], w_r1_pc};
   wire [1:0]   w_nld   = {1'b0, w_r0_ld} + {1'b0, w_r1_ld};
   wire [127:0] w_ldA   = w_r0_ld ? w_ldbeat0 : w_ldbeat1;   // first load beat (r0 priority)
   wire [127:0] w_ldB   = w_ldbeat1;                          // second (only when both)

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

   // ================= PIPELINE stage 1: register the encoded append =================
   // The encode (subtract/zigzag/LEB priority-encode) and the pack (128-way barrel
   // shift + merge) are the two deep combinational paths; a flop between them opens WNS.
   logic [95:0]  r_p_append;
   logic [7:0]   r_p_applen;
   wire  [95:0]  n_p_append = w_append;
   wire  [7:0]   n_p_applen = w_applen;

   // ================= PIPELINE stage 2: pack registered bits -> 128-bit beats =======
   logic [255:0] r_acc, n_acc;
   logic [8:0]   r_nbits, n_nbits;
   logic [1:0]   t_nbeats;          // beats to push this cycle: 0/1 (codec) or 0/1/2 (loadval)
   logic [127:0] t_beatA, t_beatB;

   always_comb
     begin
        // append new bits at position r_nbits (r_nbits < 128 after any flush)
        logic [255:0] merged;
        logic [8:0]   total;
        // defaults: hold codec state, emit nothing
        n_acc    = r_acc;
        n_nbits  = r_nbits;
        t_nbeats = 2'd0;
        t_beatA  = 128'd0;
        t_beatB  = 128'd0;
        merged   = r_acc | ({160'd0, r_p_append} << r_nbits);
        total    = r_nbits + {1'b0, r_p_applen};
        if(loadval_mode)
          begin
             // ---- load-record packer: 1 beat per load, up to 2 loads/cycle ----
             t_nbeats = w_nld;
             t_beatA  = w_ldA;
             t_beatB  = w_ldB;
          end
        else
          begin
             // ---- control-flow codec packer (1 beat/cycle max) ----
             if(total >= 9'd128)
               begin
                  t_nbeats = 2'd1;
                  t_beatA  = merged[127:0];
                  n_acc    = merged >> 128;            // keep the high (unflushed) bits
                  n_nbits  = total - 9'd128;
               end
             else
               begin
                  n_acc   = merged;
                  n_nbits = total;
               end
          end // else: !loadval_mode
     end // always_comb

   // ================= beat FIFO: 2 banks, each simple-dual-port (1W1R) =================
   // A global record sequence (r_wr/r_rd) is split EVEN/ODD across two banks: record A
   // takes seq r_wr, record B takes seq r_wr+1 -- they differ in bit0 -> ALWAYS land in
   // different banks, so 2 writes/cycle (dual load) become <=1 write PER BANK.  Each bank
   // is thus 1-write-1-read (no true-dual-port).  bank = seq[0], slot = seq[FIFO_LG-1:1].
   // Drain reads seq 0,1,2,... = bank0[0],bank1[0],bank0[1],... -> program order preserved.
   localparam int BANK_LG = FIFO_LG - 1;
   localparam int BANK_N  = (1 << BANK_LG);
   logic [127:0]        r_fifo0 [BANK_N-1:0];
   logic [127:0]        r_fifo1 [BANK_N-1:0];
   logic [FIFO_LG:0]    r_wr, n_wr;
   logic [FIFO_LG:0]    r_rd, n_rd;
   wire [FIFO_LG:0]     w_cnt   = r_wr - r_rd;
   wire                 w_empty = (w_cnt == 0);

   // high-water throttle: assert trace_stall with margin for in-flight records
   // (retire_valid is registered + a 2-stage encode pipeline -> a few beats can
   // still land after the stall asserts).  FIFO_N-16 leaves generous slack.
   localparam int HIGH_WATER = FIFO_N - 16;
   // DEADLOCK GUARD (drain-stuck detection): retirement-stall shares the AXI with the
   // trace drain, so if the drain wedges (stall -> CPU mem backs up -> AXI blocked ->
   // drain starved -> FIFO never drains -> stall forever; observed on silicon, took the
   // board down) the core deadlocks.  Detect it precisely: a trace store outstanding
   // (r_req) for > MAX_REQ_WAIT cycles WITHOUT a response means the AXI is wedged -> then
   // force-release retirement so the CPU/AXI makes progress and the drain can complete.
   // Keyed on the drain (not stall duration) so a slow-but-progressing drain never trips
   // it -> no false drops in normal operation.
   localparam int MAX_REQ_WAIT = 2048;
   logic [11:0]         r_req_wait;
   wire                 w_drain_stuck = (r_req_wait >= MAX_REQ_WAIT[11:0]);
   assign trace_stall = throttle_en & (w_cnt >= HIGH_WATER[FIFO_LG:0]) & ~w_drain_stuck;
   // saturate: once stuck, STAY stuck (a wrapping counter would oscillate the release)
   wire [11:0]          n_req_wait = (r_req & ~trace_rsp_valid) ?
                                     (w_drain_stuck ? r_req_wait : (r_req_wait + 1'b1)) : 12'd0;
   logic                r_ovf, n_ovf;

   // up to 2 records/cycle; push only what fits (throttle keeps room, so no drop).
   wire [FIFO_LG:0]   w_room  = FIFO_N[FIFO_LG:0] - w_cnt;
   wire               w_wA    = (t_nbeats >= 2'd1) & (w_room >= 7'd1);
   wire               w_wB    = (t_nbeats == 2'd2) & (w_room >= 7'd2);
   wire               w_drop  = ((t_nbeats >= 2'd1) & (w_room <  7'd1)) |
                                ((t_nbeats == 2'd2) & (w_room <  7'd2));
   wire [FIFO_LG:0]   w_seqA  = r_wr;
   wire [FIFO_LG:0]   w_seqB  = r_wr + 1'b1;
   wire [BANK_LG-1:0] w_slotA = w_seqA[FIFO_LG-1:1];
   wire [BANK_LG-1:0] w_slotB = w_seqB[FIFO_LG-1:1];
   // exactly one of A/B is even-seq (bank0), the other odd (bank1) -> 1 write per bank
   wire               w_b0_we   = (w_wA & ~w_seqA[0]) | (w_wB & ~w_seqB[0]);
   wire [BANK_LG-1:0] w_b0_addr = (w_wA & ~w_seqA[0]) ? w_slotA : w_slotB;
   wire [127:0]       w_b0_data = (w_wA & ~w_seqA[0]) ? t_beatA : t_beatB;
   wire               w_b1_we   = (w_wA &  w_seqA[0]) | (w_wB &  w_seqB[0]);
   wire [BANK_LG-1:0] w_b1_addr = (w_wA &  w_seqA[0]) ? w_slotA : w_slotB;
   wire [127:0]       w_b1_data = (w_wA &  w_seqA[0]) ? t_beatA : t_beatB;
   wire [BANK_LG-1:0] w_rd_slot = r_rd[FIFO_LG-1:1];
   wire [127:0]       w_rd_data = r_rd[0] ? r_fifo1[w_rd_slot] : r_fifo0[w_rd_slot];

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
        n_wr = r_wr + {1'b0, w_wA} + {1'b0, w_wB};
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
             n_woff  = ((r_woff + `PA_WIDTH'd16) >= ring_size) ? `PA_WIDTH'd0 : (r_woff + `PA_WIDTH'd16);
             n_bytes = r_bytes + 32'd16;
          end
     end // always_comb

   always_ff @(posedge clk)
     begin
        if(reset | ~arm)
          begin
             r_last_pc <= 32'd0;
             r_seeded  <= 1'b0;
             r_p_append<= 96'd0;
             r_p_applen<= 8'd0;
             r_acc     <= 256'd0;
             r_nbits   <= 9'd0;
             r_wr      <= '0;
             r_rd      <= '0;
             r_req_wait <= 12'd0;
             r_ovf     <= 1'b0;
             r_req     <= 1'b0;
             r_woff    <= '0;
             r_bytes   <= 32'd0;
          end
        else
          begin
             r_last_pc <= n_last_pc;
             r_seeded  <= n_seeded;
             r_p_append<= n_p_append;
             r_p_applen<= n_p_applen;
             r_acc     <= n_acc;
             r_nbits   <= n_nbits;
             r_wr      <= n_wr;
             r_rd      <= n_rd;
             r_req_wait <= n_req_wait;
             r_ovf     <= n_ovf;
             r_req     <= n_req;
             r_woff    <= n_woff;
             r_bytes   <= n_bytes;
             if(w_b0_we)
               begin
                  r_fifo0[w_b0_addr] <= w_b0_data;
               end
             if(w_b1_we)
               begin
                  r_fifo1[w_b1_addr] <= w_b1_data;
               end
          end
     end // always_ff

   assign trace_req_valid      = r_req;
   assign trace_req_addr       = (ring_base + r_woff);
   assign trace_req_store_data = w_rd_data;
   assign trace_req_opcode     = 5'd7;
   assign trace_req_mask       = 16'hffff;
   assign trace_ring_wptr      = r_bytes;
   assign trace_overflow       = r_ovf;

endmodule // dram_trace
