/* scsi_service.h -- host-side disk service for the henry SCSI shim.
 *
 * Reads a request (henry_scsi.h scsi_req_t) published by scsi_shim.sv, walks the
 * HPC3 {BP,BC,DP} descriptor chain in guest DRAM, does the disk I/O straight into
 * DRAM, and fills a completion (scsi_rsp_t).  Header-only C++; henry_tb includes
 * it.  The ARM disk service reuses the SAME henry_scsi.h contract + the same
 * decode/walk logic (reimplemented in C against mmap'd DRAM).
 *
 * Memory is reached through a caller-supplied accessor so the same code works in
 * sim (g_mem + the FPGA address map) and on the ARM (mmap):
 *     uint8_t *mem(ctx, phys, len)  -> pointer to len contiguous bytes at guest
 *                                       physical `phys`, or nullptr if unmapped.
 *
 * The descriptor walk (scsi_move) is the channel-generic part; enet-TX would
 * reuse it verbatim (see the CHANNEL/ENET SEAM note in henry_scsi.h).
 */
#ifndef SCSI_SERVICE_H
#define SCSI_SERVICE_H
#include "henry_scsi.h"
#include <cstdio>
#include <cstring>
#include <cstdint>
#include <vector>
#include <array>
#include <unordered_map>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>

typedef uint8_t *(*scsi_mem_fn)(void *ctx, uint32_t phys, uint32_t len);

/* ---- disk backend: read-only image + in-memory copy-on-write overlay ---- */
struct scsi_disk {
    int      fd = -1;
    uint64_t nblocks = 0;
    std::unordered_map<uint64_t, std::array<uint8_t,512>> overlay;   /* COW writes */

    bool open_image(const char *path) {
        fd = ::open(path, O_RDONLY);
        if(fd < 0) { fprintf(stderr, "scsi_disk: cannot open %s\n", path); return false; }
        struct stat st;
        if(::fstat(fd, &st) == 0) nblocks = (uint64_t)st.st_size / 512;
        fprintf(stderr, "scsi_disk: %s -- %llu blocks (%llu MB)\n", path,
                (unsigned long long)nblocks, (unsigned long long)(nblocks/2048));
        return true;
    }
    bool ok() const { return fd >= 0; }

    void block_read(uint64_t lba, uint8_t *dst) {           /* overlay wins, else image, else zero */
        auto it = overlay.find(lba);
        if(it != overlay.end()) { memcpy(dst, it->second.data(), 512); return; }
        if(lba < nblocks && ::pread(fd, dst, 512, (off_t)lba * 512) == 512) return;
        memset(dst, 0, 512);
    }
    void block_write(uint64_t lba, const uint8_t *src) {    /* writes go ONLY to the overlay */
        std::array<uint8_t,512> b; memcpy(b.data(), src, 512); overlay[lba] = b;
    }
};

/* ---- move `n` bytes between a host buffer and the descriptor-chain'd DRAM buffers.
 * to_device=false (READ):  buf -> DRAM[BP...]   ;  true (WRITE): DRAM[BP...] -> buf.
 * Returns bytes actually moved (n minus any shortfall from a too-short chain). ---- */
static inline uint32_t scsi_move(scsi_mem_fn mem, void *ctx, uint32_t nbdp,
                                 uint8_t *buf, uint32_t n, bool to_device) {
    uint32_t moved = 0;
    for(int guard = 0; guard < 4096 && moved < n; guard++) {
        uint8_t *d = mem(ctx, nbdp, 12);
        if(!d) break;
        uint32_t bp    = hdma_be32(d + 0);
        uint32_t bc    = hdma_be32(d + 4);
        uint32_t next  = hdma_be32(d + 8);
        uint32_t count = bc & HPC3_BC_COUNT;
        uint32_t chunk = (count < (n - moved)) ? count : (n - moved);
        if(chunk) {
            uint8_t *b = mem(ctx, bp, chunk);
            if(!b) break;
            if(to_device) memcpy(buf + moved, b, chunk);   /* WRITE: collect from DRAM */
            else          memcpy(b, buf + moved, chunk);   /* READ:  deposit into DRAM */
            moved += chunk;
        }
        if(bc & HPC3_BC_EOX) break;
        nbdp = next;
    }
    return moved;
}

/* ---- service one Select-And-Transfer ---- */
// Lower-level model: produce the SCSI response payload (data-in) or size the
// data-out, and the status -- but DO NOT touch DRAM.  The scsi_dma RTL engine
// (a real ordered DRAM master) moves the bytes between this buffer and memory;
// the caller serves `buf` as 16B beats on the engine's disk-side port.  For
// data-out (WRITE/MODE SELECT) the caller fills `buf` from the captured beats and
// then commits it (block_write at wr_lba).
static inline void scsi_service_run(const scsi_req_t *req, scsi_rsp_t *rsp,
                                    scsi_disk *disk, std::vector<uint8_t> &buf,
                                    bool &to_dev, uint64_t &wr_lba) {
    rsp->seq         = req->seq;
    rsp->residual    = 0;
    rsp->scsi_status = ST_SELECT_TRANSFER_SUCCESS;
    rsp->tgt_status  = TGT_GOOD;
    buf.clear(); to_dev = false; wr_lba = 0;

    const uint8_t *cdb = req->cdb;
    uint8_t op  = cdb[0];
    uint8_t dest = req->dest & 7, lun = req->lun & 7;
    fprintf(stderr, "[scsi] CDB %02x %02x %02x %02x %02x %02x dest=%u lun=%u\n",
            cdb[0],cdb[1],cdb[2],cdb[3],cdb[4],cdb[5], dest, lun);

    /* selection timeout: only the disk target responds */
    if(dest != SCSI_DISK_TARGET) { rsp->scsi_status = ST_SELECTION_TIMEOUT; return; }
    /* LUN gate: only LUN 0 exists (REQUEST SENSE on other LUNs still answers) */
    if(lun != 0 && op != SCSI_REQUEST_SENSE) { rsp->tgt_status = TGT_CHECK_CONDITION; return; }

    switch(op) {
    case SCSI_TEST_UNIT_READY:
    case SCSI_START_STOP:
        break;                    /* no data */
    case SCSI_INQUIRY: {
        uint8_t inq[36] = {0};
        inq[0]=0x00; inq[1]=0x00; inq[2]=0x02; inq[3]=0x02; inq[4]=31;
        memcpy(inq+8,  "SGI     ", 8);
        memcpy(inq+16, "interp_mips disk", 16);
        memcpy(inq+32, "1.0 ", 4);
        uint32_t alloc = cdb[4]; if(alloc > sizeof(inq)) alloc = sizeof(inq);
        buf.assign(inq, inq + alloc);
        break;
    }
    case SCSI_REQUEST_SENSE: {
        uint8_t sense[18] = {0};
        sense[0]=0x70;            /* current error, fixed format */
        if(lun != 0) { sense[2]=0x05; sense[7]=0x0a; sense[12]=0x25; }  /* ILLEGAL/LUN-NOT-SUP */
        uint32_t alloc = cdb[4]; if(alloc > sizeof(sense)) alloc = sizeof(sense);
        buf.assign(sense, sense + alloc);
        break;
    }
    case SCSI_READ_CAPACITY10: {
        uint8_t cap[8];
        uint32_t last = disk->nblocks ? (uint32_t)(disk->nblocks - 1) : 0;
        cap[0]=last>>24; cap[1]=last>>16; cap[2]=last>>8; cap[3]=last;
        cap[4]=0; cap[5]=0; cap[6]=2; cap[7]=0;          /* block size 512, BE */
        buf.assign(cap, cap + 8);
        break;
    }
    case SCSI_MODE_SENSE6: {
        uint8_t ms[4] = {3, 0, 0, 0};
        uint32_t alloc = cdb[4]; if(alloc > sizeof(ms)) alloc = sizeof(ms);
        buf.assign(ms, ms + alloc);
        break;
    }
    case SCSI_MODE_SELECT6:
        buf.assign(cdb[4], 0); to_dev = true;            /* consume + succeed */
        break;
    case SCSI_READ10: {
        uint64_t lba = cdb10_lba(cdb); uint32_t blk = cdb10_blocks(cdb);
        buf.assign((size_t)blk * 512, 0);
        for(uint32_t i = 0; i < blk; i++) disk->block_read(lba + i, buf.data() + (size_t)i*512);
        break;
    }
    case SCSI_WRITE10: {
        wr_lba = cdb10_lba(cdb); uint32_t blk = cdb10_blocks(cdb);
        buf.assign((size_t)blk * 512, 0); to_dev = true;
        break;
    }
    default:
        break;                    /* lenient: success / no data */
    }
    /* No DRAM access here -- the engine + caller move the bytes. */
}

#endif /* SCSI_SERVICE_H */
