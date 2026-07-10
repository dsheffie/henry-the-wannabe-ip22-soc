/* scsi_arm.h -- ARM (PS) side SCSI disk service for the henry SoC FPGA.
 *
 * This is the on-board twin of henry_tb's SCSI model: it runs on the Zynq PS
 * (the axilite-mips driver), polls the scsi_shim doorbell over AXI-lite, walks
 * the HPC3 {BP,BC,DP} descriptor chain in the shared DRAM mmap, and does the
 * disk I/O straight into the guest's buffers -- the SAME contract validated in
 * Verilator (see sim/scsi_service.h, sim/henry_scsi.h, sim/henry_tb.cpp).
 *
 * INTEGRATION (on the board, ~/axilite-mips):
 *   1. Copy this file + scsi_service.h + henry_scsi.h into the driver dir.
 *   2. In axi.cc:  #include "scsi_arm.h"
 *      Once, after the Driver + DRAM mmap are up and the core is running:
 *          static scsi_disk g_disk;  g_disk.open_image("irix65.img");
 *      Each iteration of the main poll loop:
 *          scsi_arm_poll(d, &g_disk, c_addr);
 *      NB: pass the DRAM mmap base (axi.cc's `c_addr` = mmap(phys_addr,memsize)),
 *      NOT d->get_vaddr() -- get_vaddr() is the AXI control-register window.
 *   3. The shim's select->data delay is an AXI reg now -- tune without re-synth:
 *          d->write32(SCSI_W_SELDELAY, 0);   // 0 => shim default (8192)
 *
 * AXI register map -- MUST match ip_hdl/axi_is_the_worst_v1_0_S00_AXI.v:
 *   reads : 0x30 req_seq(doorbell) 0x31-0x33 CDB[0..11] 0x34 nbdp
 *           0x35 {to_device[16], lun[15:8], dest[7:0]}
 *   writes: 0x0D rsp_seq  0x0F rsp_residual  0x10 {tgt_status[15:8],scsi_status[7:0]}
 *           0x11 sel_delay
 */
#ifndef SCSI_ARM_H
#define SCSI_ARM_H

#include "driver.hh"        // Driver: read32(port) / write32(port,val) / get_vaddr()
#include "scsi_service.h"   // scsi_disk, scsi_move, scsi_service_run  (+ henry_scsi.h)
#include <cstdint>
#include <vector>
#include <cstdio>          // CDB logging (IRIX root-mount debug)

enum {
  SCSI_R_SEQ      = 0x30, SCSI_R_CDB0 = 0x31, SCSI_R_CDB1 = 0x32, SCSI_R_CDB2 = 0x33,
  SCSI_R_NBDP     = 0x34, SCSI_R_TLD  = 0x35,
  SCSI_R_DBG      = 0x38,   // shim debug viz: [31:28]=#resets [27:22]=#SASR-rd [21:16]=#SCMD-wr
                            //   [15:10]=#SASR-wr [9:8]=phase [7]=CIP [6]=BSY [5]=INTRQ [4:0]=SASR
  SCSI_R_RTLREV   = 0x3F,   // hand-bumped RTL build revision (0xYYYYMMDD) -- verify the bitstream is current
  SCSI_W_RSP_SEQ  = 0x0D, SCSI_W_RESID = 0x0F, SCSI_W_STATUS = 0x10, SCSI_W_SELDELAY = 0x11,
};

/* FPGA AXI DRAM address map -- MUST match henry_tb fpga_map / the M00_AXI fold.
 * A guest physical address (descriptor BP/DP, the chain head NBDP) maps to a
 * DRAM-window offset, then to the host pointer get_vaddr()+offset. */
static const uint64_t SCSI_DRAM_WINDOW = 0x20000000ull;   /* 512 MB */
static const uint32_t SCSI_FPGA_ADDRMASK = 0x1fffffffu;
static inline uint32_t scsi_fpga_map(uint32_t cpuaddr, bool *bad) {
  uint32_t t;
  if(cpuaddr >= 0x08000000u && cpuaddr <= 0x17ffffffu)
    t = cpuaddr & 0x0fffffffu;                  /* 256 MB Low Local Mem */
  else if(cpuaddr >= 0x1f000000u && cpuaddr <= 0x1fffffffu)
    t = 0x10000000u | (cpuaddr & 0x00ffffffu);  /* 16 MB device/PROM shadow */
  else
    t = cpuaddr;                                /* identity */
  *bad = (t > SCSI_FPGA_ADDRMASK);
  return t;
}

/* scsi_move() mem callback: guest PA -> host pointer.  ctx = DRAM mmap base. */
static inline uint8_t *scsi_arm_mem(void *ctx, uint32_t phys, uint32_t len) {
  bool bad = false;
  uint32_t off = scsi_fpga_map(phys, &bad);
  if(bad || (uint64_t)off + len > SCSI_DRAM_WINDOW) return nullptr;
  return reinterpret_cast<uint8_t*>(ctx) + off;
}

/* Poll the doorbell once; on a new command, service it end-to-end.  Call every
 * iteration of the driver's main loop.  Returns true iff a command was serviced.
 *
 * `dram` MUST be the DRAM mmap base (axi.cc `c_addr`), not the control-reg window.
 *
 * Ordering (matches the validated sim contract): the PS reads the request AFTER
 * the doorbell, so the guest's descriptor/buffer cache-writebacks have drained
 * to DRAM by the time we read them (the ARM's poll latency is the real-HW analog
 * of henry_tb's SVC_DELAY).  We deposit the data into DRAM, issue a full memory
 * barrier, and only then echo the doorbell -- so IRIX (which already did its
 * pre-DMA dma_cache_inv) reads the fresh data after completion. */
static inline bool scsi_arm_poll(Driver *d, scsi_disk *disk, uint8_t *dram) {
  static uint32_t last_seq = 0;
  uint32_t seq = d->read32(SCSI_R_SEQ);
  if(seq == last_seq) return false;
  last_seq = seq;

  // No root disk attached: answer every command as selection-timeout ("no device")
  // so a disk-less guest (e.g. Linux from initramfs) COMPLETES its SCSI scan instead
  // of hanging -- the shim now waits on this reply (the self-completing engine is gone).
  if(!disk->ok()) {
    d->write32(SCSI_W_RESID,  0);
    d->write32(SCSI_W_STATUS, ST_SELECTION_TIMEOUT);   // scsi_status=0x42, tgt_status=0
    d->write32(SCSI_W_RSP_SEQ, seq);                   // echo doorbell LAST
    return true;
  }

  scsi_req_t req;
  req.seq     = seq;
  req.channel = CH_SCSI0;
  ((uint32_t*)req.cdb)[0] = d->read32(SCSI_R_CDB0);
  ((uint32_t*)req.cdb)[1] = d->read32(SCSI_R_CDB1);
  ((uint32_t*)req.cdb)[2] = d->read32(SCSI_R_CDB2);
  ((uint32_t*)req.cdb)[3] = 0;                 /* only 12 CDB bytes exposed (>= READ10) */
  req.nbdp = d->read32(SCSI_R_NBDP);
  uint32_t tld = d->read32(SCSI_R_TLD);
  req.dest = tld & 0xff; req.lun = (tld >> 8) & 0xff; req.to_device = (tld >> 16) & 1;
  req.xfer_len = 0;

  /* --- Chunked-DMA resume-from-pos (Option A) ---------------------------------
   * IRIX arms the HPC3 DMA chain for FEWER bytes than the full SCSI command's
   * length, then re-issues SEL_ATN_XFER for each subsequent chunk (interp_mips
   * select_and_transfer/pause_transfer).  We carry {buf,pos,total} across
   * doorbells: a doorbell arriving mid-transfer (g_active && g_pos<g_total) is a
   * RESUME of the same command -- reuse the already-read buf, scsi_move only the
   * NEXT chunk into the fresh chain at req.nbdp, and if data remains post a chunk
   * PAUSE (scsi_status 0x49 data-in / 0x48 data-out).  The shim's FAITHFUL_SCSI
   * path then raises INTRQ with phase 0x46 (count exhausted) but NOT command-
   * complete, so IRIX reprograms the DMA + resumes.  Mirrors the henry_tb.cpp
   * beat-engine path; single-chunk commands (Linux, control) still complete in
   * one pass (g_pos reaches g_total immediately), so that path is unchanged. */
  static std::vector<uint8_t> g_buf;
  static size_t   g_pos = 0, g_total = 0;
  static bool     g_active = false, g_to_dev = false;
  static uint64_t g_wr_lba = 0;

  scsi_rsp_t rsp;
  bool resume = g_active && g_pos < g_total;      /* mid-transfer doorbell = resume */
  if(!resume) {                                   /* NEW command: decode + read disk */
    g_buf.clear();
    scsi_service_run(&req, &rsp, disk, g_buf, g_to_dev, g_wr_lba);
    g_total = g_buf.size(); g_pos = 0;
    g_active = (rsp.scsi_status == ST_SELECT_TRANSFER_SUCCESS) && !g_buf.empty();
  } else {                                        /* RESUME: same buf, fresh chain */
    rsp.scsi_status = ST_SELECT_TRANSFER_SUCCESS; rsp.tgt_status = TGT_GOOD;
  }
  rsp.seq = seq; rsp.residual = 0;

  uint32_t moved = 0;
  if(g_active) {
    moved = scsi_move(scsi_arm_mem, dram, req.nbdp,
                      g_buf.data() + g_pos, (uint32_t)(g_total - g_pos), g_to_dev);
    if(g_to_dev) {                                /* WRITE: commit this chunk's blocks */
      size_t base = g_pos / 512, nb = moved / 512;
      for(size_t b = 0; b < nb; b++)
        disk->block_write(g_wr_lba + base + b, g_buf.data() + g_pos + b * 512);
    }
    g_pos += moved;
    if(g_pos < g_total) rsp.scsi_status = g_to_dev ? 0x48 : 0x49;  /* CHUNK PAUSE */
    else                g_active = false;                          /* whole command done */
  }

  /* IRIX root-mount debug: log every serviced SCSI command + its outcome. */
  fprintf(stderr, "[cdb] seq=%u %s op=0x%02x cdb=%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x "
                  "dest=%u lun=%u to_dev=%d wr_lba=%llu status=0x%02x tgt=0x%02x "
                  "pos=%zu/%zu moved=%u nbdp=0x%08x\n",
          req.seq, resume ? "RESUME" : "NEW", (unsigned)req.cdb[0],
          (unsigned)req.cdb[0],(unsigned)req.cdb[1],(unsigned)req.cdb[2],(unsigned)req.cdb[3],
          (unsigned)req.cdb[4],(unsigned)req.cdb[5],(unsigned)req.cdb[6],(unsigned)req.cdb[7],
          (unsigned)req.cdb[8],(unsigned)req.cdb[9],
          (unsigned)req.dest, (unsigned)req.lun, (int)g_to_dev, (unsigned long long)g_wr_lba,
          (unsigned)rsp.scsi_status, (unsigned)rsp.tgt_status,
          g_pos, g_total, (unsigned)moved, req.nbdp);
  fflush(stderr);

  __sync_synchronize();                         /* DRAM writes visible before completion */
  d->write32(SCSI_W_RESID,   rsp.residual);
  d->write32(SCSI_W_STATUS,  ((uint32_t)rsp.tgt_status << 8) | rsp.scsi_status);
  d->write32(SCSI_W_RSP_SEQ, rsp.seq);          /* doorbell echo LAST -> shim completes */
  return true;
}

#endif /* SCSI_ARM_H */
