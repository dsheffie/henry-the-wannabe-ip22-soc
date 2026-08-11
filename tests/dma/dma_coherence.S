/* dma_coherence.S -- directed DMA-vs-cache coherence test.
 *
 * The sibling dma_memcpy.S touches everything through kseg1 (uncached) on
 * purpose: it validates the DMA engine in isolation.  This test does the
 * OPPOSITE -- it deliberately leaves a CACHED copy of the destination buffer in
 * the L1D/L2 and then lets the DMA overwrite that same DRAM behind the caches.
 * A machine with no DMA coherence re-reads the pre-DMA data and prints 'F'.
 *
 * This exists so DMA staleness can be reproduced in ~100k cycles instead of the
 * ~150M cycles an IRIX boot needs before its first SCSI DMA, and so the stale
 * detector has a POSITIVE CONTROL: a case that must fail without inclusion and
 * pass with it.  A detector that reports "clean" is only meaningful once it has
 * been shown to report "dirty" on a known-dirty case.
 *
 *   A = phys 0x08100000  (source, DMA reads)
 *   B = phys 0x08200000  (dest,   DMA writes; the CPU caches this one)
 *     kseg1 (uncached) A=0xa8100000 B=0xa8200000 ; kseg0 (cached) B=0x88200000
 *
 * Sequence:
 *   1. fill A with P1 and B with P0, both UNCACHED (DRAM is unambiguous)
 *   2. read B CACHED  -> P0 now sits in L1D (and L2)
 *   3. DMA A->B       -> DRAM B becomes P1, caches still hold P0
 *   4. read B CACHED  -> P1 = coherent ('P'), P0 = stale ('F')
 *
 *   build: make -C tests/dma
 *   run:   ./obj_dir/henry_tb --kernel tests/dma/dma_coherence.elf --maxcyc 400000
 */
    .set noreorder
    .set noat
    .globl _start
    .text
_start:
    lui   $a0, 0xa810          /* A uncached  = phys 0x08100000 */
    lui   $a1, 0xa820          /* B uncached  = phys 0x08200000 */
    lui   $s3, 0x8820          /* B CACHED (kseg0) = same phys 0x08200000 */
    lui   $a2, 0xbfb9          /* HPC3 DMA regs = phys 0x1fb90000 (HPC3 +0x10000) */
    lui   $a3, 0xbfd0          /* magic-halt register = phys 0x1fd00000 */
    li    $t3, 64              /* word count (256 bytes = 16 cache lines) */

    /* ---- 1. fill A with P1 = 0xa5a50000|i, UNCACHED ---- */
    lui   $t4, 0xa5a5
    move  $t2, $zero
fillA:
    sll   $t5, $t2, 2
    addu  $t6, $a0, $t5
    or    $t7, $t4, $t2
    sw    $t7, 0($t6)
    addiu $t2, $t2, 1
    bne   $t2, $t3, fillA
    nop

    /* ---- 1b. fill B with P0 = 0x5a5a0000|i, UNCACHED ---- */
    lui   $t4, 0x5a5a
    move  $t2, $zero
fillB:
    sll   $t5, $t2, 2
    addu  $t6, $a1, $t5
    or    $t7, $t4, $t2
    sw    $t7, 0($t6)
    addiu $t2, $t2, 1
    bne   $t2, $t3, fillB
    nop

    /* ---- 2. read B through kseg0 so P0 lands in the L1D (and L2) ---- */
    move  $t2, $zero
    move  $s2, $zero           /* accumulator: keeps the loads from being dead */
warm:
    sll   $t5, $t2, 2
    addu  $t6, $s3, $t5
    lw    $s4, 0($t6)
    nop
    addu  $s2, $s2, $s4
    addiu $t2, $t2, 1
    bne   $t2, $t3, warm
    nop

    /* ---- 3. program the DMA: SRC=A, DST=B, LEN=256, GO ---- */
    lui   $t0, 0x0810
    sw    $t0, 0($a2)          /* SRC  @ 0x10000 */
    lui   $t0, 0x0820
    sw    $t0, 4($a2)          /* DST  @ 0x10004 */
    li    $t0, 256
    sw    $t0, 8($a2)          /* LEN  @ 0x10008 */
    li    $t0, 1
    sw    $t0, 12($a2)         /* CTRL @ 0x1000c = GO */
poll:
    lw    $t0, 12($a2)
    andi  $t0, $t0, 2
    beq   $t0, $zero, poll
    nop

    /* ---- 4. re-read B CACHED; it must now equal A (P1) ---- */
    move  $t2, $zero
chk:
    sll   $t5, $t2, 2
    addu  $t6, $a0, $t5        /* A uncached = ground truth (P1) */
    addu  $t7, $s3, $t5        /* B CACHED   = what the CPU sees */
    lw    $s0, 0($t6)
    lw    $s1, 0($t7)
    bne   $s0, $s1, fail
    nop
    addiu $t2, $t2, 1
    bne   $t2, $t3, chk
    nop

pass:
    li    $t0, 0x50           /* 'P' */
    mtc0  $t0, $7
    nop
    b     halt
    nop
fail:
    li    $t0, 0x46           /* 'F' */
    mtc0  $t0, $7
    nop
halt:
    li    $t0, 0x0a           /* '\n' */
    mtc0  $t0, $7
    nop
    li    $t0, 1
    sw    $t0, 0($a3)         /* magic-halt (non-zero) */
done:
    b     done
    nop
