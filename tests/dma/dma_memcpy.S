/* dma_memcpy.S -- isolation test for the HPC3 mem-to-mem DMA engine (hpc3.sv).
 *
 * Fills DRAM region A with a pattern, programs the HPC3 DMA to copy A->B,
 * polls the CTRL DONE bit, verifies B==A, then prints 'P'/'F' on the CP0-$7
 * console FIFO and magic-halts.  All data + MMIO go through kseg1 (uncached) so
 * the CPU and the DMA observe the same DRAM (the DMA bypasses the L1).
 *
 *   build: mips-linux-gnu-gcc -march=mips3 -mabi=32 -EB -mno-abicalls -fno-pic \
 *            -nostdlib -nostartfiles -Wl,-Ttext=0x80010000 -Wl,-e,_start \
 *            -x assembler-with-cpp dma_memcpy.S -o dma_memcpy.elf
 *   run:   ./obj_dir/henry_tb --kernel tests/dma/dma_memcpy.elf --maxcyc 200000
 */
    .set noreorder
    .set noat
    .globl _start
    .text
_start:
    lui   $a0, 0xa810          /* A = phys 0x08100000 (kseg1, uncached) */
    lui   $a1, 0xa820          /* B = phys 0x08200000 (kseg1, uncached) */
    lui   $a2, 0xbfb9          /* HPC3 DMA regs = phys 0x1fb90000 (HPC3 +0x10000) */
    lui   $a3, 0xbfd0          /* magic-halt register = phys 0x1fd00000 */
    li    $t3, 64              /* word count (256 bytes = 16 cache lines) */
    lui   $t4, 0xa5a5          /* pattern base 0xa5a50000 */

    /* fill A[i] = 0xa5a50000 | i */
    move  $t2, $zero
fill:
    sll   $t5, $t2, 2
    addu  $t6, $a0, $t5
    or    $t7, $t4, $t2
    sw    $t7, 0($t6)
    addiu $t2, $t2, 1
    bne   $t2, $t3, fill
    nop

    /* program the DMA: SRC=0x08100000, DST=0x08200000, LEN=256, then GO */
    lui   $t0, 0x0810
    sw    $t0, 0($a2)          /* SRC  @ 0x10000 */
    lui   $t0, 0x0820
    sw    $t0, 4($a2)          /* DST  @ 0x10004 */
    li    $t0, 256
    sw    $t0, 8($a2)          /* LEN  @ 0x10008 */
    li    $t0, 1
    sw    $t0, 12($a2)         /* CTRL @ 0x1000c = GO */

    /* poll CTRL until DONE (bit1) */
poll:
    lw    $t0, 12($a2)
    andi  $t0, $t0, 2
    beq   $t0, $zero, poll
    nop

    /* verify B[i] == A[i] */
    move  $t2, $zero
chk:
    sll   $t5, $t2, 2
    addu  $t6, $a0, $t5
    addu  $t7, $a1, $t5
    lw    $s0, 0($t6)
    lw    $s1, 0($t7)
    bne   $s0, $s1, fail
    nop
    addiu $t2, $t2, 1
    bne   $t2, $t3, chk
    nop

pass:
    li    $t0, 0x50           /* 'P' */
    mtc0  $t0, $7             /* CP0 reg7 console putchar */
    nop
    li    $t0, 1
    sw    $t0, 0($a3)         /* magic-halt (non-zero) */
done:
    b     done
    nop
fail:
    li    $t0, 0x46           /* 'F' */
    mtc0  $t0, $7
    nop
    li    $t0, 1
    sw    $t0, 0($a3)
fdone:
    b     fdone
    nop
