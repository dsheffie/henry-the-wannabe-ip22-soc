`include "machine.vh"
// -----------------------------------------------------------------------------
// mem_arbiter.sv -- parameterized weighted round-robin DRAM arbiter.
//
// Multiplexes N one-outstanding memory masters onto a single external DRAM port.
// Arbitration is a slot-based weighted round-robin: there are NSLOT slots, each
// assigned to a master by SLOT_MAP; at each grant we scan slots from the rotating
// pointer for the first slot whose master is requesting (idle masters' slots are
// skipped, so a lone master gets 100%).  A master's weight = how many slots it
// owns, so e.g. N=2, NSLOT=4, SLOT_MAP=4'b1000 gives CPU(0):DMA(1) = 3:1.  Every
// master is therefore guaranteed a turn within NSLOT rounds (deadlock-free), and
// the weighting is fully tunable / extensible to more masters via the parameters.
//
// The external AXI master requires mem_req_valid to DROP between requests, so a
// one-cycle TURN (valid low) follows every response (the henry_tb DRAM model now
// enforces this too).  Masters must hold their request stable until their
// response (the core-bus contract).
// -----------------------------------------------------------------------------
module mem_arbiter
  #(parameter int                       N        = 2,        // number of masters
    parameter int                       NSLOT    = 4,        // round-robin slots (sum of weights)
    parameter int                       LG_N     = 1,        // bits to index a master
    parameter [NSLOT*LG_N-1:0]          SLOT_MAP = 4'b1000)  // slot s owner = SLOT_MAP[s*LG_N +: LG_N]
   (input  logic                        clk,
    input  logic                        reset,
    // packed per-master request channels (master m = bits [m*W +: W])
    input  logic [N-1:0]                m_req_valid,
    input  logic [N*`PA_WIDTH-1:0]      m_req_addr,
    input  logic [N*128-1:0]            m_req_store_data,
    input  logic [N*5-1:0]              m_req_opcode,
    input  logic [N*16-1:0]             m_req_mask,
    output logic [N-1:0]                m_rsp_valid,          // 1-hot to the granted owner
    output logic [127:0]                m_rsp_load_data,      // broadcast; qualify by m_rsp_valid
    output logic                        m_rsp_bad,
    // external DRAM port (one outstanding, fire-and-response, valid drops between reqs)
    output logic                        mem_req_valid,
    output logic [`PA_WIDTH-1:0]        mem_req_addr,
    output logic [127:0]                mem_req_store_data,
    output logic [4:0]                  mem_req_opcode,
    output logic [15:0]                 mem_req_mask,
    input  logic                        mem_rsp_valid,
    input  logic [127:0]                mem_rsp_load_data,
    input  logic                        mem_rsp_bad);

   localparam ARB_IDLE = 2'd0, ARB_BUSY = 2'd1, ARB_TURN = 2'd2;
   localparam int LG_SLOT = (NSLOT <= 1) ? 1 : $clog2(NSLOT);

   logic [1:0]          r_arb_state, n_arb_state;
   logic [LG_N-1:0]     r_owner,     n_owner;     // granted master (latched, valid in BUSY)
   logic [LG_SLOT-1:0]  r_slot,      n_slot;      // round-robin slot pointer

   wire w_any_req = |m_req_valid;

   // Scan slots from r_slot for the first one whose owner master is requesting.
   logic               w_found;
   logic [LG_N-1:0]    w_grant_owner;
   logic [LG_SLOT-1:0] w_grant_next;              // slot pointer AFTER the granted slot
   always_comb begin
      w_found       = 1'b0;
      w_grant_owner = '0;
      w_grant_next  = r_slot;
      for(int k = 0; k < NSLOT; k++) begin
         logic [LG_SLOT:0]   ws;
         logic [LG_SLOT-1:0] s;
         logic [LG_N-1:0]    own;
         ws  = {1'b0, r_slot} + LG_SLOT'(k);
         s   = (ws >= NSLOT) ? (ws - NSLOT) : ws[LG_SLOT-1:0];
         own = SLOT_MAP[s*LG_N +: LG_N];
         if(!w_found && m_req_valid[own]) begin
            w_found       = 1'b1;
            w_grant_owner = own;
            w_grant_next  = (s == LG_SLOT'(NSLOT-1)) ? '0 : (s + 1'b1);
         end
      end
   end

   // owner whose request is on the bus this cycle (granting in IDLE, else latched)
   wire [LG_N-1:0] w_cur_owner = (r_arb_state == ARB_IDLE) ? w_grant_owner : r_owner;

   always_comb begin
      n_arb_state = r_arb_state;
      n_owner     = r_owner;
      n_slot      = r_slot;
      case(r_arb_state)
        ARB_IDLE:
          if(w_any_req && w_found) begin
             n_arb_state = ARB_BUSY;
             n_owner     = w_grant_owner;
             n_slot      = w_grant_next;
          end
        ARB_BUSY: if(mem_rsp_valid) n_arb_state = ARB_TURN;
        ARB_TURN:                   n_arb_state = ARB_IDLE;   // 1 cycle valid-low: AXI sees the drop
        default:                    n_arb_state = ARB_IDLE;
      endcase
   end

   always_ff @(posedge clk) begin
      if(reset) begin
         r_arb_state <= ARB_IDLE;
         r_owner     <= '0;
         r_slot      <= '0;
      end
      else begin
         r_arb_state <= n_arb_state;
         r_owner     <= n_owner;
         r_slot      <= n_slot;
      end
   end

   // request mux -- variable base (the allowed use of +:)
   assign mem_req_valid      = ((r_arb_state == ARB_IDLE) & w_any_req) | (r_arb_state == ARB_BUSY);
   assign mem_req_addr       = m_req_addr      [w_cur_owner*`PA_WIDTH +: `PA_WIDTH];
   assign mem_req_store_data = m_req_store_data[w_cur_owner*128       +: 128];
   assign mem_req_opcode     = m_req_opcode    [w_cur_owner*5         +: 5];
   assign mem_req_mask       = m_req_mask      [w_cur_owner*16        +: 16];

   // response: 1-hot to the latched owner during BUSY
   always_comb begin
      m_rsp_valid = '0;
      if((r_arb_state == ARB_BUSY) & mem_rsp_valid)
        m_rsp_valid[r_owner] = 1'b1;
   end
   assign m_rsp_load_data = mem_rsp_load_data;
   assign m_rsp_bad       = mem_rsp_bad;
endmodule // mem_arbiter
