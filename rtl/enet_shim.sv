`include "machine.vh"
// -----------------------------------------------------------------------------
// enet_shim.sv -- Seeq 8003 + HPC3 ENET-DMA-channel control shim for the
// ARM/DPI-host-serviced ethernet path.  The ethernet analog of scsi_shim.
//
// Owns the guest-facing registers the stock IRIX if_ec / Linux sgiseeq driver
// pokes; moves ZERO frame bytes.  Two host-serviced HPC3 DMA channels:
//
//   TX (ch1, guest-initiated -- like a SCSI write): the driver programs the TX
//   descriptor chain (NBDP) + writes tx_ctrl ACTIVE.  The shim snapshots {NBDP}
//   into the TX mailbox and bumps enet_tx_req_seq (the TX doorbell).  The service
//   (C++ in henry_tb, ARM on the FPGA) walks the {BP,BC,DP} chain in DRAM,
//   assembles the frame (concatenate buffers to EOX), writes it to a host TAP,
//   sets each descriptor's ETXD, and echoes enet_tx_rsp_seq.  The shim then
//   clears tx_ctrl ACTIVE and raises the ENET channel IRQ.
//
//   RX (ch0, unsolicited -- service-initiated "reverse doorbell"): the driver
//   arms the RX ring (descriptors with OWN=1) + writes rx_ctrl ACTIVE; the shim
//   bumps enet_rx_arm_seq and publishes the ring head (enet_rx_nbdp).  Whenever a
//   frame arrives on the TAP, the service walks the ring, deposits
//   [2 pad][frame][1 status=0x30], clears OWN, writes back BCNT=residual,
//   reports the filled descriptor in enet_rx_crbdp (guest reads it at 0x18000),
//   and bumps enet_rx_rsp_seq.  The shim then raises the ENET channel IRQ.
//
// The ENET channel IRQ (TX or RX) -> IOC2 local0 bit3 (ENET) -> IP2, cleared when
// the driver's ISR writes the reset reg (0x15014/0x17014, CLRIRQ) -- matches the
// validated interp_mips model (sgi_hpc.cc / sgi_seeq.cc; iris seeq8003.rs).
//
// MMIO bus (shared HPC3 window; offs = pa & 0x7ffff, line-aligned + 16-bit mask;
// byte N = wdata[8*N +: 8]).  The Seeq 8-byte PIO regs at 0x54000 are word-spaced
// (reg N in the MSB of the word at 0x54000+N*4).  The HPC3 32-bit DMA regs ARE
// byte-swapped (bswap32), like the SCSI channel.  Register map + contract:
// sim/henry_scsi.h (CH_ENET_TX/RX seam).
// -----------------------------------------------------------------------------
module enet_shim
   (input  logic         clk,
    input  logic         reset,
    // ---- guest MMIO (HPC3 window; offs = pa & 0x7ffff, line-aligned + mask) ----
    input  logic         sel,
    input  logic         is_store,
    input  logic [18:0]  offs,
    input  logic [15:0]  mask,
    input  logic [127:0] wdata,
    output logic [127:0] rdata,
    // ---- TX mailbox: shim -> service (published on tx_ctrl ACTIVE) ----
    output logic [31:0]  enet_tx_req_seq,    // TX doorbell: ++ per transmit kick
    output logic [31:0]  enet_tx_nbdp,       // TX descriptor-chain head (phys)
    input  logic [31:0]  enet_tx_rsp_seq,    // echoes enet_tx_req_seq when frame sent
    // ---- RX mailbox: reverse doorbell (service free-runs on each inbound frame) ----
    output logic [31:0]  enet_rx_arm_seq,    // ++ when the guest (re)arms rx_ctrl ACTIVE
    output logic [31:0]  enet_rx_nbdp,       // RX ring head (phys)
    input  logic [31:0]  enet_rx_rsp_seq,    // ++ by the service per injected frame
    input  logic [31:0]  enet_rx_crbdp,      // service-maintained current RX desc (reg 0x18000)
    // ---- Seeq config -> service (for the RX address filter) ----
    output logic [47:0]  enet_station,       // programmed station MAC (bank-0 regs 0..5)
    output logic [7:0]   enet_rx_cmd,        // Seeq RX command (match mode + int enables)
    // ---- interrupt ----
    output logic         enet_intrq,         // -> IOC2 local0 bit3 (ENET)
    // ---- silicon debug visibility (read back via an AXI PMU slot) ----
    output logic [31:0]  dbg);

   // ---- Seeq 8003 register-model constants (from interp_mips sgi_seeq.cc) ----
   localparam [7:0] RS_OLD = 8'h80, RX_STATUS_GOOD = 8'h30;      // rx_stat: 0x30 = GOOD|END
   localparam [7:0] XS_OLD = 8'h80, XS_SUCCESS = 8'h08;          // tx_stat
   localparam [7:0] EDLC_NO_SQE = 8'h01;                         // reg5 read = carrier present
   localparam [7:0] XC_BANK_MASK = 8'h60;                        // tx_cmd[6:5] = write bank

   // ---- HPC3 ENET DMA channel ctrl bit ----
   localparam [31:0] HPC_ACTIVE = 32'h00000200;                  // rx/tx_ctrl ACTIVE (STRCVDMA)

   // ---- guest-written Seeq register state ----
   logic [47:0] r_station;                  // station MAC, bank-0 regs 0..5 (byte0 = reg0)
   logic [7:0]  r_rx_cmd, r_tx_cmd;
   logic [7:0]  r_rx_stat, r_tx_stat;

   // ---- HPC3 ENET DMA channels (RX = ch0, TX = ch1) ----
   logic [31:0] r_rx_cbp, r_rx_nbdp, r_rx_bc;
   logic [31:0] r_tx_cbp, r_tx_nbdp, r_tx_bc;
   logic        r_rx_active, r_tx_active;

   // ---- mailbox / interrupt bookkeeping ----
   logic [31:0] r_tx_req_seq, r_tx_done_seq, r_tx_req_nbdp;
   logic [31:0] r_rx_arm_seq, r_rx_done_seq;
   logic        r_rx_irq, r_tx_irq;         // HPC3 ENET RX/TX channel IRQ -> local0[3]

   // ---- MMIO decode.  ch = offs[13] (the 0x2000 bit): RX=ch0 @0x14000, TX=ch1 @0x16000.
   //      Normalize with ~0x2000 so both channels share the case values. ----
   wire         w_ch     = offs[13];                              // 0 = RX, 1 = TX
   wire [18:0]  w_n      = offs & ~19'h2000;                      // channel-normalized offset
   wire         w_cbpln  = sel & (w_n == 19'h14000);              // CBP(w0) / NBDP(w1)
   wire         w_bcln   = sel & (w_n == 19'h15000);              // BC(w0)  / CTRL(w1)
   wire         w_rstln  = sel & (w_n == 19'h15010);              // reset/CLRIRQ @0x15014 (w1)
   wire         w_crbdp  = sel & (offs == 19'h18000);             // CRBDP (RX only, w0)
   wire         w_seeqlo = sel & (offs == 19'h54000);             // Seeq regs 0..3
   wire         w_seeqhi = sel & (offs == 19'h54010);             // Seeq regs 4..7

   wire         w_cbp_wr  = w_cbpln & is_store & (mask[3:0] == 4'hf);
   wire         w_nbdp_wr = w_cbpln & is_store & (mask[7:4] == 4'hf);
   wire         w_bc_wr   = w_bcln  & is_store & (mask[3:0] == 4'hf);
   wire         w_ctrl_wr = w_bcln  & is_store & (mask[7:4] == 4'hf);
   wire         w_rst_wr  = w_rstln & is_store & (mask[7:4] == 4'hf);
   wire [31:0]  w_ctrl_val = bswap32(wdata[63:32]);               // rx/tx_ctrl (byte-swapped)
   wire         w_ctrl_active = (w_ctrl_val & HPC_ACTIVE) != 32'd0;
   wire         w_tx_kick  = w_ctrl_wr &  w_ch & w_ctrl_active;   // TX ACTIVE  -> doorbell
   wire         w_rx_arm   = w_ctrl_wr & ~w_ch & w_ctrl_active;   // RX ACTIVE  -> arm

   // completion detects (service echoed our seq / free-ran the RX seq)
   wire         w_tx_complete = (r_tx_req_seq != r_tx_done_seq) & (enet_tx_rsp_seq == r_tx_req_seq);
   wire         w_rx_inject   = (enet_rx_rsp_seq != r_rx_done_seq);

   // Seeq register writes: the byte lives in the MSB of the guest word, i.e. byte
   // (reg&3)*4 of the line.  regs 0..3 in line 0x54000, regs 4..7 in line 0x54010.
   wire [7:0] w_r0 = wdata[7:0];      wire [7:0] w_r1 = wdata[39:32];
   wire [7:0] w_r2 = wdata[71:64];    wire [7:0] w_r3 = wdata[103:96];
   wire w_bank0 = (r_tx_cmd & XC_BANK_MASK) == 8'h00;             // bank 0 = station address

   always_ff @(posedge clk) begin
      if(reset) begin
         r_station <= 48'd0; r_rx_cmd <= 8'd0; r_tx_cmd <= 8'd0;
         r_rx_stat <= RS_OLD; r_tx_stat <= XS_OLD | XS_SUCCESS;
         r_rx_cbp <= 32'd0; r_rx_nbdp <= 32'd0; r_rx_bc <= 32'd0;
         r_tx_cbp <= 32'd0; r_tx_nbdp <= 32'd0; r_tx_bc <= 32'd0;
         r_rx_active <= 1'b0; r_tx_active <= 1'b0;
         r_tx_req_seq <= 32'd0; r_tx_done_seq <= 32'd0; r_tx_req_nbdp <= 32'd0;
         r_rx_arm_seq <= 32'd0; r_rx_done_seq <= 32'd0;
         r_rx_irq <= 1'b0; r_tx_irq <= 1'b0;
      end
      else begin
         // ---- Seeq 8003 PIO register writes (station addr banks + rx/tx cmd) ----
         if(w_seeqlo & is_store & w_bank0) begin                 // regs 0..3 = station[0..3]
            if(mask[0])  r_station[47:40] <= w_r0;               // reg0 = station byte 0 (MSB)
            if(mask[4])  r_station[39:32] <= w_r1;
            if(mask[8])  r_station[31:24] <= w_r2;
            if(mask[12]) r_station[23:16] <= w_r3;
         end
         if(w_seeqhi & is_store) begin
            if(w_bank0 & mask[0]) r_station[15:8] <= w_r0;       // reg4 = station byte 4
            if(w_bank0 & mask[4]) r_station[7:0]  <= w_r1;       // reg5 = station byte 5
            if(mask[8])  r_rx_cmd <= w_r2;                       // reg6 = RX command
            if(mask[12]) r_tx_cmd <= w_r3;                       // reg7 = TX command
         end
         // ---- Seeq status OLD-marking on register reads (reg6/reg7) ----
         if(w_seeqhi & ~is_store & mask[8])  r_rx_stat <= r_rx_stat | RS_OLD;
         if(w_seeqhi & ~is_store & mask[12]) r_tx_stat <= r_tx_stat | XS_OLD;

         // ---- HPC3 ENET DMA channel registers (byte-swapped) ----
         if(w_cbp_wr)  begin if(w_ch) r_tx_cbp  <= bswap32(wdata[31:0]);  else r_rx_cbp  <= bswap32(wdata[31:0]);  end
         if(w_nbdp_wr) begin if(w_ch) r_tx_nbdp <= bswap32(wdata[63:32]); else r_rx_nbdp <= bswap32(wdata[63:32]); end
         if(w_bc_wr)   begin if(w_ch) r_tx_bc   <= bswap32(wdata[31:0]);  else r_rx_bc   <= bswap32(wdata[31:0]);  end
         if(w_ctrl_wr) begin
            if(w_ch) r_tx_active <= w_ctrl_active;
            else     r_rx_active <= w_ctrl_active;
         end

         // ---- TX doorbell: guest wrote tx_ctrl ACTIVE ----
         if(w_tx_kick) begin
            r_tx_req_seq  <= r_tx_req_seq + 32'd1;
            r_tx_req_nbdp <= r_tx_nbdp;
         end
         // ---- RX arm: guest wrote rx_ctrl ACTIVE ----
         if(w_rx_arm) begin
            r_rx_arm_seq <= r_rx_arm_seq + 32'd1;
         end

         // ---- TX completion (service echoed the TX seq) ----
         if(w_tx_complete) begin
            r_tx_done_seq <= r_tx_req_seq;
            r_tx_active   <= 1'b0;                               // DMA done: clear tx ACTIVE
            r_tx_irq      <= 1'b1;                               // ENET TX channel IRQ
            r_tx_stat     <= XS_SUCCESS;                         // NEW status (OLD cleared)
         end
         // ---- RX inject (service free-ran the RX seq per inbound frame) ----
         if(w_rx_inject) begin
            r_rx_done_seq <= enet_rx_rsp_seq;
            r_rx_irq      <= 1'b1;                               // ENET RX channel IRQ
            r_rx_stat     <= RX_STATUS_GOOD;                     // NEW status (OLD cleared)
         end

         // ---- CLRIRQ: the driver's ISR writes the reset reg to clear the ENET IRQ.
         //      Lowest priority so a same-cycle inject/complete still latches. ----
         if(w_rst_wr & ~w_tx_complete & ~w_rx_inject) begin
            r_rx_irq <= 1'b0; r_tx_irq <= 1'b0;
         end
      end
   end // always_ff

   // ---- read path ----
   always_comb begin
      rdata = 128'd0;
      // HPC3 ENET DMA channel reads (byte-swapped)
      if(w_cbpln & ~is_store & (mask[3:0] == 4'hf)) rdata[31:0]  = bswap32(w_ch ? r_tx_cbp  : r_rx_cbp);
      if(w_cbpln & ~is_store & (mask[7:4] == 4'hf)) rdata[63:32] = bswap32(w_ch ? r_tx_nbdp : r_rx_nbdp);
      if(w_bcln  & ~is_store & (mask[3:0] == 4'hf)) rdata[31:0]  = bswap32(w_ch ? r_tx_bc   : r_rx_bc);
      // rx/tx_ctrl read: ACTIVE bit | Seeq rx/tx status (does NOT mark it OLD)
      if(w_bcln  & ~is_store & (mask[7:4] == 4'hf))
        rdata[63:32] = bswap32(((w_ch ? r_tx_active : r_rx_active) ? HPC_ACTIVE : 32'd0) |
                               {24'd0, (w_ch ? r_tx_stat : r_rx_stat)});
      // reset reg (0x15014) read: CLRIRQ (0x2) reflects a pending ENET channel IRQ
      if(w_rstln & ~is_store & (mask[7:4] == 4'hf))
        rdata[63:32] = bswap32((r_rx_irq | r_tx_irq) ? 32'h2 : 32'd0);
      // CRBDP read (0x18000): service-maintained current RX descriptor pointer
      if(w_crbdp & ~is_store & (mask[3:0] == 4'hf)) rdata[31:0] = bswap32(enet_rx_crbdp);
      // Seeq PIO reads: reg5 = NO_SQE (carrier), reg6 = rx_stat, reg7 = tx_stat; else 0.
      // The byte goes in the MSB of the guest word, i.e. byte (reg&3)*4 of the line.
      if(w_seeqhi & ~is_store) begin
         rdata[39:32]  = EDLC_NO_SQE;                            // reg5 (byte4)
         rdata[71:64]  = r_rx_stat;                             // reg6 (byte8)
         rdata[103:96] = r_tx_stat;                             // reg7 (byte12)
      end
   end // always_comb

   // ---- mailbox outputs (stable between doorbells) ----
   assign enet_tx_req_seq = r_tx_req_seq;
   assign enet_tx_nbdp    = r_tx_req_nbdp;
   assign enet_rx_arm_seq = r_rx_arm_seq;
   assign enet_rx_nbdp    = r_rx_nbdp;
   assign enet_station    = r_station;
   assign enet_rx_cmd     = r_rx_cmd;
   assign enet_intrq      = r_rx_irq | r_tx_irq;
   // dbg: [3]=tx_active [2]=rx_active [1]=tx_irq [0]=rx_irq [15:8]=rx_cmd [23:16]=tx_stat[..]
   assign dbg = {8'd0, r_tx_stat, r_rx_cmd, 4'd0, r_tx_active, r_rx_active, r_tx_irq, r_rx_irq};

endmodule // enet_shim
