`include "machine.vh"
// -----------------------------------------------------------------------------
// enet_dma.sv -- HPC3 ENET RX/TX DMA channels: walk the descriptor ring/chain in
// DRAM through the henry arbiter (a REAL ordered DRAM master) and move frame
// bytes between memory and the host-side tap.
//
// Counterpart to scsi_dma.sv, and for the same reason: previously ENET was
// "host-served" -- henry_tb / the ARM PS wrote the guest's RX buffers DIRECTLY
// via a memory callback, completely bypassing the RTL.  That makes the frame
// data invisible to the L2, so the L2 can serve a stale line for a buffer the
// NIC just filled, and NOTHING in software can fix it (Config.SC hides the L2
// from IRIX, so the kernel issues zero secondary-cache ops).  Routing the writes
// through the arbiter makes ENET coherent BY CONSTRUCTION -- the same ordered
// port the CPU uses -- and lets the snoop FIFO see every line.
//
// SPLIT OF WORK (same as the disk): the MEDIA stays in the host.  The host owns
// the tap, decides which frames arrive, and supplies/consumes frame bytes as
// 16-byte beats.  Only the MEMORY MOVEMENT is RTL.
//
// Descriptor (12 bytes, BIG-ENDIAN, one per 16-byte line at NBDP):
//   +0  BP  buffer pointer (physical)
//   +4  BC  COUNT[13:0] | ROWN(14) | ETXD(15) | XIE(29) | EOX(31)
//   +8  DP  next descriptor
//
// RX: a descriptor is usable only if ROWN=1 (HPC owns it).  The host presents the
// frame ALREADY FORMATTED as the driver expects -- [2 pad][frame][1 status] --
// so the engine just streams `rx_len` bytes to BP and does the beat/mask
// arithmetic.  On completion BC is written back with ROWN CLEARED and COUNT set
// to the residual, which is the handshake that gives the buffer to the CPU.
// TX: gather COUNT bytes from each BP, set ETXD in BC, stop at EOX.
//
// Phase-1 scope (matches scsi_dma): 16-byte-aligned NBDP and BP.  A non-multiple
// -of-16 length is handled by masking the final partial beat.
// -----------------------------------------------------------------------------
module enet_dma
   (input  logic         clk,
    input  logic         reset,
    // ---- RX control ----
    input  logic         rx_go,          // 1-cycle pulse: deposit one frame
    input  logic [31:0]  rx_nbdp,        // ring position to try
    input  logic [13:0]  rx_len,         // bytes to write (= 2 + frame + 1, host-formatted)
    output logic         rx_busy,
    output logic         rx_done,        // 1-cycle: frame delivered, descriptor released
    output logic         rx_dropped,     // 1-cycle: ring full (ROWN=0) or buffer too small
    output logic [31:0]  rx_crbdp,       // descriptor just filled (guest reads @HPC3 0x18000)
    output logic [31:0]  rx_next_nbdp,   // ring position after this frame
    // ---- TX control ----
    input  logic         tx_go,          // 1-cycle pulse: transmit the chain at tx_nbdp
    input  logic [31:0]  tx_nbdp,
    output logic         tx_busy,
    output logic         tx_done,        // 1-cycle when the chain completes
    output logic         irq,            // 1-cycle if the finishing descriptor had XIE
    // ---- DMA master -> henry DRAM arbiter ----
    output logic                  dma_req_valid,
    output logic [`PA_WIDTH-1:0]  dma_req_addr,
    output logic [4:0]            dma_req_opcode,     // 4 = line load, 7 = line store
    output logic [127:0]          dma_req_store_data,
    output logic [15:0]           dma_req_mask,
    input  logic                  dma_rsp_valid,
    input  logic [127:0]          dma_rsp_load_data,
    // ---- host side: 16-byte beat stream (the tap is the media) ----
    output logic         rx_rd_en,       // RX: pulse, consume rx_rd_data this cycle
    input  logic [127:0] rx_rd_data,     // RX: host -> mem beat
    input  logic         rx_rd_valid,    // RX: a beat is available; else stall
    output logic         tx_wr_en,       // TX: pulse, tx_wr_data valid this cycle
    output logic [127:0] tx_wr_data);    // TX: mem -> host beat

   typedef enum logic [3:0] {
      S_IDLE     = 4'd0,
      S_RX_DESC  = 4'd1,   // read the RX descriptor @ r_nbdp, check ROWN
      S_RX_BEAT  = 4'd2,   // pull a host beat
      S_RX_MEM   = 4'd3,   // store the beat to mem[bp]
      S_RX_WB    = 4'd4,   // write BC back: clear ROWN, set residual
      S_TX_DESC  = 4'd5,   // read the TX descriptor @ r_nbdp
      S_TX_MEM   = 4'd6,   // load mem[bp]
      S_TX_HOST  = 4'd7,   // push the beat to the host
      S_TX_WB    = 4'd8,   // write BC back: set ETXD
      S_NEXT     = 4'd9,   // advance to dp or finish
      S_DONE     = 4'd10,
      S_DROP     = 4'd11   // RX: ring full / buffer unusable
   } state_t;

   state_t        r_state, n_state;
   logic [31:0]   r_nbdp,  n_nbdp;      // current descriptor address
   logic [31:0]   r_bp,    n_bp;        // current buffer cursor
   logic [13:0]   r_cnt,   n_cnt;       // bytes remaining in this descriptor
   logic [31:0]   r_dp,    n_dp;        // next descriptor
   logic [31:0]   r_bc,    n_bc;        // the descriptor's BC word (for read-modify-write)
   logic [13:0]   r_bufsz, n_bufsz;     // RX: the descriptor's buffer size
   logic          r_eox,   n_eox;
   logic          r_xie,   n_xie;
   logic [127:0]  r_data,  n_data;
   logic          r_done,  n_done;
   logic          r_txdone,n_txdone;
   logic          r_drop,  n_drop;
   logic          r_irq,   n_irq;
   logic [31:0]   r_crbdp, n_crbdp;
   logic [7:0]    r_desc_cnt, n_desc_cnt;   // runaway-chain guard

   // descriptor fields: BE in DRAM, byte-swap each 32-bit lane of the line
   wire [31:0] w_bp = bswap32(dma_rsp_load_data[31:0]);
   wire [31:0] w_bc = bswap32(dma_rsp_load_data[63:32]);
   wire [31:0] w_dp = bswap32(dma_rsp_load_data[95:64]);

   localparam logic [31:0] BC_COUNT = 32'h00003fff;
   localparam logic [31:0] BC_ROWN  = 32'h00004000;
   localparam logic [31:0] BC_ETXD  = 32'h00008000;

   /* BC lives at descriptor bytes 4..7, i.e. lane 1 of the 16-byte line.
    * Write it back with a byte mask so the neighbouring BP/DP words are untouched
    * -- a full-line store would race the CPU writing the ring. */
   localparam logic [15:0] BC_MASK = 16'h00f0;

   /* RX release: clear ROWN (hand the buffer to the CPU), set COUNT = residual,
    * preserve every other flag bit. TX: just set ETXD. */
   wire [31:0] w_bc_rx_wb = (r_bc & ~BC_ROWN & ~BC_COUNT) |
                            ({18'd0, (r_bufsz - r_cnt)} & BC_COUNT);
   wire [31:0] w_bc_tx_wb = r_bc | BC_ETXD;
   wire [31:0] w_bc_wb    = (r_state == S_TX_WB) ? w_bc_tx_wb : w_bc_rx_wb;

   always_comb
     begin
	n_state    = r_state;
	n_nbdp     = r_nbdp;
	n_bp       = r_bp;
	n_cnt      = r_cnt;
	n_dp       = r_dp;
	n_bc       = r_bc;
	n_bufsz    = r_bufsz;
	n_eox      = r_eox;
	n_xie      = r_xie;
	n_data     = r_data;
	n_crbdp    = r_crbdp;
	n_desc_cnt = r_desc_cnt;
	n_done     = 1'b0;
	n_txdone   = 1'b0;
	n_drop     = 1'b0;
	n_irq      = 1'b0;

	dma_req_valid      = 1'b0;
	dma_req_addr       = {{(`PA_WIDTH-32){1'b0}}, r_nbdp};
	dma_req_opcode     = 5'd4;
	dma_req_store_data = r_data;
	dma_req_mask       = 16'hffff;
	rx_rd_en           = 1'b0;
	tx_wr_en           = 1'b0;
	tx_wr_data         = r_data;

	case(r_state)
	  S_IDLE:
	    begin
	       if(rx_go)
		 begin
		    n_nbdp     = rx_nbdp;
		    n_cnt      = rx_len;
		    n_desc_cnt = 8'd0;
		    n_state    = S_RX_DESC;
		 end
	       else if(tx_go)
		 begin
		    n_nbdp     = tx_nbdp;
		    n_desc_cnt = 8'd0;
		    n_state    = S_TX_DESC;
		 end
	    end
	  S_RX_DESC:
	    begin                                   // read descriptor, check ownership
	       dma_req_valid  = 1'b1;
	       dma_req_addr   = {{(`PA_WIDTH-32){1'b0}}, r_nbdp};
	       dma_req_opcode = 5'd4;
	       if(dma_rsp_valid)
		 begin
		    n_bp    = w_bp;
		    n_bc    = w_bc;
		    n_dp    = w_dp;
		    n_bufsz = w_bc[13:0];
		    n_xie   = w_bc[29];
		    n_crbdp = r_nbdp;
		    /* ROWN=0 -> the CPU still owns this buffer: the ring is full and
		     * the frame is dropped, exactly as real hardware does.  A buffer
		     * smaller than [2 pad][>=0 frame][1 status] is unusable and is
		     * treated the same (a torn/stale descriptor reads as COUNT=0). */
		    if(!w_bc[14] || (w_bc[13:0] < 14'd3))
		      begin
			 n_state = S_DROP;
		      end
		    else
		      begin
			 /* clamp an oversized frame to the buffer */
			 if(r_cnt > w_bc[13:0])
			   begin
			      n_cnt = w_bc[13:0];
			   end
			 n_state = S_RX_BEAT;
		      end
		 end
	    end
	  S_RX_BEAT:
	    begin                                   // pull a host beat (stall if none)
	       if(rx_rd_valid)
		 begin
		    rx_rd_en = 1'b1;
		    n_data   = rx_rd_data;
		    n_state  = S_RX_MEM;
		 end
	    end
	  S_RX_MEM:
	    begin                                   // store the beat to mem[bp]
	       dma_req_valid      = 1'b1;
	       dma_req_addr       = {{(`PA_WIDTH-32){1'b0}}, r_bp};
	       dma_req_opcode     = 5'd7;
	       dma_req_store_data = r_data;
	       /* final partial beat: mask so we never write past the frame */
	       dma_req_mask       = (r_cnt >= 14'd16) ? 16'hffff
			                              : ((16'd1 << r_cnt[3:0]) - 16'd1);
	       if(dma_rsp_valid)
		 begin
		    n_bp    = r_bp + 32'd16;
		    n_cnt   = (r_cnt > 14'd16) ? (r_cnt - 14'd16) : 14'd0;
		    n_state = (r_cnt <= 14'd16) ? S_RX_WB : S_RX_BEAT;
		 end
	    end
	  S_RX_WB:
	    begin                                   // release the buffer to the CPU
	       dma_req_valid      = 1'b1;
	       dma_req_addr       = {{(`PA_WIDTH-32){1'b0}}, r_nbdp};
	       dma_req_opcode     = 5'd7;
	       dma_req_store_data = {32'd0, bswap32(w_bc_wb), 64'd0};
	       dma_req_mask       = BC_MASK;
	       if(dma_rsp_valid)
		 begin
		    n_nbdp  = r_dp;                // ring: always advance
		    n_done  = 1'b1;                // pulse HERE: in S_DONE, r_state==S_DONE
		    n_irq   = r_xie;               // so a "which state did we come from"
		    n_state = S_IDLE;              // test there is always false
		 end
	    end
	  S_TX_DESC:
	    begin
	       dma_req_valid  = 1'b1;
	       dma_req_addr   = {{(`PA_WIDTH-32){1'b0}}, r_nbdp};
	       dma_req_opcode = 5'd4;
	       if(dma_rsp_valid)
		 begin
		    n_bp    = w_bp;
		    n_bc    = w_bc;
		    n_cnt   = w_bc[13:0];
		    n_dp    = w_dp;
		    n_eox   = w_bc[31];
		    n_xie   = w_bc[29];
		    n_state = (w_bc[13:0] == 14'd0) ? S_TX_WB : S_TX_MEM;
		 end
	    end
	  S_TX_MEM:
	    begin                                   // load mem[bp]
	       dma_req_valid  = 1'b1;
	       dma_req_addr   = {{(`PA_WIDTH-32){1'b0}}, r_bp};
	       dma_req_opcode = 5'd4;
	       if(dma_rsp_valid)
		 begin
		    n_data  = dma_rsp_load_data;
		    n_state = S_TX_HOST;
		 end
	    end
	  S_TX_HOST:
	    begin                                   // push the beat to the host
	       tx_wr_en = 1'b1;
	       n_bp     = r_bp + 32'd16;
	       n_cnt    = (r_cnt > 14'd16) ? (r_cnt - 14'd16) : 14'd0;
	       n_state  = (r_cnt <= 14'd16) ? S_TX_WB : S_TX_MEM;
	    end
	  S_TX_WB:
	    begin                                   // mark the buffer transmitted
	       dma_req_valid      = 1'b1;
	       dma_req_addr       = {{(`PA_WIDTH-32){1'b0}}, r_nbdp};
	       dma_req_opcode     = 5'd7;
	       dma_req_store_data = {32'd0, bswap32(w_bc_wb), 64'd0};
	       dma_req_mask       = BC_MASK;
	       if(dma_rsp_valid)
		 begin
		    n_state = S_NEXT;
		 end
	    end
	  S_NEXT:
	    /* EOX, a null link (stale/garbage descriptor), or a runaway chain -> stop */
	    if(r_eox | (r_dp == 32'd0) | (r_desc_cnt == 8'hff))
	      begin
		 n_txdone = 1'b1;
		 n_irq    = r_xie;
		 n_state  = S_IDLE;
	      end
	    else
	      begin
		 n_nbdp     = r_dp;
		 n_desc_cnt = r_desc_cnt + 8'd1;
		 n_state    = S_TX_DESC;
	      end
	  S_DONE:                                   // unreachable: RX/TX pulse on exit
	    begin
	       n_state = S_IDLE;
	    end
	  S_DROP:
	    begin
	       n_drop  = 1'b1;
	       n_state = S_IDLE;
	    end
	  default: n_state = S_IDLE;
	endcase // case (r_state)
     end // always_comb

   always_ff@(posedge clk)
     begin
	if(reset)
	  begin
	     r_state    <= S_IDLE;
	     r_nbdp     <= 32'd0;
	     r_bp       <= 32'd0;
	     r_cnt      <= 14'd0;
	     r_dp       <= 32'd0;
	     r_bc       <= 32'd0;
	     r_bufsz    <= 14'd0;
	     r_eox      <= 1'b0;
	     r_xie      <= 1'b0;
	     r_data     <= 128'd0;
	     r_done     <= 1'b0;
	     r_txdone   <= 1'b0;
	     r_drop     <= 1'b0;
	     r_irq      <= 1'b0;
	     r_crbdp    <= 32'd0;
	     r_desc_cnt <= 8'd0;
	  end
	else
	  begin
	     r_state    <= n_state;
	     r_nbdp     <= n_nbdp;
	     r_bp       <= n_bp;
	     r_cnt      <= n_cnt;
	     r_dp       <= n_dp;
	     r_bc       <= n_bc;
	     r_bufsz    <= n_bufsz;
	     r_eox      <= n_eox;
	     r_xie      <= n_xie;
	     r_data     <= n_data;
	     r_done     <= n_done;
	     r_txdone   <= n_txdone;
	     r_drop     <= n_drop;
	     r_irq      <= n_irq;
	     r_crbdp    <= n_crbdp;
	     r_desc_cnt <= n_desc_cnt;
	  end
     end // always_ff

   assign rx_busy      = (r_state == S_RX_DESC) | (r_state == S_RX_BEAT) |
			 (r_state == S_RX_MEM)  | (r_state == S_RX_WB);
   assign tx_busy      = (r_state == S_TX_DESC) | (r_state == S_TX_MEM) |
			 (r_state == S_TX_HOST) | (r_state == S_TX_WB) |
			 (r_state == S_NEXT);
   assign rx_done      = r_done;
   assign tx_done      = r_txdone;
   assign rx_dropped   = r_drop;
   assign irq          = r_irq;
   assign rx_crbdp     = r_crbdp;
   assign rx_next_nbdp = r_nbdp;

endmodule // enet_dma
