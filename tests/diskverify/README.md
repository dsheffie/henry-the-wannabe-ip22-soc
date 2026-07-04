# diskverify — coherent-DMA test under Linux

A controlled SCSI DMA/cache-coherence test for the r9999/henry board. The disk
is self-identifying (sector N, word W = big-endian `0x5E<N:16><W:8>`), so a stale
16B cache line reads the *previous* DMA's sector number — corruption is obvious
and localizable.

`diskverify.c` does two O_DIRECT passes over `/dev/sda` (raw DMA, no page cache):
- **CLEAN** — read each sector, verify the idiomatic value.
- **DIRTY** — `memset(0xDD)` the buffer (dirties the CPU cache lines), then
  O_DIRECT-read; a correct DMA+invalidate leaves the disk value, a surviving /
  clobbering dirty line reads `0xDDDDDDDD`.

Result (2026-07-04): **both passes CLEAN on silicon** → the RTL's DMA/cache
coherence is correct (Linux reads the 16B dcache line size from `Config` and
manages the cache right). IRIX's INQUIRY/`chown` corruption is IRIX's cache-mgmt
software (hardcoded 32B), not the RTL.

## Build

Userspace (musl mips3 toolchain, hard-float to match busybox):

    TC=~/mips-initramfs/mips3-tc/bin/mips64-linux-musl-gcc
    $TC -O2 -static -o diskverify diskverify.c

Idiomatic disk image:

    ./gen_idiodisk.py idiodisk.img 8192          # 4 MB, 8192 sectors

Kernel + initramfs (SCSI kernel: `CONFIG_SGIWD93_SCSI` + `CONFIG_BLK_DEV_SD`).
Add these to the gen_init_cpio spec and point `/init` at `diskverify_init.sh`:

    file /bin/diskverify <path>/diskverify        0755 0 0
    file /init           <path>/diskverify_init.sh 0755 0 0

then in `~/code/linux-mips`:

    ./scripts/config --set-str INITRAMFS_SOURCE <path>/diskverify.spec
    make ARCH=mips CROSS_COMPILE=mips64-linux-gnuabi64- -j$(nproc)   # emits vmlinux.32

## Run on the FPGA

The mips-axi driver's SCSI disk path is now `SCSIDISK`-configurable (defaults to
the IRIX image), so point it at the idiodisk without clobbering IRIX:

    # copy the artifacts to the board
    scp vmlinux.32 root@fpga.local:~/mips/vmlinux.32.dv
    scp idiodisk.img root@fpga.local:~/idiodisk.img

    # on the board (~/mips):
    fpgautil -b ultra96v2_oob_wrapper.bit
    SCSIDISK=/home/root/idiodisk.img \
      ~/axilite-mips/mips-axi -f vmlinux.32.dv --sgi true \
      --arcs henry_arcs.bin --start-pc 0xbfc00000

Watch for the disk attach (`[sda] 8192 512-byte logical blocks`) then:

    === CLEAN: 0 word-mismatches over 8192 sectors ===
    === DIRTY: 0 word-mismatches over 8192 sectors ===

Any mismatch prints the failing sector/word and the wrong value; `stale from
sector M` means a prior DMA of sector M leaked into this line, and
`DIRTY line survived DMA` means the invalidate/writeback around the DMA is wrong.
