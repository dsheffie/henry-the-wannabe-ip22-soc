/* enet_service.h -- host-side ethernet service for the henry ENET shim.
 *
 * Bridges the guest's two HPC3 ENET DMA channels (owned by enet_shim.sv) to a host
 * TAP device.  The behaviour is traced from the validated interp_mips model
 * (sgi_hpc.cc enet_run_dma / sgi_seeq.cc), which boots IRIX networking (ping,
 * telnet, X11).  Header-only C++; henry_tb includes it, and the ARM PS driver
 * reuses the SAME logic against mmap'd DRAM (only the mailbox transport differs).
 *
 *   TX (ch1, guest-initiated doorbell): walk the {BP,BC,DP} chain from nbdp,
 *     concatenate the buffers into one frame (to EOX), set each descriptor's ETXD,
 *     and write the frame to the tap.
 *   RX (ch0, service free-run): poll the tap; on an inbound frame, walk the guest
 *     RX ring from the armed head, find an HPC-owned (ROWN) descriptor, deposit
 *     [2 pad][frame][1 status=0x30], clear ROWN, write back BCNT=residual, report
 *     the filled descriptor in `crbdp`, and advance.
 *
 * Reuses the scsi_mem_fn DRAM accessor + the henry_scsi.h descriptor contract.
 */
#ifndef ENET_SERVICE_H
#define ENET_SERVICE_H
#include "henry_scsi.h"        /* hpc3_desc / HPC3_BC_* / hdma_be32 / scsi_mem_fn */
#include "scsi_service.h"      /* scsi_mem_fn typedef */
#include <cstdint>
#include <cstring>
#include <cstdio>
#include <fcntl.h>
#include <unistd.h>
#include <net/if.h>
#include <linux/if_tun.h>
#include <sys/ioctl.h>

/* HPC3 ENET descriptor bits the interp uses (sgi_hpc.cc) that aren't in the SCSI
 * subset: ROWN (RX buffer owned by HPC3) and ETXD (HPC transmitted this buffer). */
enum {
    HPC3_BC_ROWN = 0x00004000u,   /* RX: 1 = HPC owns the buffer (may fill it)  */
    HPC3_BC_ETXD = 0x00008000u,   /* TX: HPC set this after transmitting        */
};
static const uint8_t ENET_RX_STATUS_GOOD = 0x30;   /* Seeq RS_GOOD|RS_END appended byte */
static const uint32_t ENET_FRAME_MAX = 2048;

/* ---- write a big-endian word back into a descriptor's BC field (offset +4) ---- */
static inline void enet_put_be32(uint8_t *p, uint32_t v)
{ p[0]=(uint8_t)(v>>24); p[1]=(uint8_t)(v>>16); p[2]=(uint8_t)(v>>8); p[3]=(uint8_t)v; }

struct enet_tap {
    int fd = -1;
    bool open_tap(const char *ifname) {
        if(!ifname || !*ifname) { return false; }
        fd = ::open("/dev/net/tun", O_RDWR | O_NONBLOCK);
        if(fd < 0) { fprintf(stderr, "enet_tap: open /dev/net/tun failed\n"); return false; }
        struct ifreq ifr; memset(&ifr, 0, sizeof(ifr));
        ifr.ifr_flags = IFF_TAP | IFF_NO_PI;
        strncpy(ifr.ifr_name, ifname, IFNAMSIZ - 1);
        if(::ioctl(fd, TUNSETIFF, &ifr) < 0) {
            fprintf(stderr, "enet_tap: TUNSETIFF %s failed (need the tap up + user-owned)\n", ifname);
            ::close(fd); fd = -1; return false;
        }
        fprintf(stderr, "enet_tap: attached to %s\n", ifname);
        return true;
    }
    bool ok() const { return fd >= 0; }
};

/* ---- TX: walk the chain from nbdp, assemble one frame, set ETXD, write the tap.
 * Returns the number of bytes transmitted (0 on a short/empty chain). ---- */
static inline uint32_t enet_tx_run(scsi_mem_fn mem, void *ctx, uint32_t nbdp, int tap_fd) {
    uint8_t frame[ENET_FRAME_MAX];
    uint32_t len = 0;
    for(int guard = 0; guard < 64; guard++) {
        uint8_t *d = mem(ctx, nbdp, 12);
        if(!d) { break; }
        uint32_t bp   = hdma_be32(d + 0);
        uint32_t bc   = hdma_be32(d + 4);
        uint32_t next = hdma_be32(d + 8);
        uint32_t cnt  = bc & HPC3_BC_COUNT;
        if(cnt > ENET_FRAME_MAX - len) { cnt = ENET_FRAME_MAX - len; }
        if(cnt) {
            uint8_t *b = mem(ctx, bp, cnt);
            if(b) { memcpy(frame + len, b, cnt); len += cnt; }
        }
        enet_put_be32(d + 4, bc | HPC3_BC_ETXD);        /* HPC transmitted this buffer */
        if(bc & HPC3_BC_EOX) { break; }
        nbdp = next;
    }
    if(tap_fd >= 0 && len >= 14) {
        ssize_t n = ::write(tap_fd, frame, len);
        (void)n;
    }
    return len;
}

/* ---- RX: deposit one inbound frame into the guest RX ring.
 * `nbdp` is walked and updated (the service's current ring position); on success
 * `crbdp` = the descriptor just filled (the guest reads it at HPC3 reg 0x18000).
 * Returns true if a descriptor was consumed (frame delivered), false if the ring is
 * full (all CPU-owned) -> the frame is dropped, like real hardware. ---- */
static inline bool enet_rx_inject(scsi_mem_fn mem, void *ctx, uint32_t &nbdp,
                                  const uint8_t *frame, uint32_t flen, uint32_t &crbdp) {
    uint8_t *d = mem(ctx, nbdp, 12);
    if(!d) { return false; }
    uint32_t bp    = hdma_be32(d + 0);
    uint32_t bc    = hdma_be32(d + 4);
    uint32_t next  = hdma_be32(d + 8);
    if(!(bc & HPC3_BC_ROWN)) { return false; }          /* CPU still owns it: ring full */
    uint32_t bufsz = bc & HPC3_BC_COUNT;
    /* A usable RX buffer must hold at least [2 pad][>=0 frame][1 status] = 3 B.
     * A stale/torn descriptor read as ROWN=1,COUNT=0 would clamp `written` to 0
     * and store the status byte at b[written-1] == b[0xffffffff] (SIGSEGV).
     * Treat a too-small buffer as not-ready and drop the frame (self-heals on the
     * next poll once the guest has fully armed the descriptor). */
    if(bufsz < 3) { return false; }
    /* layout the driver expects: [2 pad][ethernet frame][1 status] */
    uint32_t written = 2 + flen + 1;
    if(written > bufsz) { written = bufsz; }             /* clamp a giant frame to the buffer */
    uint8_t *b = mem(ctx, bp, written);
    if(!b) { return false; }
    b[0] = 0; b[1] = 0;                                  /* 2-byte alignment pad */
    uint32_t fcopy = (written >= 3) ? (written - 3) : 0;
    if(fcopy > flen) { fcopy = flen; }
    if(fcopy) { memcpy(b + 2, frame, fcopy); }
    b[written - 1] = ENET_RX_STATUS_GOOD;               /* appended Seeq status byte */
    uint32_t residual = bufsz - written;
    /* write back BC: clear ROWN, set BCNT=residual, preserve the flag bits */
    enet_put_be32(d + 4, (bc & ~HPC3_BC_ROWN & ~HPC3_BC_COUNT) | (residual & HPC3_BC_COUNT));
    crbdp = nbdp;
    nbdp  = next;                                        /* advance around the ring */
    return true;
}

/* ---- address filter (Seeq RX command match modes; sgi_seeq.cc address_filter).
 * station = the 6 programmed MAC bytes (MSB first). rx_cmd bits [7:6] select the
 * match mode.  Broadcast + station always pass in the common STA_BCAST mode. ---- */
static inline bool enet_addr_filter(uint8_t rx_cmd, const uint8_t station[6],
                                    const uint8_t *frame, uint32_t len) {
    if(len < 6) { return false; }
    bool is_bcast = (frame[0]&frame[1]&frame[2]&frame[3]&frame[4]&frame[5]) == 0xff;
    bool is_sta   = memcmp(frame, station, 6) == 0;
    bool is_multi = (frame[0] & 1) != 0;
    switch(rx_cmd & 0xc0) {
    case 0x00: return false;                             /* receiver disabled */
    case 0x40: return true;                              /* promiscuous       */
    case 0x80: return is_bcast || is_sta;                /* station + bcast    */
    default:   return is_bcast || is_sta || is_multi;    /* + multicast        */
    }
}

#endif /* ENET_SERVICE_H */
