`include "machine.vh"
// -----------------------------------------------------------------------------
// snoop_fifo.sv -- DMA-coherence snoop queue.
//
// Collects the PHYSICAL LINE ADDRESS of every DRAM write performed by a DMA
// master (SCSI engine, ENET engine) and hands them one at a time to the L2's
// snoop port, which synthesizes a MEM_INVL so the L2 cannot serve a stale copy
// of a line the device just overwrote.
//
// WHY A QUEUE: a DMA engine can retire a line store every few cycles, while the
// L2 accepts one snoop at a time and only when its own pipeline is free.  Without
// buffering the engine would have to stall on the L2, coupling two independent
// machines.  Depth is small because the L2 drains far faster than a DMA streams.
//
// OVERFLOW IS A CORRECTNESS BUG, NOT A PERFORMANCE ONE: a dropped address leaves
// a stale L2 line, which is exactly the silent corruption this exists to prevent.
// So overflow asserts `full` for the producer to stall on, and (sim) shouts.
// Never silently drop.
//
// Producers push a BYTE address; the line address is formed here so callers can
// hand over whatever they have.
// -----------------------------------------------------------------------------
module snoop_fifo
  #(parameter int LG_DEPTH = 4)                    // 16 entries
   (input  logic                     clk,
    input  logic                     reset,
    // ---- producers (one push per accepted DMA line store) ----
    input  logic                     push_valid,
    input  logic [`PA_WIDTH-1:0]     push_addr,
    output logic                     full,         // producer MUST stall on this
    // ---- consumer: the L2 snoop port ----
    output logic                     snoop_req_valid,
    output logic [`PA_WIDTH-1:0]     snoop_req_addr,
    input  logic                     snoop_req_ack);

   localparam int DEPTH = 1 << LG_DEPTH;

   logic [`PA_WIDTH-1:0] r_mem [DEPTH-1:0];
   logic [LG_DEPTH:0]    r_wr_ptr, n_wr_ptr;       // extra bit distinguishes full/empty
   logic [LG_DEPTH:0]    r_rd_ptr, n_rd_ptr;

   wire w_empty = (r_wr_ptr == r_rd_ptr);
   wire w_full  = (r_wr_ptr[LG_DEPTH] != r_rd_ptr[LG_DEPTH]) &&
                  (r_wr_ptr[LG_DEPTH-1:0] == r_rd_ptr[LG_DEPTH-1:0]);
   assign full = w_full;

   /* line-align: the L2 invalidates a whole line, so the low bits are noise */
   wire [`PA_WIDTH-1:0] w_line = {push_addr[`PA_WIDTH-1:`LG_L1D_CL_LEN],
                                  {`LG_L1D_CL_LEN{1'b0}}};

   assign snoop_req_valid = !w_empty;
   assign snoop_req_addr  = r_mem[r_rd_ptr[LG_DEPTH-1:0]];

   always_comb
     begin
	n_wr_ptr = r_wr_ptr;
	n_rd_ptr = r_rd_ptr;
	if(push_valid && !w_full)
	  begin
	     n_wr_ptr = r_wr_ptr + 1'b1;
	  end
	if(!w_empty && snoop_req_ack)
	  begin
	     n_rd_ptr = r_rd_ptr + 1'b1;
	  end
     end // always_comb

   always_ff@(posedge clk)
     begin
	if(reset)
	  begin
	     r_wr_ptr <= 'd0;
	     r_rd_ptr <= 'd0;
	  end
	else
	  begin
	     r_wr_ptr <= n_wr_ptr;
	     r_rd_ptr <= n_rd_ptr;
	     if(push_valid && !w_full)
	       begin
		  r_mem[r_wr_ptr[LG_DEPTH-1:0]] <= w_line;
	       end
	  end
     end // always_ff

`ifdef VERILATOR
   /* POSITIVE CONTROL: a snoop path that silently never fires looks identical to
    * one that works.  Count pushes/pops and print the first few + a periodic
    * tally so "the snoop is live" is observable rather than assumed. */
   integer r_npush = 0, r_npop = 0;
   always_ff@(posedge clk)
     begin
	if(!reset)
	  begin
	     if(push_valid && !w_full)
	       begin
		  r_npush <= r_npush + 1;
		  if(r_npush < 8)
		    begin
		       $display("[snoop] push #%0d line=%x", r_npush, w_line);
		    end
	       end
	     if(!w_empty && snoop_req_ack)
	       begin
		  r_npop <= r_npop + 1;
		  if(r_npop < 8)
		    begin
		       $display("[snoop] L2 invalidated line=%x (pop #%0d)", snoop_req_addr, r_npop);
		    end
	       end
	  end
     end // always_ff

   /* A dropped snoop = a stale L2 line = silent data corruption.  If this ever
    * fires the depth is wrong or a producer is not honouring `full`. */
   always_ff@(posedge clk)
     begin
	if(!reset && push_valid && w_full)
	  begin
	     $display(">>>> SNOOP FIFO OVERFLOW -- dropped invalidate for %x", w_line);
	     $stop();
	  end
     end
`endif

endmodule // snoop_fifo
