#!/usr/bin/python3
# Generate a self-identifying disk image for the coherent-DMA test: sector N,
# word W (0..127) holds big-endian 0x5E<N:16><W:8>.  A stale 16B cache line
# therefore reads the PREVIOUS DMA's sector number -> instantly localizable.
import struct, sys
NSEC = int(sys.argv[2]) if len(sys.argv) > 2 else 8192          # 4 MB default
out  = sys.argv[1] if len(sys.argv) > 1 else 'idiodisk.img'
with open(out, 'wb') as f:
    for s in range(NSEC):
        sec = bytearray()
        for w in range(128):
            sec += struct.pack('>I', (0x5E << 24) | ((s & 0xffff) << 8) | (w & 0xff))
        f.write(sec)
print("wrote %s: %d sectors (sector N word W = 0x5E<N:16><W:8>)" % (out, NSEC))
