# Henry SoC SCC Rx echo -- validates the RX wrapper (ARM -> S00_AXI reg 0x3b push
# / 0x3a bit8 full -> SCC Rx FIFO -> core) end to end ON THE FPGA.
#
# Pure assembly running DIRECTLY from the reset vector (0xbfc00000): no C runtime,
# no TLB, no stack, no $gp.  This deliberately avoids the mapped bare-metal
# runtime (start_csmith_mapped.S), which does NOT reach main on the restructured
# henny SoC (the same "big-csmith reaches ready/state 1 then hangs" issue).
#
#   make                  -> echo_asm.mips
#   make deploy           -> scp to the board (~/mips)
# On the board (after `fpgautil -b ultra96v2_oob_wrapper.bit`):
#   ~/axilite-mips/mips-axi -f echo_asm.mips --sgi 1          # interactive: type, keys echo back
#   printf "hello" | ~/axilite-mips/mips-axi -f echo_asm.mips --sgi 1   # scripted
# It prints "E\n" once (Tx path alive), then echoes every byte the ARM pushes.
BOARD := root@fpga.local
CC    := mips-linux-gnu-gcc
FLAGS := -mips3 -mabi=n32 -mno-abicalls -G0 -nostdlib -Wl,-melf32btsmipn32

echo_asm.mips: echo_asm.elf
	cp $< $@

echo_asm.elf: echo_asm.S echo_asm.ld
	$(CC) $(FLAGS) -T echo_asm.ld echo_asm.S -o $@

deploy: echo_asm.mips
	scp echo_asm.mips $(BOARD):~/mips/

clean:
	rm -f echo_asm.elf echo_asm.mips
