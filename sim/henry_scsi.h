/* henry_scsi.h -- contract between the host-served-DMA shim (RTL) and the disk
 * service (C++ in henry_tb, ARM on the FPGA).  Constants traced from the
 * validated interp_mips model (sgi_scsi.cc / sgi_hpc.cc).
 *
 * The shim owns the WD33C93 + HPC3 register files (guest MMIO) and moves zero
 * data bytes.  On a Select-And-Transfer it publishes a request + bumps a doorbell
 * sequence number; the service walks the {BP,BC,DP} descriptor chain in DRAM,
 * does the disk I/O straight into DRAM, and posts a completion.  Identical in sim
 * and on silicon -- only the mailbox transport differs (TB ports vs AXI-lite
 * slv_regs); descriptors and data buffers live in DRAM.
 *
 * ENDIANNESS: the guest is MIPS big-endian.  HPC3 descriptor words in DRAM are
 * BIG-ENDIAN (use be32() below).  The SCSI data buffers are byte streams (copy
 * raw).  Mailbox fields are logical values (the transport handles any bus swap).
 *
 * CHANNEL / ENET SEAM: this is really a generic "host-serviced HPC3 DMA channel".
 * SCSI uses channel CH_SCSI0; Ethernet would add CH_ENET_TX (maps cleanly, like a
 * SCSI write) and CH_ENET_RX (unsolicited -- needs a service-initiated completion,
 * i.e. the service free-runs rsp.seq after a one-time arm; see scsi_rsp_t.seq).
 * The descriptor-walk + deposit in the service is the reusable part; only the
 * per-device register shim (WD33C93 vs Seeq) and the RX reverse-doorbell differ.
 */
#ifndef HENRY_SCSI_H
#define HENRY_SCSI_H
#include <stdint.h>

#define SCSI_DISK_TARGET   1u    /* the one real disk: target 1, LUN 0 */

/* Host-DMA channel ids (seam). Only CH_SCSI0 exists today. */
enum host_dma_channel {
    CH_SCSI0   = 0,
    CH_SCSI1   = 1,   /* 2nd WD33C93 disk channel (HD1)            */
    CH_ENET_TX = 2,   /* future: Seeq transmit  (guest-initiated)  */
    CH_ENET_RX = 3,   /* future: Seeq receive   (service-initiated) */
};

/* ---- HPC3 scatter-gather descriptor: 3 BIG-ENDIAN words at nbdp in DRAM ---- */
typedef struct {
    uint32_t bp;   /* buffer pointer  -- physical DRAM addr of the data buffer */
    uint32_t bc;   /* byte-count word -- count[13:0] | flags                   */
    uint32_t dp;   /* next-descriptor pointer (physical); follow until EOX      */
} hpc3_desc_t;     /* stored BIG-ENDIAN -- read with be32()                     */
enum {
    HPC3_BC_COUNT = 0x00003fffu,  /* bytes this descriptor (<= 16 KB)          */
    HPC3_BC_XIE   = 0x20000000u,  /* raise channel IRQ at this desc completion */
    HPC3_BC_EOX   = 0x80000000u,  /* End Of Xfer: last descriptor              */
};
static inline uint32_t hdma_be32(const uint8_t *p)   /* DRAM BE word -> host value */
{ return ((uint32_t)p[0]<<24)|((uint32_t)p[1]<<16)|((uint32_t)p[2]<<8)|p[3]; }

/* ---- SCSI command set (every opcode an IRIX boot issues; IRIX_SCSI_PROFILE.md) ---- */
enum {
    SCSI_TEST_UNIT_READY = 0x00, SCSI_REQUEST_SENSE = 0x03, SCSI_INQUIRY = 0x12,
    SCSI_MODE_SELECT6    = 0x15, SCSI_MODE_SENSE6   = 0x1a, SCSI_START_STOP = 0x1b,
    SCSI_READ_CAPACITY10 = 0x25, SCSI_READ10        = 0x28, SCSI_WRITE10    = 0x2a,
};
static inline uint32_t cdb10_lba(const uint8_t *c)
{ return ((uint32_t)c[2]<<24)|((uint32_t)c[3]<<16)|((uint32_t)c[4]<<8)|c[5]; }
static inline uint32_t cdb10_blocks(const uint8_t *c)
{ return ((uint32_t)c[7]<<8)|c[8]; }

/* ---- WD33C93 completion codes (what the shim latches; the service supplies) ---- */
enum {  /* reg 0x17 SCSI Status */
    ST_SELECT_TRANSFER_SUCCESS = 0x16,   /* normal completion          */
    ST_SELECTION_TIMEOUT       = 0x42,   /* absent target              */
};
enum {  /* reg 0x0f target status */
    TGT_GOOD            = 0x00,
    TGT_CHECK_CONDITION = 0x02,
};

/* ---- REQUEST: shim -> service, published on the Select-And-Transfer doorbell ---- */
typedef struct {
    uint32_t seq;        /* doorbell: ++ per command; service acts on a change    */
    uint8_t  channel;    /* host_dma_channel (CH_SCSI0 today)                     */
    uint32_t nbdp;       /* HPC3 descriptor-chain head (physical DRAM addr)       */
    uint32_t xfer_len;   /* WD33C93 24-bit Transfer Count (bytes) the guest set   */
    uint8_t  cdb[16];    /* regs[0x03..]; service decodes op/lba/len from here     */
    uint8_t  dest;       /* target SCSI id (real disk = 1)                        */
    uint8_t  lun;        /* logical unit (real disk = 0)                          */
    uint8_t  to_device;  /* DIR: 0 = READ (dev->mem), 1 = WRITE (mem->dev)        */
} scsi_req_t;

/* ---- COMPLETION: service -> shim. Shim latches into the WD33C93 regs + INTRQ ---- */
typedef struct {
    uint32_t seq;         /* echoes scsi_req_t.seq (or free-runs for RX, see seam) */
    uint32_t residual;    /* bytes NOT moved; MUST be 0 on success (short-xfer!)   */
    uint8_t  scsi_status; /* -> reg 0x17 (ST_SELECT_TRANSFER_SUCCESS / TIMEOUT)    */
    uint8_t  tgt_status;  /* -> reg 0x0f (TGT_GOOD / TGT_CHECK_CONDITION)          */
} scsi_rsp_t;

#endif /* HENRY_SCSI_H */
