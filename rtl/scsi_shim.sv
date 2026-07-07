`include "machine.vh"
// FAITHFUL_SCSI (Stage A): faithful chunked-DMA -- honor a service PAUSE (scsi_status
// 0x48/0x49) at an HPC3 descriptor-chain EOX boundary so IRIX's >252KB transfers
// pause/resume correctly instead of completing early.  Default OFF keeps the working
// one-shot path; uncomment to A/B.  Pairs with per-target {buf,pos} in the ARM/TB.
`define FAITHFUL_SCSI
// -----------------------------------------------------------------------------
// scsi_shim.sv -- WD33C93A + HPC3 SCSI-DMA-channel control shim for the
// ARM/DPI-host-serviced disk path (docs/peripherals/scsi_disk_theory_of_operation.md).
//
// Owns the guest-facing registers the stock IRIX/Linux sgiwd93 driver pokes;
// moves ZERO data bytes.  On a WD33C93 Select-And-Transfer (Command reg 0x18 =
// 0x08/0x09) it snapshots {cdb, dest, lun, xfer_len, nbdp, DIR} into a mailbox
// and bumps a request sequence number (the doorbell).  The service (C++ in
// henry_tb, ARM on the FPGA) walks the descriptor chain in DRAM, does the disk
// I/O, and posts a completion (scsi_rsp_*); the shim then runs the WD33C93
// completion contract (reg 0x0f = target status, count -> 0, phase 0x60) and
// raises INTRQ -> IOC2 local0 bit1 (SCSI0) -> IP2.  Latency-agnostic: it just
// waits for scsi_rsp_seq == the current request seq.
//
// Register/constant layout + the contract: see sim/henry_scsi.h.  MMIO bus:
// device requests are line-aligned (offs = pa & ~0xf within the HPC3 window) with
// a 16-bit byte mask; byte N is wdata[8*N +: 8].  WD33C93 byte ports are NOT
// byte-swapped; the HPC3 32-bit DMA regs ARE (bswap32).
// -----------------------------------------------------------------------------
module scsi_shim
   (input  logic         clk,
    input  logic         reset,
    // ---- guest MMIO (HPC3 window; offs = pa & 0x7ffff, line-aligned + mask) ----
    input  logic         sel,
    input  logic         is_store,
    input  logic [18:0]  offs,
    input  logic [15:0]  mask,
    input  logic [127:0] wdata,
    output logic [127:0] rdata,
    // ---- request mailbox: shim -> service (published on Select-And-Transfer) ----
    output logic [31:0]  scsi_req_seq,       // doorbell: ++ per command
    output logic [31:0]  scsi_req_nbdp,      // HPC3 descriptor-chain head (phys)
    output logic [31:0]  scsi_req_xfer_len,  // WD33C93 24-bit Transfer Count (bytes)
    output logic [127:0] scsi_req_cdb,       // regs[0x03..]; cdb[0]=opcode
    output logic [7:0]   scsi_req_dest,      // target SCSI id
    output logic [7:0]   scsi_req_lun,       // logical unit (low 3 bits)
    output logic         scsi_req_to_device, // DIR: 0=READ(dev->mem) 1=WRITE(mem->dev)
    // ---- completion: service -> shim ----
    input  logic [31:0]  scsi_rsp_seq,       // echoes scsi_req_seq when done
    input  logic [31:0]  scsi_rsp_residual,  // bytes NOT moved; 0 = full xfer
    input  logic [7:0]   scsi_rsp_scsi_status, // -> reg 0x17
    input  logic [7:0]   scsi_rsp_tgt_status,  // -> reg 0x0f (GOOD/CHECK)
    // ---- runtime-programmable select/command -> data-phase delay (AXI reg on FPGA).
    //      0 => the PH_SEL_DELAY default.  Lets us tune the SCSI command latency the
    //      host needs WITHOUT a re-synth (was a hardcoded localparam). ----
    input  logic [15:0]  sel_delay,
    // ---- scsi_dma engine (lower-level data mover; gated/connected by henry_soc) ----
    // The WD33C93 phase SM pulses dma_go at the DATA phase, so the engine's
    // descriptor read goes through the arbiter AFTER the driver's post-command
    // flush -- read-after-write ordered by construction (no host-service backdoor).
    output logic         dma_go,             // 1-cycle pulse at the SCSI data phase
    output logic [31:0]  dma_nbdp,           // descriptor-chain head (phys)
    output logic         dma_to_device,      // DIR: 1 = WRITE (mem->disk)
    input  logic         dma_done,           // engine finished the chain
    input  logic         dma_rd_stalled,     // engine blocked waiting for a disk beat (no more data)
    output logic         dma_abort,          // cancel the engine (short/no-data/selection timeout)
    // ---- interrupt ----
    output logic         scsi_intrq,         // -> IOC2 local0 bit1 (SCSI0)
    // ---- silicon debug visibility (read back via an AXI PMU slot): proves the
    //      WD33C93 accesses actually reach the shim + exposes the reset->INTRQ
    //      state.  Pure observability; saturating event counters + live regs. ----
    output logic [31:0]  dbg);

   // ---- WD33C93 phase progression: SEL_ATN_XFER -> select/command -> DATA -----
   // Coarse model of the SCSI bus phases.  The DATA phase opens PH_SEL_DELAY
   // cycles after the command (the select/message/command bus time), which is
   // when the real HPC3 reads the descriptor -- by then the driver's post-command
   // dma_cache_wback has been issued, and the engine's read (an ordered DRAM
   // agent) serializes after it at the single DRAM port.  The delay only has to
   // clear the driver's flush ISSUE, not the writeback drain (the arbiter orders
   // the rest); it is modeling real bus latency, not papering over a race.
   localparam [1:0]  PH_IDLE=2'd0, PH_DELAY=2'd1, PH_GO=2'd2, PH_BUSY=2'd3;
   localparam [15:0] PH_SEL_DELAY = 16'd8192;   // select/cmd bus time; clears the driver's flush issue
   logic [1:0]  r_ph, n_ph;
   logic [15:0] r_ph_cnt, n_ph_cnt;

   // WD33C93 indirect register indices (the ones modeled)
   localparam [4:0] WD_OWN_ID=5'h00, WD_CONTROL=5'h01, WD_TARGET_LUN=5'h0f,
                    WD_CMD_PHASE=5'h10, WD_XFER_MSB=5'h12, WD_XFER_MID=5'h13,
                    WD_XFER_LSB=5'h14, WD_DEST_ID=5'h15, WD_SCSI_STATUS=5'h17,
                    WD_COMMAND=5'h18;
   // WD33C93 command (low 7 bits of reg 0x18) + completion codes
   localparam [6:0] CMD_RESET=7'h00, CMD_SEL_ATN_XFER=7'h08, CMD_SEL_XFER=7'h09;
   localparam [7:0] CMD_PHASE_COMPLETE=8'h60;
   // Aux Status bits (returned by a read of the SASR port)
   localparam [7:0] AUX_DBR=8'h01, AUX_CIP=8'h10, AUX_BSY=8'h20, AUX_INT=8'h80;

   // ---- guest-written register state ----
   logic [4:0]  r_sasr;
   logic [7:0]  r_own_id, r_control;
   logic [95:0] r_cdb;             // bytes for indices 0x03..0x0e
   logic [7:0]  r_target_lun;      // guest LUN; OVERWRITTEN with target status at completion
   logic [7:0]  r_cmd_phase, r_scsi_status, r_dest_id;
   logic [23:0] r_xfer_cnt;
   logic        r_cip, r_bsy, r_intrq;
   // ---- HPC3 SCSI DMA channel (HD0) ----
   logic [31:0] r_cbp, r_nbdp, r_bc;
   logic [7:0]  r_ctrl;
   logic        r_chan_irq;        // HPC3 per-channel IRQ (XIE), surfaced in ctrl bit0
   // ---- silicon debug event counters (saturating) -> dbg ----
   logic [5:0]  r_cnt_sasr, r_cnt_scmd, r_cnt_rd;   // SASR writes / SCMD writes / SASR-port reads
   logic [3:0]  r_cnt_reset;                        // CMD_RESETs seen
   // ---- request mailbox (latched at the doorbell) + completion bookkeeping ----
   logic [31:0]  r_req_seq, r_done_seq;
   logic [127:0] r_req_cdb;
   logic [31:0]  r_req_nbdp, r_req_xfer;
   logic [7:0]   r_req_dest, r_req_lun;
   logic         r_req_dir;

   // ---- MMIO decode (line-aligned offs + byte mask) ----
   // WD33C93 decodes across the WHOLE HD0 device region 0x40000..0x47fff (SGI
   // hpc3.pdf: HD0 device regs = 0x1fbc0000..0x1fbc7fff; the chip hd0.cs is the
   // 0x1fbc4000 sub-window but the 32KB region aliases it -- MAME map(0x40000,
   // 0x47fff)). IRIX accesses it at 0x40003/0x40007, Linux at 0x44003/0x44007
   // (its scsi0_ext = hd0.cs @ offset 0x44000); BOTH are valid. The old decode
   // matched only the exact line 0x40000 -> worked for IRIX, MISSED Linux. Match
   // the region. SASR=byte3, SCMD=byte7 (== interp_mips port=((offs-0x40000)>>2)&1).
   wire w_wd_line = sel & ((offs & 19'h78000) == 19'h40000);
   wire w_sasr_wr = w_wd_line &  is_store & mask[3];
   wire w_scmd_wr = w_wd_line &  is_store & mask[7];
   wire w_sasr_rd = w_wd_line & ~is_store & mask[3];
   wire w_scmd_rd = w_wd_line & ~is_store & mask[7];
   wire [7:0] w_scmd_wval = wdata[63:56];               // SCMD = byte 7

   wire w_dma_lo  = sel & (offs == 19'h10000);          // cbp(word0) / nbdp(word1)
   wire w_dma_hi  = sel & (offs == 19'h11000);          // bc(word0) / ctrl(word1)
   wire w_cbp_wr  = w_dma_lo &  is_store & (mask[3:0]  == 4'hf);
   wire w_nbdp_wr = w_dma_lo &  is_store & (mask[7:4]  == 4'hf);
   wire w_bc_wr   = w_dma_hi &  is_store & (mask[3:0]  == 4'hf);
   wire w_ctrl_wr = w_dma_hi &  is_store & (mask[7:4]  == 4'hf);
   wire w_ctrl_rd = w_dma_hi & ~is_store & (mask[7:4]  == 4'hf);

   // Select-And-Transfer = the doorbell; completion = the service echoing our seq.
   wire w_cmd_seltx  = w_scmd_wr & (r_sasr == WD_COMMAND) &
                       (((w_scmd_wval & 7'h7f) == CMD_SEL_ATN_XFER) |
                        ((w_scmd_wval & 7'h7f) == CMD_SEL_XFER));
   wire w_cmd_reset  = w_scmd_wr & (r_sasr == WD_COMMAND) & ((w_scmd_wval & 7'h7f) == CMD_RESET);
   // Completion waits for the phase SM to return to PH_IDLE -- i.e. the scsi_dma
   // engine has finished moving the data (or the selection-timeout skip) -- so the
   // driver never sees command-complete before the ordered DMA has landed.
   wire w_complete   = (r_req_seq != r_done_seq) & (scsi_rsp_seq == r_req_seq) & (r_ph == PH_IDLE);

   always_ff @(posedge clk) begin
      if(reset) begin
         r_sasr <= 5'd0; r_own_id <= 8'd0; r_control <= 8'd0; r_cdb <= 96'd0;
         r_target_lun <= 8'd0; r_cmd_phase <= 8'd0; r_scsi_status <= 8'd0;
         r_dest_id <= 8'd0; r_xfer_cnt <= 24'd0;
         r_cip <= 1'b0; r_bsy <= 1'b0; r_intrq <= 1'b0;
         r_cbp <= 32'd0; r_nbdp <= 32'd0; r_bc <= 32'd0; r_ctrl <= 8'd0; r_chan_irq <= 1'b0;
         r_req_seq <= 32'd0; r_done_seq <= 32'd0; r_req_cdb <= 128'd0;
         r_req_nbdp <= 32'd0; r_req_xfer <= 32'd0; r_req_dest <= 8'd0;
         r_req_lun <= 8'd0; r_req_dir <= 1'b0;
         r_cnt_sasr <= 6'd0; r_cnt_scmd <= 6'd0; r_cnt_rd <= 6'd0; r_cnt_reset <= 4'd0;
      end
      else begin
         // ---- WD33C93 SASR/SCMD port (one access per cycle) ----
         if(w_sasr_wr) begin
            r_sasr <= wdata[28:24];                      // byte3 & 0x1f
         end
         else if(w_scmd_wr) begin
            if(r_sasr == WD_COMMAND) begin
               // Command register: execute, no auto-increment.
               if(w_cmd_seltx) begin                     // Select-And-Transfer -> doorbell
                  r_req_seq  <= r_req_seq + 32'd1;
                  r_req_cdb  <= {32'd0, r_cdb};
                  r_req_nbdp <= r_nbdp;
                  r_req_xfer <= {8'd0, r_xfer_cnt};
                  r_req_dest <= r_dest_id;
                  r_req_lun  <= {5'd0, r_target_lun[2:0]};
                  r_req_dir  <= r_ctrl[2];               // HPC3 ctrl DIR (1 = WRITE)
                  r_cip <= 1'b1; r_bsy <= 1'b1;
               end
               else if(w_cmd_reset) begin
                  // WD33C93 RESET: post SCSI Status = 0x00 (ST_RESET) and raise
                  // INTRQ -- the driver waits for it ("wd93 ... reset correctly").
                  r_scsi_status <= 8'h00;
                  r_intrq <= 1'b1; r_cip <= 1'b0; r_bsy <= 1'b0;
               end
            end
            else begin
               // Data write to the selected register, then auto-increment SASR.
               case(r_sasr)
                 WD_OWN_ID:      r_own_id      <= w_scmd_wval;
                 WD_CONTROL:     r_control     <= w_scmd_wval;
                 WD_TARGET_LUN:  r_target_lun  <= w_scmd_wval;
                 WD_CMD_PHASE:   r_cmd_phase   <= w_scmd_wval;
                 WD_XFER_MSB:    r_xfer_cnt[23:16] <= w_scmd_wval;
                 WD_XFER_MID:    r_xfer_cnt[15:8]  <= w_scmd_wval;
                 WD_XFER_LSB:    r_xfer_cnt[7:0]   <= w_scmd_wval;
                 WD_DEST_ID:     r_dest_id     <= w_scmd_wval;
                 WD_SCSI_STATUS: r_scsi_status <= w_scmd_wval;
                 default:
                   if((r_sasr >= 5'h03) && (r_sasr <= 5'h0e))   // CDB bytes 0x03..0x0e
                     r_cdb[(r_sasr - 5'h03)*8 +: 8] <= w_scmd_wval;
               endcase
               r_sasr <= (r_sasr + 5'd1) & 5'h1f;
            end
         end
         else if(w_scmd_rd) begin
            if(r_sasr == WD_SCSI_STATUS) r_intrq <= 1'b0;   // reading SCSI Status clears INTRQ
            r_sasr <= (r_sasr + 5'd1) & 5'h1f;
         end

         // ---- silicon debug counters (independent of the access chain above) ----
         if(w_sasr_wr   & (r_cnt_sasr  != 6'h3f)) r_cnt_sasr  <= r_cnt_sasr  + 6'd1;
         if(w_scmd_wr   & (r_cnt_scmd  != 6'h3f)) r_cnt_scmd  <= r_cnt_scmd  + 6'd1;
         if(w_sasr_rd   & (r_cnt_rd    != 6'h3f)) r_cnt_rd    <= r_cnt_rd    + 6'd1;
         if(w_cmd_reset & (r_cnt_reset != 4'hf )) r_cnt_reset <= r_cnt_reset + 4'd1;

`ifdef VERILATOR
         // sim-only trace of the WD33C93 control plane (grep the console log)
         if(sel & ((offs & 19'h78000) == 19'h40000))
           $display("[shim] offs=%05x st=%b mask=%04x b3=%02x b7=%02x r_sasr=%02x",
                    offs, is_store, mask, wdata[31:24], wdata[63:56], r_sasr);
         if(w_cmd_reset)  $display("[shim] CMD RESET  -> status=00 intrq=1");
         if(w_cmd_seltx)  $display("[shim] CMD SELTX  cdb0=%02x dest=%02x", r_cdb[7:0], r_dest_id);
         if(w_sasr_rd)    $display("[shim] SASR_RD aux=%02x (intrq=%b)", w_aux, r_intrq);
         if(w_nbdp_wr) $display("[hpc3] NBDP <= %08x", bswap32(wdata[63:32]));
         if(w_cbp_wr)  $display("[hpc3] CBP  <= %08x", bswap32(wdata[31:0]));
         if(w_bc_wr)   $display("[hpc3] BC   <= %08x", bswap32(wdata[31:0]));
         if(w_ctrl_wr) $display("[hpc3] CTRL <= %08x (ACTIVE=%b)", bswap32(wdata[63:32]) & 32'hff,
                                (bswap32(wdata[63:32]) & 32'h10) != 0);
`endif
         // ---- HPC3 SCSI DMA channel registers (byte-swapped) ----
         if(w_cbp_wr)  r_cbp  <= bswap32(wdata[31:0]);
         if(w_nbdp_wr) r_nbdp <= bswap32(wdata[63:32]);
         if(w_bc_wr)   r_bc   <= bswap32(wdata[31:0]);
         if(w_ctrl_wr) r_ctrl <= bswap32(wdata[63:32]) & 32'hff;   // ACTIVE/DIR/FLUSH/...
         if(w_ctrl_rd) r_chan_irq <= 1'b0;                          // reading ctrl clears chan IRQ

         // ---- completion (service posted scsi_rsp_*); wins ties on r_intrq ----
         if(w_complete) begin
            r_scsi_status <= scsi_rsp_scsi_status;
            r_cip <= 1'b0; r_bsy <= 1'b0; r_intrq <= 1'b1;
            r_done_seq <= r_req_seq;
            r_ctrl <= r_ctrl & ~8'h10;                // DMA done: clear HPC3 ctrl ACTIVE
`ifdef FAITHFUL_SCSI
            // Stage-A chunked DMA: the service posts scsi_status 0x48 (data-out) /
            // 0x49 (data-in) to signal a CHUNK PAUSE -- the HPC3 chain EOX'd before the
            // SCSI command's full length.  Raise INTRQ with transfer-count-exhausted
            // phase (0x46) but do NOT mark command-complete (0x60): the guest reprograms
            // the DMA + re-issues SEL_ATN_XFER and the service resumes from pos.
            // (interp_mips pause_transfer()).  No target-status/chan-IRQ update.
            if((scsi_rsp_scsi_status == 8'h48) || (scsi_rsp_scsi_status == 8'h49)) begin
               r_cmd_phase <= 8'h46;                  // transfer count exhausted (chunked)
               r_xfer_cnt  <= 24'd0;                  // WD33C93 count counted down to 0
            end
            else
`endif
            if(scsi_rsp_scsi_status != 8'h42) begin   // NORMAL completion (not selection timeout)
               r_target_lun <= scsi_rsp_tgt_status;   // reg 0x0f = target status (GOOD/CHECK)
               r_cmd_phase  <= CMD_PHASE_COMPLETE;    // 0x60 command-complete
               r_xfer_cnt   <= scsi_rsp_residual[23:0];
               if(r_bc[29]) r_chan_irq <= 1'b1;       // XIE -> HPC3 channel IRQ
            end
            // selection timeout (0x42): status + INTRQ only -- do NOT mark command
            // complete (phase 0x60) or it reads as "completed w/ timeout" -> bus reset.
         end
      end
   end

   // ---- read path ----
   wire [7:0] w_aux  = (r_intrq ? AUX_INT : 8'd0) | (r_bsy ? AUX_BSY : 8'd0) |
                       (r_cip ? AUX_CIP : 8'd0);      // DBR(DRQ) unused: host-served, no PIO data
   logic [7:0] t_scmd;
   always_comb begin
      case(r_sasr)
        WD_OWN_ID:      t_scmd = r_own_id;
        WD_CONTROL:     t_scmd = r_control;
        WD_TARGET_LUN:  t_scmd = r_target_lun;
        WD_CMD_PHASE:   t_scmd = r_cmd_phase;
        WD_XFER_MSB:    t_scmd = r_xfer_cnt[23:16];
        WD_XFER_MID:    t_scmd = r_xfer_cnt[15:8];
        WD_XFER_LSB:    t_scmd = r_xfer_cnt[7:0];
        WD_DEST_ID:     t_scmd = r_dest_id;
        WD_SCSI_STATUS: t_scmd = r_scsi_status;
        default:        t_scmd = ((r_sasr >= 5'h03) && (r_sasr <= 5'h0e))
                                 ? r_cdb[(r_sasr - 5'h03)*8 +: 8] : 8'd0;
      endcase
   end

   always_comb begin
      rdata = 128'd0;
      if(w_sasr_rd) rdata[31:24]  = w_aux;                         // SASR port = Aux Status
      if(w_scmd_rd) rdata[63:56]  = t_scmd;                        // SCMD port = regs[sasr]
      if(w_dma_lo & ~is_store & (mask[3:0] == 4'hf)) rdata[31:0]  = bswap32(r_cbp);
      if(w_dma_lo & ~is_store & (mask[7:4] == 4'hf)) rdata[63:32] = bswap32(r_nbdp);
      if(w_dma_hi & ~is_store & (mask[3:0] == 4'hf)) rdata[31:0]  = bswap32(r_bc);
      if(w_ctrl_rd) rdata[63:32] = bswap32({24'd0, r_ctrl} | (r_chan_irq ? 32'd1 : 32'd0));
   end

   // ---- request mailbox outputs (stable from doorbell to next doorbell) ----
   assign scsi_req_seq       = r_req_seq;
   assign scsi_req_nbdp      = r_req_nbdp;
   assign scsi_req_xfer_len  = r_req_xfer;
   assign scsi_req_cdb       = r_req_cdb;
   assign scsi_req_dest      = r_req_dest;
   assign scsi_req_lun       = r_req_lun;
   assign scsi_req_to_device = r_req_dir;
   assign scsi_intrq         = r_intrq;
   // dbg layout: [31:28]=#resets [27:22]=#SASR-reads [21:16]=#SCMD-wr [15:10]=#SASR-wr
   //             [9:8]=phase [7]=CIP [6]=BSY [5]=INTRQ [4:0]=SASR pointer
   assign dbg = {r_cnt_reset, r_cnt_rd, r_cnt_scmd, r_cnt_sasr,
                 r_ph, r_cip, r_bsy, r_intrq, r_sasr};

   // ---- phase SM: SEL_ATN_XFER -> select/cmd delay -> pulse dma_go at DATA ----
   always_comb begin
      n_ph     = r_ph;
      n_ph_cnt = r_ph_cnt;
      dma_go        = 1'b0;
      dma_abort     = 1'b0;
      dma_nbdp      = r_nbdp;
      dma_to_device = r_ctrl[2];          // HPC3 ctrl DIR (1 = WRITE: mem->disk)
      case(r_ph)
        PH_IDLE:
          if(w_cmd_seltx) begin n_ph = PH_DELAY;
             n_ph_cnt = (sel_delay == 16'd0) ? PH_SEL_DELAY : sel_delay; end
        PH_DELAY: begin
           n_ph_cnt = r_ph_cnt - 16'd1;
           if(r_ph_cnt == 16'd0) n_ph = PH_GO;
        end
        PH_GO:
          if(r_ctrl[4]) begin dma_go = 1'b1; n_ph = PH_BUSY; end  // ACTIVE -> START the engine
          else          n_ph = PH_IDLE;                            // no DMA (selection timeout)
        PH_BUSY:
          // The scsi_dma engine -- the ONLY agent that touches MIPS memory -- walks
          // the descriptor + drains the ARM-fed beat FIFO into mem[BP], then pulses
          // dma_done, so completion (INTRQ) can't fire before the data has landed.
          // But the engine only finishes if it gets all its beats.  When the ARM has
          // finished servicing (rsp_seq echoed) yet the engine is still blocked for a
          // beat (dma_rd_stalled) -> no more data is coming: a short / no-data / unknown
          // -opcode / selection-timeout transfer.  Cancel the engine (dma_abort) and
          // complete with whatever landed (real SCSI short-transfer + residual), rather
          // than hang forever polling CIP/BSY.
          if(dma_done) n_ph = PH_IDLE;
          else if((scsi_rsp_seq == r_req_seq) & dma_rd_stalled) begin
             dma_abort = 1'b1;
             n_ph      = PH_IDLE;
          end
        default: n_ph = PH_IDLE;
      endcase
   end

   always_ff @(posedge clk)
     if(reset) begin r_ph <= PH_IDLE; r_ph_cnt <= 16'd0; end
     else      begin r_ph <= n_ph;    r_ph_cnt <= n_ph_cnt; end
endmodule // scsi_shim
