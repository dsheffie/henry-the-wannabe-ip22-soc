/* diskverify.c -- coherent-DMA test for the r9999/henry SCSI path.
 *
 * The disk (idiodisk.img) is self-identifying: sector N, word W holds
 *   0x5E<N:16><W:8>   (big-endian)
 * so a stale 16B cache line reads the PREVIOUS DMA's sector number.
 *
 * Two passes, both O_DIRECT (raw DMA, no page cache):
 *   clean : read sector -> verify the idiomatic value.
 *   dirty : memset the buffer to 0xDD (dirties the CPU cache lines), THEN
 *           O_DIRECT-read the same sector.  A correct DMA + invalidate leaves
 *           the disk value; a surviving/clobbering dirty line reads 0xDDDDDDDD.
 *
 * Reports the first mismatches with the wrong sector number decoded, so the
 * failing line + which sector's stale data landed there is obvious.
 */
#include <stdio.h>
#include <stdlib.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdint.h>
#include <string.h>

#define SECSZ   512
#define CHUNK   4096            /* 8 sectors, page-aligned for O_DIRECT */
#define NSEC    8192

static int verify_chunk(const uint8_t *buf, int base_sec, int dirty, int *shown) {
    int errs = 0;
    for(int i = 0; i < CHUNK/4; i++) {
        int s = base_sec + i/128, w = i % 128;
        uint32_t got = ((uint32_t)buf[i*4]<<24)|((uint32_t)buf[i*4+1]<<16)|
                       ((uint32_t)buf[i*4+2]<<8)|(uint32_t)buf[i*4+3];
        uint32_t exp = (0x5Eu<<24)|(((uint32_t)s&0xffff)<<8)|((uint32_t)w&0xff);
        if(got != exp) {
            if(*shown < 24) {
                if(got == 0xDDDDDDDDu)
                    printf("  %s sec %d word %d: exp=%08x got=DDDDDDDD (DIRTY line survived DMA)\n",
                           dirty?"dirty":"clean", s, w, exp);
                else
                    printf("  %s sec %d word %d: exp=%08x got=%08x (stale from sector %u)\n",
                           dirty?"dirty":"clean", s, w, exp, got, (got>>8)&0xffff);
                (*shown)++;
            }
            errs++;
        }
    }
    return errs;
}

int main(int argc, char **argv) {
    const char *dev = (argc > 1) ? argv[1] : "/dev/sda";
    int fd = open(dev, O_RDONLY | O_DIRECT);
    if(fd < 0) { printf("diskverify: cannot open %s (O_DIRECT)\n", dev); return 1; }

    void *buf = NULL;
    if(posix_memalign(&buf, 4096, CHUNK) != 0) { printf("memalign fail\n"); return 1; }

    for(int dirty = 0; dirty <= 1; dirty++) {
        int errs = 0, shown = 0;
        printf("=== %s pass ===\n", dirty ? "DIRTY (pre-fill 0xDD then DMA)" : "CLEAN");
        for(int s = 0; s < NSEC; s += CHUNK/SECSZ) {
            if(dirty) memset(buf, 0xDD, CHUNK);           /* dirty the cache lines */
            ssize_t n = pread(fd, buf, CHUNK, (off_t)s * SECSZ);
            if(n != CHUNK) { printf("  read fail sec %d (ret %ld)\n", s, (long)n); break; }
            errs += verify_chunk((uint8_t*)buf, s, dirty, &shown);
        }
        printf("=== %s: %d word-mismatches over %d sectors ===\n",
               dirty ? "DIRTY" : "CLEAN", errs, NSEC);
    }
    close(fd);
    printf("diskverify done\n");
    return 0;
}
