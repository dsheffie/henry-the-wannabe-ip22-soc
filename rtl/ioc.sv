// -----------------------------------------------------------------------------
// ioc.sv -- SGI Indy IOC2 I/O controller @ phys 0x1fbd9800 .. 0x1fbd98ff
// (a sub-window of the HPC3 space).  Models the two boot-critical pieces:
//   * SYSID  @ +0x58 : guinness/Indy board id; getsysid masks bits[7:0] for 0x20.
//   * Z8530 SCC @ +0x30 (16 B, "ab_dc"): byte b is DATA iff (b>>2)&1, else CONTROL.
//     CONTROL reads -> RR0 (Tx-empty|all-sent = 0x44) so IRIX's du driver always
//     thinks it can transmit; DATA writes are the serial console TX (scc_tx_*).
// (from r9999 sgi_hpc.cc + sgi_scc.cc).  Line base `offs` is 16-byte aligned.
// -----------------------------------------------------------------------------
module ioc
   (input  logic         clk,
    input  logic         reset,
    input  logic         sel,
    input  logic         is_store,
    input  logic [7:0]   offs,       // line base, byte offset within IOC2 (addr & 0xff)
    input  logic [15:0]  mask,
    input  logic [127:0] wdata,
    input  logic         con_full,   // SoC console FIFO full -> SCC Tx not ready (backpressure)
    output logic [127:0] rdata,
    output logic         scc_tx_valid,
    output logic [7:0]   scc_tx_byte);

   // SYSID stored 0x26000000 -> BE lw yields 0x00000026 (board id in bits[7:0]).
   localparam [31:0] IOC2_SYSID = 32'h26000000;
   localparam [7:0]  SCC_RR0    = 8'h44;       // RR0: Tx-Buffer-Empty | All-Sent
   // Tx-Buffer-Empty (bit2) reflects "console FIFO can accept a byte": clear it
   // when the FIFO is full so the du driver's RR0 poll rate-limits to the drain
   // (otherwise it blasts and overflows the 8-deep FIFO -> dropped console bytes).
   wire [7:0] w_rr0 = con_full ? (SCC_RR0 & 8'hfb) : SCC_RR0;  // &~0x04

   wire w_scc = (offs == 8'h30);               // the SCC 16-byte window @ IOC+0x30
   integer i, b;

   always_comb begin
      rdata = '0;
      if(w_scc) begin
         // SCC: CONTROL bytes -> RR0, DATA bytes -> 0 (no Rx)
         for(b = 0; b < 16; b = b + 1)
           if(mask[b] & (((b>>2)&1) == 0))
             rdata[8*b +: 8] = w_rr0;
      end
      else begin
         // word-granular IOC2 regs (only SYSID @ +0x58 modeled)
         for(i = 0; i < 4; i = i + 1)
           if(mask[4*i +: 4] == 4'hf && ((offs + 8'(4*i)) == 8'h58))
             rdata[32*i +: 32] = IOC2_SYSID;
      end
   end

   // SCC DATA write -> serial console TX byte (combinational, on the accept cycle)
   always_comb begin
      scc_tx_valid = 1'b0;
      scc_tx_byte  = 8'h0;
      if(sel & is_store & w_scc)
        for(b = 0; b < 16; b = b + 1)
          if(mask[b] & (((b>>2)&1) == 1)) begin
             scc_tx_valid = 1'b1;
             scc_tx_byte  = wdata[8*b +: 8];
          end
   end

   // (IOC2 interrupt/GIO-config registers not yet modeled: reads 0, writes absorbed.)
endmodule // ioc
