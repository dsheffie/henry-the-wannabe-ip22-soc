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
    output logic [7:0]   scc_tx_byte,
    output logic         timer0_irq);  // 8254 counter0 -> INT3 Timer0 (CPU IP4)

   // SYSID stored 0x26000000 -> BE lw yields 0x00000026 (board id in bits[7:0]).
   localparam [31:0] IOC2_SYSID = 32'h26000000;
   localparam [7:0]  SCC_RR0    = 8'h44;       // RR0: Tx-Buffer-Empty | All-Sent
   // Tx-Buffer-Empty (bit2) reflects "console FIFO can accept a byte": clear it
   // when the FIFO is full so the du driver's RR0 poll rate-limits to the drain
   // (otherwise it blasts and overflows the 8-deep FIFO -> dropped console bytes).
   wire [7:0] w_rr0 = con_full ? (SCC_RR0 & 8'hfb) : SCC_RR0;  // &~0x04

   wire w_scc = (offs == 8'h30);               // the SCC 16-byte window @ IOC+0x30
   integer i, b;

   // ---- i8254 PIT counter 2 (IP22 timer calibration; ip22-time.c dosample) ----
   // tcword = IOC byte 0xbf (line 0xb0, byte 15); tcnt2 = IOC byte 0xbb (byte 11).
   // NO interrupt: the kernel drives the tick from CP0 Count/Compare (the real 8254
   // IRQ is buggy on IP22), so the 8254 is calibration-only -- dosample programs
   // cnt2, then polls the latched value until its high byte reads 0, measuring CP0
   // Count over the interval. We tie the down-count to a free-running cycle counter
   // so the poll converges with a sane, deterministic CP0-Count delta.
   // The IP22 i8254 is clocked at EXACTLY 1 MHz -- NOT the PC's 1.193182 MHz
   // (kernel asm/sgi/ioc.h: "Unlike in PCs it's clocked at exactly 1MHz",
   // SGINT_TIMER_CLOCK = 1000000). Both IRIX and Linux dosample calibration assume
   // 1 MHz (mips_hpt_frequency = CP0-Count-delta / (PIT-count / 1 MHz)). So clock
   // the down-count at 1 MHz: divide the 100 MHz core clock by 100. A wrong rate
   // (the old /8 = 12.5 MHz) corrupts the calibration -> Linux timekeeping_advance
   // runs away on a bogus frequency; /84 (1.193 MHz) booted but skewed timing ~19%.
   localparam int PIT_DIV = 100;               // core-clock / PIT-rate (1 MHz @ 100 MHz)
   wire        w_pit          = (offs == 8'hb0);
   wire        w_pit_tcword_wr= sel &  is_store & w_pit & mask[15];
   wire        w_pit_tcnt2_wr = sel &  is_store & w_pit & mask[11];
   wire        w_pit_tcnt2_rd = sel & ~is_store & w_pit & mask[11];
   wire [7:0]  w_pit_tcword   = wdata[8*15 +: 8];
   wire [7:0]  w_pit_tcnt2_in = wdata[8*11 +: 8];

   logic [31:0] r_cycle;        // PIT-tick counter, advanced at ~1.193 MHz by r_presc
   logic [6:0]  r_presc;        // core-clock prescaler, 0..PIT_DIV-1 (no RTL divider)
   logic [15:0] r_t2_load, r_t2_latch;
   logic [31:0] r_t2_at;                        // cycle snapshot at (re)load
   logic        r_t2_wr_phase, r_t2_rd_phase, r_t2_loading;

   wire [31:0] w_t2_dec    = (r_cycle - r_t2_at);   // r_cycle is already at the PIT rate
   wire [15:0] w_t2_val    = (w_t2_dec >= {16'd0, r_t2_load}) ? 16'd0
                                                              : (r_t2_load - w_t2_dec[15:0]);
   wire [7:0]  w_t2_rdbyte = r_t2_rd_phase ? r_t2_latch[15:8] : r_t2_latch[7:0];

   always_comb begin
      rdata = '0;
      if(w_scc) begin
         // SCC: CONTROL bytes -> RR0, DATA bytes -> 0 (no Rx)
         for(b = 0; b < 16; b = b + 1)
           if(mask[b] & (((b>>2)&1) == 0))
             rdata[8*b +: 8] = w_rr0;
      end
      else if(w_pit) begin
         // i8254 counter 2 read: tcnt2 (byte 11) returns the latched lo/hi byte.
         if(mask[11])
           rdata[8*11 +: 8] = w_t2_rdbyte;
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

   // i8254 PIT state: free-running cycle counter + the latch/2-byte-load/lo-hi-read
   // protocol. sel is a one-cycle accept pulse, so each access updates state once.
   always_ff @(posedge clk) begin
      if(reset) begin
         r_cycle       <= 32'd0;
         r_presc       <= 7'd0;
         r_t2_load     <= 16'd0;
         r_t2_latch    <= 16'd0;
         r_t2_at       <= 32'd0;
         r_t2_wr_phase <= 1'b0;
         r_t2_rd_phase <= 1'b0;
         r_t2_loading  <= 1'b0;
      end
      else begin
         // prescaler: advance the PIT tick once per PIT_DIV core clocks (~1.193 MHz),
         // no RTL divider -- just a 7-bit counter + compare.
         if(r_presc == (PIT_DIV - 1)) begin
            r_presc <= 7'd0;
            r_cycle <= r_cycle + 32'd1;
         end
         else
            r_presc <= r_presc + 7'd1;
         // tcword write: RW field (bits[5:4]) == 0 is a counter-latch command;
         // otherwise it programs (or stops) cnt2 -> expect a 2-byte counter load.
         if(w_pit_tcword_wr) begin
            if(w_pit_tcword[5:4] == 2'b00) begin
               r_t2_latch    <= w_t2_val;
               r_t2_rd_phase <= 1'b0;
            end
            else begin
               r_t2_loading  <= 1'b1;
               r_t2_wr_phase <= 1'b0;
            end
         end
         // tcnt2 write: low byte then high byte; on the high byte the counter
         // (re)loads and the down-count restarts from the current cycle.
         if(w_pit_tcnt2_wr & r_t2_loading) begin
            if(r_t2_wr_phase == 1'b0) begin
               r_t2_load[7:0] <= w_pit_tcnt2_in;
               r_t2_wr_phase  <= 1'b1;
            end
            else begin
               r_t2_load[15:8] <= w_pit_tcnt2_in;
               r_t2_wr_phase   <= 1'b0;
               r_t2_loading    <= 1'b0;
               r_t2_at         <= r_cycle;
            end
         end
         // tcnt2 read: return latched lo byte then hi byte (toggle each read).
         if(w_pit_tcnt2_rd)
           r_t2_rd_phase <= ~r_t2_rd_phase;
      end
   end

   // ---- i8254 counter 0 -> Timer0 interrupt (INT3 Level2 / CPU IP4) ----
   // Periodic down-counter at the PIT rate (shares r_presc with counter2).
   // Models the Intel 82C54 in Mode 2 (Rate Generator) / Mode 3 (Square Wave):
   // a divide-by-N counter that, at terminal count, emits the interrupt edge and
   // reloads, repeating every N PIT ticks. (Intel 82C54 datasheet, order #23124406:
   // Mode 2 is "typically used to generate a Real Time Clock interrupt.") We model
   // only the interrupt EDGE -- a 1-cycle timer0_irq pulse -- not the OUT duty
   // cycle, and ignore the mode bits (always periodic reload).
   // Programming: the control word (tcword) selects the counter via bits[7:6]
   // (00 = counter0) and the access mode via bits[5:4] (11 = LSB-then-MSB); then
   // the 2-byte count is written LSB then MSB. tcnt0 = IOC byte 0xb3: the 82C54 is
   // an 8-bit part on the low byte lane, so it sits at slot 0xb0 + 3 (mask[3]).
   // NB IP22 Linux/IRIX drive the system tick from CP0 Count/Compare (IP7), not
   // this 8254 IRQ; the 8254 is calibration-only there. Kept as the cleanest
   // testable real INT3 source (tests/pit).
   wire        w_pit_tcnt0_wr = sel & is_store & w_pit & mask[3];
   wire [7:0]  w_pit_tcnt0_in = wdata[8*3 +: 8];

   logic [15:0] r_t0_load, r_t0_count;
   logic        r_t0_wr_phase, r_t0_loading, r_t0_running;
   logic        r_timer0_irq;

   always_ff @(posedge clk) begin
      if(reset) begin
         r_t0_load     <= 16'd0;
         r_t0_count    <= 16'd0;
         r_t0_wr_phase <= 1'b0;
         r_t0_loading  <= 1'b0;
         r_t0_running  <= 1'b0;
         r_timer0_irq  <= 1'b0;
      end
      else begin
         r_timer0_irq <= 1'b0;                       // 1-cycle terminal-count pulse
         // tcword selecting counter0 (SC1:SC0 = 00) arms a 2-byte counter load.
         if(w_pit_tcword_wr & (w_pit_tcword[7:6] == 2'b00)) begin
            r_t0_loading  <= 1'b1;
            r_t0_wr_phase <= 1'b0;
            r_t0_running  <= 1'b0;
         end
         // tcnt0 write: low byte then high byte; on the high byte (re)load + run.
         if(w_pit_tcnt0_wr & r_t0_loading) begin
            if(r_t0_wr_phase == 1'b0) begin
               r_t0_load[7:0] <= w_pit_tcnt0_in;
               r_t0_wr_phase  <= 1'b1;
            end
            else begin
               r_t0_load[15:8] <= w_pit_tcnt0_in;
               r_t0_count      <= {w_pit_tcnt0_in, r_t0_load[7:0]};
               r_t0_wr_phase   <= 1'b0;
               r_t0_loading    <= 1'b0;
               r_t0_running    <= 1'b1;
            end
         end
         // down-count once per PIT tick; terminal count -> pulse + reload (periodic).
         else if(r_t0_running & (r_presc == (PIT_DIV - 1))) begin
            if(r_t0_count <= 16'd1) begin
               r_timer0_irq <= 1'b1;
               r_t0_count   <= r_t0_load;
            end
            else
               r_t0_count <= r_t0_count - 16'd1;
         end
      end
   end
   assign timer0_irq = r_timer0_irq;

   // (IOC2 interrupt/GIO-config registers not yet modeled: reads 0, writes absorbed.)
endmodule // ioc
