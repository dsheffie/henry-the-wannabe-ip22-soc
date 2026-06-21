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
// -----------------------------------------------------------------------------
module hpc3
   (input  logic         clk,
    input  logic         reset,
    input  logic         sel,
    input  logic         is_store,
    input  logic [18:0]  offs,       // line base, byte offset within HPC3 (addr & 0x7ffff)
    input  logic [15:0]  mask,
    input  logic [127:0] wdata,
    output logic [127:0] rdata);

   logic [31:0] r_intstat, r_misc;

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
         case(o)
           19'h30000: x = r_intstat;
           19'h30004: x = r_misc;
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
      end
      else if(sel & is_store) begin
         for(i = 0; i < 4; i = i + 1)
           if(mask[4*i +: 4] == 4'hf)
             case(offs + 19'(4*i))
               19'h30004: r_misc <= wdata[32*i +: 32] & 32'h3;
               default:   /* pbus/enet/scsi/pio windows: write-absorb */ ;
             endcase
      end
   end
endmodule // hpc3
