// -----------------------------------------------------------------------------
// scsi_beat_fifo.sv -- 128-bit beat FIFO between the ARM (AXI slave-reg pushes)
// and the scsi_dma engine's disk-read port.
//
// The "radically different DMA controller": the ARM never touches MIPS memory.
// It trickles disk bytes across the ordered S00 slave-reg leg into this FIFO,
// 16 bytes (one beat) at a time; the scsi_dma engine (the only agent that
// touches MIPS memory) drains the FIFO and writes mem[BP] via M00.  Because the
// AXI-Lite fill rate is far below the engine's drain rate, the engine stalls
// (disk_rd_valid low) whenever the FIFO is empty -- the "very slowly" path.
//
// Style mirrors the ioc.sv SCC Rx FIFO (count-based, explicit widths).
// -----------------------------------------------------------------------------
`include "machine.vh"

module scsi_beat_fifo
   (input  logic         clk,
    input  logic         reset,
    // ---- producer side: ARM push (via S00 slave regs / TB) ----
    input  logic         push,        // 1-cycle enqueue pulse (ignored if full)
    input  logic [127:0] wdata,        // the 16-byte beat to enqueue
    output logic         full,         // flow control: ARM must not push when set
    // ---- consumer side: scsi_dma engine disk-read port ----
    input  logic         pop,          // 1-cycle dequeue pulse (engine disk_rd_en)
    output logic [127:0] rdata,        // front beat (valid when ~empty)
    output logic         empty);

   localparam int N = 16;              // depth (beats)

   logic [127:0] r_fifo [0:N-1];
   logic [3:0]   r_wptr, r_rptr;
   logic [4:0]   r_count;

   wire w_push = push & ~full;
   wire w_pop  = pop  & ~empty;

   assign empty = (r_count == 5'd0);
   assign full  = (r_count == 5'(N));
   assign rdata = r_fifo[r_rptr];

   always_ff @(posedge clk) begin
      if(reset) begin
         r_wptr  <= 4'd0;
         r_rptr  <= 4'd0;
         r_count <= 5'd0;
      end
      else begin
         if(w_push) begin
            r_fifo[r_wptr] <= wdata;
            r_wptr         <= r_wptr + 4'd1;
         end
         if(w_pop)
            r_rptr <= r_rptr + 4'd1;
         case({w_push, w_pop})
           2'b10:   r_count <= r_count + 5'd1;
           2'b01:   r_count <= r_count - 5'd1;
           default: r_count <= r_count;
         endcase
      end
   end
endmodule // scsi_beat_fifo
