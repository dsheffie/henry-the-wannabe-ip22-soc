// -----------------------------------------------------------------------------
// int3.sv -- SGI Indy IOC2 "INT3" interrupt multiplexor (skeleton).
//
// Muxes the IP22 device interrupt sources onto the 5 CPU hardware interrupt
// pins IP2..IP6 (R4000 Cause.IP[6:2]). Register map per ioc.pdf 4.5
// (INT3 REGISTERS, 0x1FBD9880..0x1FBD98AC); sgint base = IOC2 + 0x80, each
// register is a byte at a 4-byte-aligned address:
//   0x80 LOCAL0 STATUS (istat0 ,R)   0x84 LOCAL0 MASK (imask0   ,RW)
//   0x88 LOCAL1 STATUS (istat1 ,R)   0x8c LOCAL1 MASK (imask1   ,RW)
//   0x90 MAP STATUS    (vmeistat,R)  0x94 MAP MASK0   (cmeimask0,RW)
//   0x98 MAP MASK1     (cmeimask1,RW)0x9c MAP POL     (cmepol   ,RW)
//   0xa0 TIMER CLEAR   (tclear ,W)   0xa4 ERROR STAT  (errstat  ,R)
//
// INT3 does NO internal latching except the two 8254 timer interrupts; all
// Local0/Local1/Mappable inputs are LEVEL-triggered (the source holds the
// line until serviced). Output mapping (INT3 "Level N" -> CPU IP[N+2]):
//   Level0 Local0 -> IP2   Level1 Local1 -> IP3
//   Level2 Timer0 -> IP4   Level3 Timer1 -> IP5   Level4 BusErr -> IP6
//
// SKELETON: the 4.5 register file + the aggregation to IP2..IP6 are complete;
// the device SOURCES are input ports (henry_soc ties them 0 for now). The first
// real source to wire is the SCC serial RX:
//   SCC RX-avail -> map_src[5] (Serial DUART) -> MAP_INT0 (via cmeimask0)
//                -> istat0[7] (LIO2) -> IP2.
//
// Same 16-byte-granular device interface as ioc/mc/hpc3: offs = the 16-byte
// line base, byte b within the line = data[8*b +: 8], selected by mask[b].
// -----------------------------------------------------------------------------
module int3
  (input  logic         clk,
   input  logic         reset,
   // IOC2 device access
   input  logic         sel,
   input  logic         is_store,
   input  logic [7:0]   offs,
   input  logic [15:0]  mask,
   input  logic [127:0] wdata,
   output logic [127:0] rdata,
   // device interrupt sources (level, active-high here; tied 0 until wired)
   input  logic [6:0]   local0_src,  // [0]FIFOfull [1]SCSI0 [2]SCSI1 [3]ENET [4]MCDMA [5]PPORT [6]GFX
   input  logic [7:0]   local1_src,  // [0]GP0 [1]PANEL [2]GP2 [3]=MAP_INT1(unused) [4]HPCDMA [5]ACFAIL [6]VSYNC [7]VRETRACE
   input  logic [7:0]   map_src,     // 8 mappable inputs; [5]=Serial DUART [4]=Kbd/Mouse
   input  logic [2:0]   buserr,      // [0]EISA [1]MC [2]HPC (not maskable)
   input  logic         timer0_irq,  // 8254 cnt0 (latched -> IP4)
   input  logic         timer1_irq,  // 8254 cnt1 (latched -> IP5)
   // CPU hardware interrupt pins
   output logic         ip2,
   output logic         ip3,
   output logic         ip4,
   output logic         ip5,
   output logic         ip6);

   // ---- RW mask/polarity registers (default 0 = all masked, per 4.5) ----
   logic [7:0] r_imask0, r_imask1, r_cmeimask0, r_cmeimask1, r_cmepol;
   // ---- the only INT3 latches: the two 8254 timer interrupts ----
   logic       r_timer0, r_timer1;

   // ---- combinational status (level-triggered; recomputed each cycle) ----
   // MAP STATUS = raw mappable source status (4.5: unaffected by mask/polarity).
   // (cmepol is stored but polarity conversion is deferred until real, possibly
   //  active-low, mappable sources are wired -- e.g. the active-low SCC serial.)
   wire [7:0] w_vmeistat = map_src;
   // Mappable Interrupt 0/1 = OR of (map status & the respective map mask).
   wire       w_map_int0 = |(w_vmeistat & r_cmeimask0);
   wire       w_map_int1 = |(w_vmeistat & r_cmeimask1);
   // LOCAL0 STATUS: bit7 = MAP_INT0, bits[6:0] = local0 device sources.
   wire [7:0] w_istat0 = {w_map_int0, local0_src};
   // LOCAL1 STATUS: bit3 = MAP_INT1, others = local1 device sources.
   wire [7:0] w_istat1 = {local1_src[7:4], w_map_int1, local1_src[2:0]};
   // ERROR STAT (bus errors, not maskable).
   wire [7:0] w_errstat = {5'd0, buserr};

   // ---- aggregation -> CPU IP pins (Level N -> IP[N+2]) ----
   assign ip2 = |(w_istat0 & r_imask0);   // Level0 Local0
   assign ip3 = |(w_istat1 & r_imask1);   // Level1 Local1
   assign ip4 = r_timer0;                  // Level2 Timer0 (latched)
   assign ip5 = r_timer1;                  // Level3 Timer1 (latched)
   assign ip6 = |buserr;                   // Level4 BusErr (not maskable)

   // ---- register read (offs = line base; reg = byte b -> rdata[8*b +: 8]) ----
   always_comb begin
      rdata = '0;
      if(offs == 8'h80) begin
         if(mask[0])  rdata[8*0  +: 8] = w_istat0;     // LOCAL0 STATUS @0x80
         if(mask[4])  rdata[8*4  +: 8] = r_imask0;     // LOCAL0 MASK   @0x84
         if(mask[8])  rdata[8*8  +: 8] = w_istat1;     // LOCAL1 STATUS @0x88
         if(mask[12]) rdata[8*12 +: 8] = r_imask1;     // LOCAL1 MASK   @0x8c
      end
      else if(offs == 8'h90) begin
         if(mask[0])  rdata[8*0  +: 8] = w_vmeistat;   // MAP STATUS    @0x90
         if(mask[4])  rdata[8*4  +: 8] = r_cmeimask0;  // MAP MASK0     @0x94
         if(mask[8])  rdata[8*8  +: 8] = r_cmeimask1;  // MAP MASK1     @0x98
         if(mask[12]) rdata[8*12 +: 8] = r_cmepol;     // MAP POL       @0x9c
      end
      else if(offs == 8'ha0) begin
         // TIMER CLEAR @0xa0 is write-only (reads 0).
         if(mask[4])  rdata[8*4  +: 8] = w_errstat;    // ERROR STAT    @0xa4
      end
   end

   // ---- register writes + 8254 timer latch / TIMER CLEAR ----
   wire       w_l0      = sel & is_store & (offs == 8'h80);
   wire       w_l1      = sel & is_store & (offs == 8'h90);
   wire       w_tc      = sel & is_store & (offs == 8'ha0) & mask[0];   // TIMER CLEAR @0xa0
   wire [7:0] w_tclear  = wdata[8*0 +: 8];

   always_ff @(posedge clk) begin
      if(reset) begin
         r_imask0    <= 8'd0;
         r_imask1    <= 8'd0;
         r_cmeimask0 <= 8'd0;
         r_cmeimask1 <= 8'd0;
         r_cmepol    <= 8'd0;
         r_timer0    <= 1'b0;
         r_timer1    <= 1'b0;
      end
      else begin
         if(w_l0 & mask[4])  r_imask0    <= wdata[8*4  +: 8];   // LOCAL0 MASK
         if(w_l0 & mask[12]) r_imask1    <= wdata[8*12 +: 8];   // LOCAL1 MASK
         if(w_l1 & mask[4])  r_cmeimask0 <= wdata[8*4  +: 8];   // MAP MASK0
         if(w_l1 & mask[8])  r_cmeimask1 <= wdata[8*8  +: 8];   // MAP MASK1
         if(w_l1 & mask[12]) r_cmepol    <= wdata[8*12 +: 8];   // MAP POL
         // 8254 timer interrupts latch on assert, clear on TIMER CLEAR bit0/1.
         if(timer0_irq)              r_timer0 <= 1'b1;
         else if(w_tc & w_tclear[0]) r_timer0 <= 1'b0;
         if(timer1_irq)              r_timer1 <= 1'b1;
         else if(w_tc & w_tclear[1]) r_timer1 <= 1'b0;
      end
   end
endmodule // int3
