// -----------------------------------------------------------------------------
// hpc3.sv -- SGI Indy HPC3 peripheral controller @ phys 0x1fb80000 .. 0x1fbfffff
// (the IOC2 sub-window @0x1fbd98xx is carved out and handled by ioc.sv).
// Translated from the r9999 sgi_hpc.cc functional model.
//
// Word-granular register slave (same interface as mc.sv).  Models the few regs
// the kernel reads (intstat/misc) plus the ds1386 RTC clock @0x60000 (fixed BCD
// time -- required so IRIX rtodc() doesn't spin); the SCSI/enet/PBUS DMA/PIO
// windows are write-absorbed.  Reads not yet modeled return 0 (a documented gap
// -- see tests/devregs: HPC 0x11004/0x58010/0x58020 etc. MAME returns nonzero).
//
// The mem-to-mem DMA copy engine (datapath bring-up / arbiter exercise) lives in
// dma_memcpy.sv and is gated by `ENABLE_HPC3_DMA below: it is NOT the real HPC3
// SCSI channel and the host-served (ARM/DPI) disk path does not need it, so the
// SoC build can compile it out (the DMA master then ties off, the arbiter sees a
// lone CPU master).  Default ON so the dma_memcpy isolation test stays exercised.
// -----------------------------------------------------------------------------
`include "machine.vh"
//`define ENABLE_HPC3_DMA 1

module hpc3
   (input  logic         clk,
    input  logic         reset,
    input  logic         sel,
    input  logic         is_store,
    input  logic [18:0]  offs,       // line base, byte offset within HPC3 (addr & 0x7ffff)
    input  logic [15:0]  mask,
    input  logic [127:0] wdata,
    output logic [127:0] rdata,
    // ---- DMA master (mem-to-mem copy engine) -> henry_soc DRAM arbiter ----
    output logic                  dma_req_valid,
    output logic [`PA_WIDTH-1:0]  dma_req_addr,
    output logic [4:0]            dma_req_opcode,     // 4 = line load, 7 = line store
    output logic [127:0]          dma_req_store_data,
    output logic [15:0]           dma_req_mask,
    input  logic                  dma_rsp_valid,
    input  logic [127:0]          dma_rsp_load_data);

   logic [31:0] r_intstat, r_misc;
   wire  [31:0] w_dma_status;       // CTRL (0x1000c) read value from the DMA engine (0 if gated off)

   // PBUS DMA/PIO channel config + SCSI0 channel config.  IRIX's pbus init writes
   // these and READS THEM BACK to validate (else "pbus configuration failed for
   // channel N"); the values don't affect the host-served disk path, so we just
   // store and return them to satisfy the probe.  (Matches interp_mips sgi_hpc.cc.)
   logic [31:0] r_pbus_dma [0:7];   // 0x5c000 block: 8 PBUS DMA channels (stride 0x200)
   logic [31:0] r_pbus_pio [0:15];  // 0x5d000 block: PBUS PIO channels (stride 0x100)
   logic [31:0] r_scsi_dmacfg, r_scsi_piocfg;  // 0x11010 / 0x11014 SCSI0 channel cfg

   // ds1386 RTC / battery-backed clock @0x60000 (byte-per-word x4: internal reg i
   // at offset 0x60000 + i*4, value in the low byte = [31:24] after the BE swap,
   // same lane convention as the IOC2 SYSID). A FIXED, valid BCD wall-clock
   // (2000-01-01 00:00:00) -- NOT optional: with the clock regs reading 0, IRIX's
   // rtodc() loop bound is garbage and boot spins forever; a valid BCD time lets
   // it print "lost battery backup clock" and proceed. (Ported from interp_mips
   // sgi_hpc.cc; see docs/peripherals/hpc3.md. month/date are 1-based BCD.)
   function automatic logic [31:0] hpc_rd(input logic [18:0] o);
      logic [31:0] x;
      begin
         x = 32'd0;
         if(o[18:12] == 7'h5c)       x = r_pbus_dma[o[11:9]];   // PBUS DMA cfg readback
         else if(o[18:12] == 7'h5d)  x = r_pbus_pio[o[11:8]];   // PBUS PIO cfg readback
         else if(o == 19'h11010)     x = r_scsi_dmacfg;         // SCSI0 DMA cfg readback
         else if(o == 19'h11014)     x = r_scsi_piocfg;         // SCSI0 PIO cfg readback
         else case(o)
           19'h30000: x = r_intstat;
           19'h30004: x = r_misc;
           19'h1000c: x = w_dma_status; // mem-to-mem DMA status: bit0=BUSY bit1=DONE
           19'h60004: x = 32'h00000000; // ds1386 seconds      (BCD 00)
           19'h60008: x = 32'h00000000; // ds1386 minutes      (BCD 00)
           19'h60010: x = 32'h00000000; // ds1386 hours        (BCD 00, 24h)
           19'h60018: x = 32'h01000000; // ds1386 day-of-week  (1)
           19'h60020: x = 32'h01000000; // ds1386 date         (1st)
           19'h60024: x = 32'h01000000; // ds1386 month        (January)
           19'h60028: x = 32'h00000000; // ds1386 year         (BCD 00 = 2000)
           19'h6002c: x = 32'h00000000; // ds1386 command/status (not busy)
           default:   x = 32'd0;     // unmodeled HPC3 read regs -> 0 (gap)
         endcase
         hpc_rd = x;
      end
   endfunction

   integer i;

   always_comb begin
      rdata = '0;
      for(i = 0; i < 4; i = i + 1)
        if(mask[4*i +: 4] == 4'hf)
          rdata[32*i +: 32] = hpc_rd(offs + 19'(4*i));
   end

   always_ff @(posedge clk) begin
      if(reset) begin
         r_intstat <= 32'd0;
         r_misc    <= 32'd0;
         for(i = 0; i < 8;  i = i + 1) r_pbus_dma[i] <= 32'd0;
         for(i = 0; i < 16; i = i + 1) r_pbus_pio[i] <= 32'd0;
         r_scsi_dmacfg <= 32'd0;
         r_scsi_piocfg <= 32'd0;
      end
      else if(sel & is_store) begin
         // PBUS DMA/PIO config + SCSI0 cfg: store so the readback validates.
         if((offs[18:12] == 7'h5c) & (mask[3:0] == 4'hf)) r_pbus_dma[offs[11:9]] <= wdata[31:0];
         if((offs[18:12] == 7'h5d) & (mask[3:0] == 4'hf)) r_pbus_pio[offs[11:8]] <= wdata[31:0];
         if((offs == 19'h11010)    & (mask[3:0] == 4'hf)) r_scsi_dmacfg <= wdata[31:0];
         if((offs == 19'h11010)    & (mask[7:4] == 4'hf)) r_scsi_piocfg <= wdata[63:32];
         // intstat/misc + remaining windows (write-absorb)
         for(i = 0; i < 4; i = i + 1)
           if(mask[4*i +: 4] == 4'hf)
             case(offs + 19'(4*i))
               19'h30004: r_misc <= wdata[32*i +: 32] & 32'h3;
               default:   /* enet/scsi/pio data windows: write-absorb */ ;
             endcase
      end
   end

`ifdef VERILATOR
   // TEMP: trace HPC3-window accesses in the PBUS config regions to see what IRIX's
   // pbus-config probe reads/writes (0x00000-0x0ffff dma chan, 0x10000-0x13fff scsi
   // chan+cfg, 0x58000-0x5dfff pio data + dma/pio config).
   always_ff @(posedge clk)
     if(sel & (offs[18:12] != 7'h30) & (offs[18:12] != 7'h40) & (offs[18:12] != 7'h60))
       $display("[hpc3acc] offs=%05x st=%b mask=%04x w0=%08x w1=%08x",
                offs, is_store, mask, wdata[31:0], wdata[63:32]);
`endif

   // ---- mem-to-mem DMA copy engine (gated; see dma_memcpy.sv) ----------------
`ifdef ENABLE_HPC3_DMA
   dma_memcpy u_dma
     (.clk(clk), .reset(reset),
      .sel(sel), .is_store(is_store), .offs(offs), .mask(mask), .wdata(wdata),
      .status(w_dma_status),
      .dma_req_valid(dma_req_valid), .dma_req_addr(dma_req_addr),
      .dma_req_opcode(dma_req_opcode), .dma_req_store_data(dma_req_store_data),
      .dma_req_mask(dma_req_mask),
      .dma_rsp_valid(dma_rsp_valid), .dma_rsp_load_data(dma_rsp_load_data));
`else
   // DMA engine compiled out: tie off the master (arbiter sees a lone CPU master).
   assign w_dma_status       = 32'd0;
   assign dma_req_valid      = 1'b0;
   assign dma_req_addr       = '0;
   assign dma_req_opcode     = '0;
   assign dma_req_store_data = '0;
   assign dma_req_mask       = '0;
`endif
endmodule // hpc3
