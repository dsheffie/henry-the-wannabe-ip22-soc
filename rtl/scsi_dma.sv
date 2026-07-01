`include "machine.vh"
// -----------------------------------------------------------------------------
// scsi_dma.sv -- HPC3 SCSI DMA channel: walk the {BP,BC,DP} descriptor chain in
// DRAM (through the henry arbiter, a REAL ordered DRAM master) and stream data
// between memory and the disk side (a 16-byte beat port the TB/ARM fills/drains).
//
// This is the lower-level replacement for the "offload the whole transaction"
// host service.  Because the descriptor read + buffer accesses go through the
// SAME ordered DRAM port as the CPU, read-after-write holds BY CONSTRUCTION --
// no g_mem backdoor, no latency constant.  The disk media (which LBA, the bytes)
// stays in the TB/ARM; only the memory movement is RTL.
//
// Descriptor (12 bytes, stored BIG-ENDIAN, one per 16-byte line at NBDP):
//   +0  BP  buffer pointer (physical)
//   +4  BC  byte count[13:0] + XIE(bit29) + EOX(bit31)
//   +8  DP  next-descriptor pointer; follow until EOX
// Data buffers are raw byte streams (no swap); descriptor words are BE.
//
// Phase-1 scope: 16-byte-aligned BC counts and 16-byte-aligned NBDP; the disk
// side is assumed always-ready (no backpressure).  Backpressure + the TB block
// transport (4 KB / 8-LBA chunks) come in a later phase.
// -----------------------------------------------------------------------------
module scsi_dma
   (input  logic         clk,
    input  logic         reset,
    // ---- control ----
    input  logic         go,            // 1-cycle pulse: start the chain at nbdp
    input  logic [31:0]  nbdp,          // chain head (physical, 16-byte aligned)
    input  logic         to_device,     // 1 = WRITE (mem->disk), 0 = READ (disk->mem)
    output logic         busy,
    output logic         done,          // 1-cycle pulse when the chain completes
    output logic         irq,           // 1-cycle pulse if the final desc had XIE
    output logic         rd_stalled,    // READ: waiting for a disk beat that isn't in the FIFO
    // ---- DMA master -> henry DRAM arbiter ----
    output logic                  dma_req_valid,
    output logic [`PA_WIDTH-1:0]  dma_req_addr,
    output logic [4:0]            dma_req_opcode,     // 4 = line load, 7 = line store
    output logic [127:0]          dma_req_store_data,
    output logic [15:0]           dma_req_mask,
    input  logic                  dma_rsp_valid,
    input  logic [127:0]          dma_rsp_load_data,
    // ---- disk side: 16-byte beat stream (TB/ARM is the disk media) ----
    output logic         disk_rd_en,     // READ: pulse, consume disk_rd_data this cycle
    input  logic [127:0] disk_rd_data,   // READ: disk -> mem beat (valid when disk_rd_valid)
    input  logic         disk_rd_valid,  // READ: a beat is available (FIFO non-empty); else stall
    input  logic         cancel,         // force back to IDLE (short/no-data/selection timeout)
    output logic         disk_wr_en,     // WRITE: pulse, disk_wr_data valid this cycle
    output logic [127:0] disk_wr_data);  // WRITE: mem -> disk beat

   typedef enum logic [2:0] {
      S_IDLE   = 3'd0,
      S_DESC   = 3'd1,   // read the descriptor line @ r_nbdp
      S_R_DISK = 3'd2,   // READ : pull a disk beat
      S_R_MEM  = 3'd3,   // READ : store the beat to mem[bp]
      S_W_MEM  = 3'd4,   // WRITE: load mem[bp]
      S_W_DISK = 3'd5,   // WRITE: push the beat to disk
      S_NEXT   = 3'd6,   // advance to dp or finish
      S_DONE   = 3'd7
   } state_t;

   state_t        r_state,  n_state;
   logic [31:0]   r_nbdp,   n_nbdp;     // current descriptor address
   logic [31:0]   r_bp,     n_bp;       // current buffer cursor
   logic [13:0]   r_cnt,    n_cnt;      // bytes remaining in this descriptor
   logic [31:0]   r_dp,     n_dp;       // next descriptor
   logic          r_eox,    n_eox;
   logic          r_xie,    n_xie;
   logic          r_to_dev, n_to_dev;
   logic [127:0]  r_data,   n_data;     // beat latched between disk and mem
   logic          r_done,   n_done;
   logic          r_irq,    n_irq;
   logic [7:0]    r_desc_cnt, n_desc_cnt;  // chain-length guard (null/garbage link)

   // descriptor fields: BE in DRAM, so byte-swap each 32-bit lane of the line
   wire [31:0] w_bp = bswap32(dma_rsp_load_data[31:0]);
   wire [31:0] w_bc = bswap32(dma_rsp_load_data[63:32]);
   wire [31:0] w_dp = bswap32(dma_rsp_load_data[95:64]);

   always_comb begin
      n_state    = r_state;
      n_nbdp     = r_nbdp;
      n_bp       = r_bp;
      n_cnt      = r_cnt;
      n_dp       = r_dp;
      n_eox      = r_eox;
      n_xie      = r_xie;
      n_to_dev   = r_to_dev;
      n_data     = r_data;
      n_done     = 1'b0;
      n_irq      = 1'b0;
      n_desc_cnt = r_desc_cnt;

      dma_req_valid      = 1'b0;
      dma_req_addr       = {{(`PA_WIDTH-32){1'b0}}, r_nbdp};
      dma_req_opcode     = 5'd4;
      dma_req_store_data = r_data;
      dma_req_mask       = 16'hffff;
      disk_rd_en         = 1'b0;
      disk_wr_en         = 1'b0;
      disk_wr_data       = r_data;       // WRITE beat = the line just loaded from mem

      case(r_state)
        S_IDLE:
          if(go) begin
             n_nbdp     = nbdp;
             n_to_dev   = to_device;
             n_desc_cnt = 8'd0;
             n_state    = S_DESC;
          end
        S_DESC: begin                              // read the descriptor line @ r_nbdp
           dma_req_valid  = 1'b1;
           dma_req_addr   = {{(`PA_WIDTH-32){1'b0}}, r_nbdp};
           dma_req_opcode = 5'd4;
           if(dma_rsp_valid) begin
              n_bp  = w_bp;
              n_cnt = w_bc[13:0];
              n_dp  = w_dp;
              n_eox = w_bc[31];
              n_xie = w_bc[29];
              n_state = (w_bc[13:0] == 14'd0) ? S_NEXT
                                              : (r_to_dev ? S_W_MEM : S_R_DISK);
           end
        end
        S_R_DISK:                                  // READ: pull a disk beat (stall until one is ready)
          if(disk_rd_valid) begin
             disk_rd_en = 1'b1;
             n_data     = disk_rd_data;
             n_state    = S_R_MEM;
          end
        S_R_MEM: begin                             // READ: store the beat to mem[bp]
           dma_req_valid      = 1'b1;
           dma_req_addr       = {{(`PA_WIDTH-32){1'b0}}, r_bp};
           dma_req_opcode     = 5'd7;
           dma_req_store_data = r_data;
           // final partial beat (cnt not a multiple of 16, e.g. MODE SENSE 254,
           // READ CAPACITY 8): byte-mask so we don't over-write past the buffer.
           dma_req_mask       = (r_cnt >= 14'd16) ? 16'hffff
                                                  : ((16'd1 << r_cnt[3:0]) - 16'd1);
           if(dma_rsp_valid) begin
              n_bp    = r_bp + 32'd16;
              n_cnt   = (r_cnt > 14'd16) ? (r_cnt - 14'd16) : 14'd0;
              n_state = (r_cnt <= 14'd16) ? S_NEXT : S_R_DISK;
           end
        end
        S_W_MEM: begin                             // WRITE: load mem[bp]
           dma_req_valid  = 1'b1;
           dma_req_addr   = {{(`PA_WIDTH-32){1'b0}}, r_bp};
           dma_req_opcode = 5'd4;
           if(dma_rsp_valid) begin
              n_data  = dma_rsp_load_data;
              n_state = S_W_DISK;
           end
        end
        S_W_DISK: begin                            // WRITE: push the beat to disk
           disk_wr_en = 1'b1;
           n_bp       = r_bp + 32'd16;
           n_cnt      = (r_cnt > 14'd16) ? (r_cnt - 14'd16) : 14'd0;
           n_state    = (r_cnt <= 14'd16) ? S_NEXT : S_W_MEM;
        end
        S_NEXT:
          // EOX, a null link (stale/garbage descriptor), or a runaway chain -> stop.
          if(r_eox | (r_dp == 32'd0) | (r_desc_cnt == 8'hff))
            n_state = S_DONE;
          else begin
             n_nbdp     = r_dp;
             n_desc_cnt = r_desc_cnt + 8'd1;
             n_state    = S_DESC;
          end
        S_DONE: begin
           n_done  = 1'b1;
           n_irq   = r_xie;
           n_state = S_IDLE;
        end
        default: n_state = S_IDLE;
      endcase
      if(cancel) n_state = S_IDLE;  // short/no-data/timeout: bail out of any stall, no done pulse
   end

   always_ff @(posedge clk) begin
      if(reset) begin
         r_state  <= S_IDLE;
         r_nbdp   <= 32'd0;
         r_bp     <= 32'd0;
         r_cnt    <= 14'd0;
         r_dp     <= 32'd0;
         r_eox    <= 1'b0;
         r_xie    <= 1'b0;
         r_to_dev <= 1'b0;
         r_data   <= 128'd0;
         r_done   <= 1'b0;
         r_irq    <= 1'b0;
         r_desc_cnt <= 8'd0;
      end
      else begin
         r_state  <= n_state;
         r_nbdp   <= n_nbdp;
         r_bp     <= n_bp;
         r_cnt    <= n_cnt;
         r_dp     <= n_dp;
         r_eox    <= n_eox;
         r_xie    <= n_xie;
         r_to_dev <= n_to_dev;
         r_data   <= n_data;
         r_done   <= n_done;
         r_irq    <= n_irq;
         r_desc_cnt <= n_desc_cnt;
      end
   end

   assign busy = (r_state != S_IDLE);
   // Engine is blocked in the READ data phase with no beat available -- i.e. it
   // wants a disk beat the ARM/TB hasn't streamed. The shim uses this (+ the ARM
   // having posted its rsp) to complete a short/no-data transfer instead of hanging.
   assign rd_stalled = (r_state == S_R_DISK) & ~disk_rd_valid;
   assign done = r_done;
   assign irq  = r_irq;

`ifdef VERILATOR
   always_ff @(posedge clk) begin
      if((r_state == S_IDLE) & go)
        $display("[sdma] GO nbdp=%08x to_dev=%b", nbdp, to_device);
      if((r_state == S_DESC) & dma_rsp_valid)
        $display("[sdma] DESC @%08x -> bp=%08x cnt=%0d eox=%b dp=%08x",
                 r_nbdp, w_bp, w_bc[13:0], w_bc[31], w_dp);
      if(r_done) $display("[sdma] DONE");
   end
`endif
endmodule // scsi_dma
