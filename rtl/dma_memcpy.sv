`include "machine.vh"
// -----------------------------------------------------------------------------
// dma_memcpy.sv -- software-driven, polled mem-to-mem DMA copy engine.
//
// Bring-up datapath exercised through the HPC3 register window: copy LEN bytes
// SRC->DST in 16-byte lines via the henry DRAM arbiter (a second DRAM master).
// This is NOT the real HPC3 SCSI channel -- it has no {BP,BC,DP} descriptor
// walk and is not what IRIX programs.  It validates the arbiter + the AXI
// valid-drop turnaround end-to-end; the host-served (ARM/DPI) disk path does
// not use it (see hpc3.sv `ENABLE_HPC3_DMA gate).
//
// Regs (HPC3 offsets, 32-bit; the BE bus delivers words byte-swapped):
//   0x10000 SRC   source phys addr (16-byte aligned)
//   0x10004 DST   dest   phys addr (16-byte aligned)
//   0x10008 LEN   byte count (16-byte multiple)
//   0x1000c CTRL  write bit0 = GO (start); read bit0 = BUSY, bit1 = DONE
// SRC/DST/LEN/CTRL share the one 16-byte line @0x10000 (lanes 0..3), so a single
// store programs all four and kicks off the copy.
// -----------------------------------------------------------------------------
module dma_memcpy
   (input  logic         clk,
    input  logic         reset,
    // HPC3 register-window strobes (engine self-decodes its 0x10000 subwindow)
    input  logic         sel,
    input  logic         is_store,
    input  logic [18:0]  offs,        // byte offset within HPC3 (addr & 0x7ffff)
    input  logic [15:0]  mask,
    input  logic [127:0] wdata,
    output logic [31:0]  status,       // CTRL read value (bit1=DONE bit0=BUSY in byte[31:24])
    // ---- DMA master -> henry_soc DRAM arbiter ----
    output logic                  dma_req_valid,
    output logic [`PA_WIDTH-1:0]  dma_req_addr,
    output logic [4:0]            dma_req_opcode,     // 4 = line load, 7 = line store
    output logic [127:0]          dma_req_store_data,
    output logic [15:0]           dma_req_mask,
    input  logic                  dma_rsp_valid,
    input  logic [127:0]          dma_rsp_load_data);

   localparam DMA_IDLE = 2'd0, DMA_RD = 2'd1, DMA_WR = 2'd2, DMA_DONE = 2'd3;
   logic [1:0]   r_dma_state,   n_dma_state;
   logic [31:0]  r_dma_src,     n_dma_src;       // working source cursor
   logic [31:0]  r_dma_dst,     n_dma_dst;       // working dest cursor
   logic [31:0]  r_dma_len,     n_dma_len;       // bytes remaining
   logic [31:0]  r_dma_src_reg, n_dma_src_reg;   // programmed SRC
   logic [31:0]  r_dma_dst_reg, n_dma_dst_reg;   // programmed DST
   logic [31:0]  r_dma_len_reg, n_dma_len_reg;   // programmed LEN
   logic [127:0] r_dma_data,    n_dma_data;      // line latched between RD and WR
   logic         r_dma_done,    n_dma_done;      // sticky completion flag

   // A GO write (CTRL bit0) latches SRC/DST/LEN into the working cursors and walks
   // SRC->DST in 16-byte lines via the DRAM arbiter: RD (line load @SRC) -> WR
   // (line store @DST) -> advance, until LEN==0.  The master holds dma_req_valid
   // through RD then WR; the arbiter's turnaround drops mem_req_valid between them,
   // and CPU-priority lets the CPU interleave.
   wire w_dma_busy  = (r_dma_state == DMA_RD) | (r_dma_state == DMA_WR);
   // GO = bit0 of the guest's CTRL word (lane 3 @0x1000c).  The BE bus puts the
   // guest LSB in byte 15 of the line, so CTRL[0] = wdata[120].
   wire w_dma_wr_go = sel & is_store & (offs == 19'h10000) &
                      (mask[15:12] == 4'hf) & wdata[120];

   always_comb begin
      n_dma_state   = r_dma_state;
      n_dma_src     = r_dma_src;
      n_dma_dst     = r_dma_dst;
      n_dma_len     = r_dma_len;
      n_dma_src_reg = r_dma_src_reg;
      n_dma_dst_reg = r_dma_dst_reg;
      n_dma_len_reg = r_dma_len_reg;
      n_dma_data    = r_dma_data;
      n_dma_done    = r_dma_done;

      // programming: SRC/DST/LEN at lanes 0/1/2 of the 0x10000 line (BE-swapped)
      if(sel & is_store & (offs == 19'h10000)) begin
         if(mask[3:0]  == 4'hf) n_dma_src_reg = bswap32(wdata[31:0]);
         if(mask[7:4]  == 4'hf) n_dma_dst_reg = bswap32(wdata[63:32]);
         if(mask[11:8] == 4'hf) n_dma_len_reg = bswap32(wdata[95:64]);
      end

      case(r_dma_state)
        DMA_IDLE:
          // start on a GO write (use n_*_reg so a combined SRC/DST/LEN/CTRL store works)
          if(w_dma_wr_go && (n_dma_len_reg != 32'd0)) begin
             n_dma_src   = n_dma_src_reg;
             n_dma_dst   = n_dma_dst_reg;
             n_dma_len   = n_dma_len_reg;
             n_dma_done  = 1'b0;
             n_dma_state = DMA_RD;
          end
        DMA_RD:
          if(dma_rsp_valid) begin
             n_dma_data  = dma_rsp_load_data;
             n_dma_state = DMA_WR;
          end
        DMA_WR:
          if(dma_rsp_valid) begin
             n_dma_src   = r_dma_src + 32'd16;
             n_dma_dst   = r_dma_dst + 32'd16;
             n_dma_len   = r_dma_len - 32'd16;
             n_dma_state = (r_dma_len == 32'd16) ? DMA_DONE : DMA_RD;
          end
        DMA_DONE: begin
           n_dma_done  = 1'b1;        // sticky until the next GO clears it
           n_dma_state = DMA_IDLE;
        end
        default: n_dma_state = DMA_IDLE;
      endcase
   end

   always_ff @(posedge clk) begin
      if(reset) begin
         r_dma_state   <= DMA_IDLE;
         r_dma_src     <= 32'd0;
         r_dma_dst     <= 32'd0;
         r_dma_len     <= 32'd0;
         r_dma_src_reg <= 32'd0;
         r_dma_dst_reg <= 32'd0;
         r_dma_len_reg <= 32'd0;
         r_dma_data    <= 128'd0;
         r_dma_done    <= 1'b0;
      end
      else begin
         r_dma_state   <= n_dma_state;
         r_dma_src     <= n_dma_src;
         r_dma_dst     <= n_dma_dst;
         r_dma_len     <= n_dma_len;
         r_dma_src_reg <= n_dma_src_reg;
         r_dma_dst_reg <= n_dma_dst_reg;
         r_dma_len_reg <= n_dma_len_reg;
         r_dma_data    <= n_dma_data;
         r_dma_done    <= n_dma_done;
      end
   end

   // status read (0x1000c): bit1=DONE bit0=BUSY, placed in byte[31:24] so the BE
   // load path delivers it to the guest's low byte (same lane convention as SYSID).
   assign status             = {6'd0, r_dma_done, w_dma_busy, 24'd0};

   assign dma_req_valid      = w_dma_busy;
   assign dma_req_addr       = (r_dma_state == DMA_RD)
                               ? {{(`PA_WIDTH-32){1'b0}}, r_dma_src}
                               : {{(`PA_WIDTH-32){1'b0}}, r_dma_dst};
   assign dma_req_opcode     = (r_dma_state == DMA_RD) ? 5'd4 : 5'd7;   // load / store
   assign dma_req_store_data = r_dma_data;
   assign dma_req_mask       = 16'hffff;
endmodule // dma_memcpy
