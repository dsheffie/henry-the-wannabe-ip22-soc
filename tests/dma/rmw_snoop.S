/* rmw_snoop.S -- hammer a read-modify-write on ONE cached line while the
 * synthetic snoop injector tries to take that line away underneath it.
 *
 * WHY: the IRIX repro takes ~90M cycles and lands as "PANIC: pagedequeue" long
 * after the damage.  Bisecting it showed the corruption needs the L1D
 * back-invalidate specifically (L1I-only and L2-invalidate-only both survive),
 * and the first divergence in a clean run was inside bset() -- a read-modify-write
 * of a bitmap word that came back missing exactly one bit.  This reproduces that
 * shape directly, in a few thousand cycles, with an exact expected value.
 *
 * IT MUST MISS TO BE TESTED AT ALL.  The injector arms on L2 line FILLS.  A first
 * version hammered ONE line, which fills once and then hits in the L1D forever --
 * zero snoops fired and it "passed" without testing anything.  So the RMW now walks
 * a WORKING SET larger than the L2 -- not the L1D.  Sizing it past the 4 KB L1D
 * was not enough: the injector arms on L2->DRAM fills, so an L1D miss that HITS in
 * the 1 MB sim L2 (BIG_SIM_L2, LG_L2_NUM_SETS=16) arms nothing, and a 64 KB set
 * again produced zero snoops.  4 MB overflows the L2, so every iteration reaches
 * DRAM, every fill arms a snoop, and each line is read-modify-written while snoops
 * take it away.
 *
 * ORACLE: the counter is incremented N times, so it must read exactly N.  Any
 * value below N is a LOST STORE -- the snoop handed the L2 a pre-store copy of the
 * line and the L2 merged it over the good one.  The shortfall is printed in hex so
 * the magnitude is visible, not just pass/fail.
 *
 * Checked through the UNCACHED alias as well, so a correct-looking cached read
 * cannot mask a wrong value in memory.
 *
 *   build: make -C tests/dma
 *   run:   ./obj_dir/henry_tb --kernel tests/dma/rmw_snoop.elf --maxcyc 20000000
 */
    .set noreorder
    .set noat
    .globl _start
    .text
_start:
    lui   $s0, 0x8830          /* target, CACHED   (kseg0) = phys 0x08300000 */
    lui   $s1, 0xa830          /* same line, UNCACHED (kseg1)                */
    lui   $a3, 0xbfd0          /* magic-halt register = phys 0x1fd00000      */

    /* zero it through the uncached alias so DRAM is unambiguous at the start */
    sw    $zero, 0($s1)
    nop

    /* working set = 4 MB = 4x the 1 MB sim L2, stride 16 B, 262144 lines */
    lui   $s4, 0x0004          /* 0x40000 = 262144 lines */
    li    $s6, 4               /* passes over the whole set */

    /* zero the whole set through the CACHED alias first */
    move  $t0, $zero
zloop:
    sll   $t1, $t0, 4
    addu  $t1, $s0, $t1
    sw    $zero, 0($t1)
    addiu $t0, $t0, 1
    bne   $t0, $s4, zloop
    nop

    move  $t8, $zero           /* pass counter */
oloop:
    move  $t0, $zero           /* line index */
loop:
    sll   $t1, $t0, 4          /* byte offset = idx * 16 */
    addu  $t1, $s0, $t1
    /* the read-modify-write under test */
    lw    $t2, 0($t1)
    nop
    addiu $t2, $t2, 1
    sw    $t2, 0($t1)
    addiu $t0, $t0, 1
    bne   $t0, $s4, loop
    nop
    addiu $t8, $t8, 1
    bne   $t8, $s6, oloop
    nop

    /* ---- verify: EVERY line must have been incremented exactly $s6 times ---- */
    move  $t0, $zero
vloop:
    sll   $t1, $t0, 4
    addu  $t9, $s0, $t1        /* cached alias   */
    lw    $t3, 0($t9)
    nop
    bne   $t3, $s6, fail       /* short == a lost store */
    nop
    /* push it to memory and re-check uncached, so a good-looking cached value
     * cannot hide a bad one in DRAM */
    cache 0x15, 0($t9)         /* Hit_Writeback_Invalidate_D */
    nop
    addu  $t9, $s1, $t1        /* uncached alias */
    lw    $t4, 0($t9)
    nop
    bne   $t4, $s6, fail
    nop
    addiu $t0, $t0, 1
    bne   $t0, $s4, vloop
    nop

pass:
    li    $t0, 0x50            /* 'P' */
    mtc0  $t0, $7
    nop
    b     halt
    nop

fail:
    li    $t0, 0x46            /* 'F' */
    mtc0  $t0, $7
    nop
    /* print the cached value as 8 hex nybbles so the shortfall is visible:
     * "F<cached>" -- e.g. F0000fffe means two stores were lost. */
    li    $t5, 8               /* nybbles remaining */
    move  $t6, $t3             /* value to print */
hexlp:
    srl   $t7, $t6, 28         /* top nybble */
    andi  $t7, $t7, 0xf
    sltiu $at, $t7, 10
    beq   $at, $zero, hexal
    nop
    addiu $t7, $t7, 0x30       /* '0'..'9' */
    b     hexem
    nop
hexal:
    addiu $t7, $t7, 0x57       /* 'a'..'f' */
hexem:
    mtc0  $t7, $7
    nop
    sll   $t6, $t6, 4
    addiu $t5, $t5, -1
    bne   $t5, $zero, hexlp
    nop

halt:
    li    $t0, 0x0a            /* '\n' */
    mtc0  $t0, $7
    nop
    li    $t0, 1
    sw    $t0, 0($a3)          /* magic-halt (non-zero) */
done:
    b     done
    nop
