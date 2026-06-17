// -----------------------------------------------------------------------------
// mc.sv -- SGI Indy MC (memory controller) @ phys 0x1fa00000.
// Translated from the r9999 sgi_mc.cc functional model.  Big-endian IRIX uses
// the +4/+c register aliases, so register select ignores bit 2: index=(offs>>3)&1.
//
// Register-slave interface (driven by henry_soc's mem-bus FSM): on `sel` the
// 16-byte-aligned line at `offs` (mask = per-byte enables) is read (combinational
// `rdata`, per full word) and, when `is_store`, written (clocked).
// -----------------------------------------------------------------------------
module mc
  #(parameter [31:0] MEMCFG0 = 32'h0000_2023)  // bank0 cfg as STORED (BE lw -> 0x23200000 = 16 MB)
   (input  logic         clk,
    input  logic         reset,
    input  logic         sel,        // MC selected + a request this cycle
    input  logic         is_store,
    input  logic [16:0]  offs,       // line base, byte offset within MC (addr & 0x1ffff)
    input  logic [15:0]  mask,
    input  logic [127:0] wdata,
    output logic [127:0] rdata);

   // MC sysid/rev @0x1c: store 0x13000000 so the BE lw -> 0x00000013 (MAME golden);
   // low nibble = MC rev (3), rev<5 keeps the 22/14 mconfig shifts.
   localparam [31:0] MC_SYSID = 32'h13000000;

   logic [31:0] r_cpu_control [0:1];
   logic [31:0] r_memcfg      [0:1];
   logic [31:0] r_cpu_mem_acc, r_gio_mem_acc, r_rpss_div, r_gio64_arb, r_rpss, r_eeprom_ctrl;

   function automatic logic [31:0] mc_rd(input logic [16:0] o);
      logic [31:0] x;
      begin
         x = 32'd0;
         case(o)
           17'h0000,17'h0004,17'h0008,17'h000c: x = r_cpu_control[(o>>3)&1];
           17'h0018,17'h001c:                   x = MC_SYSID;
           17'h00c4,17'h00cc:                   x = r_memcfg[(o>>3)&1];
           17'h00d4:                            x = r_cpu_mem_acc;
           17'h00dc:                            x = r_gio_mem_acc;
           17'h0030:                            x = 32'h00000010;    // EEPROM: SDATAI high
           17'h1004:                            x = r_rpss / 32'd10;  // RPSS free-running counter
           default:                             x = 32'd0;
         endcase
         mc_rd = x;
      end
   endfunction

   integer i;

   always_comb begin
      rdata = '0;
      for(i = 0; i < 4; i = i + 1)
        if(mask[4*i +: 4] == 4'hf)
          rdata[32*i +: 32] = mc_rd(offs + 17'(4*i));
   end

   always_ff @(posedge clk) begin
      r_rpss <= reset ? 32'd0 : (r_rpss + 32'd1);
      if(reset) begin
         r_cpu_control[0] <= 32'd0; r_cpu_control[1] <= 32'd0;
         r_memcfg[0] <= MEMCFG0;    r_memcfg[1] <= 32'd0;
         r_cpu_mem_acc <= 32'd0; r_gio_mem_acc <= 32'd0;
         r_rpss_div <= 32'd0; r_gio64_arb <= 32'd0; r_eeprom_ctrl <= 32'd0;
      end
      else if(sel & is_store) begin
         for(i = 0; i < 4; i = i + 1)
           if(mask[4*i +: 4] == 4'hf)
             case(offs + 17'(4*i))
               17'h0000,17'h0004,17'h0008,17'h000c: r_cpu_control[((offs + 17'(4*i))>>3)&1] <= wdata[32*i +: 32];
               17'h002c:                            r_rpss_div    <= wdata[32*i +: 32];
               17'h0084:                            r_gio64_arb   <= wdata[32*i +: 32];
               17'h00c4,17'h00cc:                   r_memcfg[((offs + 17'(4*i))>>3)&1] <= wdata[32*i +: 32];
               17'h00d4:                            r_cpu_mem_acc <= wdata[32*i +: 32];
               17'h00dc:                            r_gio_mem_acc <= wdata[32*i +: 32];
               17'h0030:                            r_eeprom_ctrl <= wdata[32*i +: 32];
               default: /* ec/fc error-status clear + unhandled: ignore */ ;
             endcase
      end
   end
endmodule // mc
