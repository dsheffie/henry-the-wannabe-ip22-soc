/*
 * echo_asm.S -- pure-assembly SCC Rx echo, runs DIRECTLY from the reset vector
 * (0xbfc00000). No C runtime, no TLB, no stack, no $gp -- so it can't be defeated
 * by the mapped-bare-metal startup that big-csmith gets stuck in. Run with
 * `mips-axi -f echo_asm.mips --sgi 1` (--sgi loads the 0xbfc00000 segment).
 *
 * Emits "E\n" once (proves the core runs + the SCC Tx->putchar path works), then
 * echoes every Rx byte: poll chanA RR0 (rx_avail bit0) @0xBFBD9833, read the byte
 * @0xBFBD9837 (pops the Rx FIFO), write it back @0x37 (Tx -> host console).
 */
	.set noreorder
	.set noat
	.section .boot.reset, "ax"
	.globl _start
_start:
	lui	$8, 0xbfbd
	ori	$8, $8, 0x9800		/* $8 = SCC chanA base 0xbfbd9800 */

	ori	$9, $0, 0x45		/* 'E' */
	sb	$9, 0x37($8)		/* Tx marker */
	ori	$9, $0, 0x0a		/* '\n' */
	sb	$9, 0x37($8)

loop:
	lbu	$9, 0x33($8)		/* RR0 */
	andi	$9, $9, 0x01		/* Rx Char Available? */
	beq	$9, $0, loop
	nop
	lbu	$10, 0x37($8)		/* read Rx byte (pops FIFO) */
	sb	$10, 0x37($8)		/* echo via Tx */
	b	loop
	nop
