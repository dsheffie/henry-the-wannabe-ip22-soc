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
 * ORACLE: each line is incremented once per pass, and is CHECKED AT THE START OF
 * EVERY PASS before being incremented -- not just at the end.  Checking only the
 * final value cannot tell a store that never landed from a line that reached the
 * right value and was then REVERTED (the L2 merging a pre-store copy over a good
 * one): both end one short.  Verifying each pass distinguishes them.  A line that
 * reads correctly at the start of pass k and wrong at the start of pass k+1 lost
 * exactly one store in pass k; a line that reads LOWER than a value already
 * verified in an earlier pass has gone backwards, which is a revert.
 *
 * Failure prints <code><expected><actual><address>: 'B' = wrong at a pass boundary,
 * 'F' = final check.  The address is there so the back-invalidate log
 * (+define+INCL_ADDR_LOG) can be filtered down to the line that actually broke.
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
    move  $s7, $zero           /* bad-line events */
    move  $s3, $zero           /* total increments lost */
    move  $s5, $zero           /* first failing address (0 = none) */
    move  $a0, $zero           /* value read there */
    move  $s2, $zero           /* lines also wrong via the uncached alias */
    li    $a1, 0xdead          /* uncached value of the first bad line */
    move  $a2, $zero           /* "capture the next uncached read" flag */
    move  $v0, $zero           /* vloop's first failing address */
    li    $a0, 0xdead          /* ... and its cached value (sentinel, not 0: the
				* expected-wrong value IS 0, so a 0 here could not be
				* told apart from "never captured") */

    /* zero the whole set through the CACHED alias first */
    move  $t0, $zero
zloop:
    sll   $t1, $t0, 4
    addu  $t1, $s0, $t1
    sw    $zero, 0($t1)
    addiu $t0, $t0, 1
    bne   $t0, $s4, zloop
    nop

    move  $t8, $zero           /* pass counter: at pass entry every line == $t8 */
oloop:
    move  $t0, $zero           /* line index */
loop:
    sll   $t1, $t0, 4          /* byte offset = idx * 16 */
    addu  $t1, $s0, $t1
    /* the read-modify-write under test */
    lw    $t2, 0($t1)
    nop
    /* CHECK BEFORE MODIFYING: this line was verified == $t8-1 last pass and
     * incremented to $t8, so anything else means it changed while we were not
     * looking.
     *
     * COUNT, do not halt.  Stopping at the first bad line reports exactly one
     * failure no matter how many there are, which made a systematic fault look
     * like a single unlucky line.  Record it, repair the value so later passes
     * stay meaningful, and carry on -- the census at the end is the real result. */
    beq   $t2, $t8, ok
    nop
    addiu $s7, $s7, 1          /* bad-line count */
    subu  $t3, $t8, $t2        /* shortfall = expected - actual */
    addu  $s3, $s3, $t3        /* total increments lost */
    beq   $s5, $zero, firstbad
    nop
    b     ok
    nop
firstbad:
    move  $s5, $t1             /* remember the FIRST failing address */
    move  $a0, $t2             /* ... and what it read */
ok:
    move  $t2, $t8             /* repair, so the next pass's check is meaningful */
    addiu $t2, $t2, 1
    sw    $t2, 0($t1)
    addiu $t0, $t0, 1
    bne   $t0, $s4, loop
    nop
    addiu $t8, $t8, 1
    bne   $t8, $s6, oloop
    nop

    /* ---- flush the L2 before verifying -------------------------------------
     * Stream a DISJOINT array twice the size of the L2 (2 MB vs 1 MB) so every set
     * is overwritten and every dirty working-set line is forced out.  Without this
     * the cached check can be served by a copy still resident in the hierarchy, so
     * "wrong in cache but right in DRAM" and "genuinely lost" are indistinguishable.
     * After the flush both reads must come from DRAM, so any remaining disagreement
     * means the value never reached memory at all.
     *
     * At 0x88800000, past the 4 MB working set (0x88300000-0x886fffff), so it
     * cannot alias any line under test in DRAM -- only in the cache, which is the
     * point. */
    lui   $t6, 0x8880          /* flush array, CACHED */
    lui   $t7, 0x0002          /* 0x20000 = 131072 lines = 2 MB */
    move  $t0, $zero
floop:
    sll   $t1, $t0, 4
    addu  $t1, $t6, $t1
    lw    $t2, 0($t1)          /* read only: the fill is what evicts */
    nop
    addiu $t0, $t0, 1
    bne   $t0, $t7, floop
    nop

    /* ---- verify: EVERY line must have been incremented exactly $s6 times ---- */
    move  $t0, $zero
vloop:
    sll   $t1, $t0, 4
    addu  $t9, $s0, $t1        /* cached alias   */
    lw    $t3, 0($t9)
    nop
    /* count, do not halt -- the last pass's stores have no pass-entry check after
     * them, so this loop is the ONLY place a pass-4 loss shows up.  Halting here
     * reports one bad line regardless of how many there are. */
    beq   $t3, $s6, vok
    nop
    addiu $s7, $s7, 1
    subu  $t5, $s6, $t3
    addu  $s3, $s3, $t5
    bne   $v0, $zero, vok      /* $v0: vloop's OWN first-bad addr, NOT $s5 --
				* sharing one register with the pass-entry check let
				* an earlier pass-entry failure suppress this capture,
				* so the address, cached value and uncached value were
				* each describing a different line. */
    nop
    move  $v0, $t9             /* vloop OWN first-bad addr (NOT $s5: shared with the pass-entry check) */
    li    $a2, 1               /* flag: capture this line's UNCACHED value below.
                                * A pointer compare cannot work here -- $t9 is
                                * reassigned to the uncached alias before that
                                * point, so it never equals the cached address. */
    /* NOT $t9: it is the loop's address register.  (It also used to be the base of
     * a `cache 0x15,0($t9)` below, so clobbering it made every bad line write back
     * a garbage address -- that op has since been removed entirely.) */
    move  $a0, $t3             /* and the value it held */
vok:
    /* NO cache op here on purpose.  A `cache 0x15` would (a) exercise the very
     * coherence machinery under test, confounding the result, and (b) force a
     * writeback before the uncached read, so "wrong in DRAM" would measure
     * DRAM-after-a-flush rather than DRAM as it actually stands.  Reading the
     * uncached alias directly asks the sharper question: does the cache serve a
     * value that memory disagrees with? */
    addu  $t9, $s1, $t1        /* uncached alias */
    lw    $t4, 0($t9)
    nop
    /* capture the UNCACHED value of the FIRST bad line: write path (DRAM wrong) or
     * read path (DRAM right)? */
    beq   $a2, $zero, notfirst
    nop
    move  $a1, $t4
    move  $a2, $zero
notfirst:
    beq   $t4, $s6, vok2
    nop
    addiu $s2, $s2, 1          /* wrong in MEMORY too, not just in cache */
vok2:
    addiu $t0, $t0, 1
    bne   $t0, $s4, vloop
    nop

    /* ---- census: bad-line events, increments lost, first bad addr+value ---- */
    beq   $s7, $zero, pass
    nop
    li    $t0, 0x43            /* 'C' -- census follows */
    mtc0  $t0, $7
    nop
    move  $t3, $s7
    bal   puthex               /* how many lines went wrong */
    nop
    move  $t3, $s3
    bal   puthex               /* how many increments were lost in total */
    nop
    move  $t3, $v0
    bal   puthex               /* vloop's first failing address */
    nop
    move  $t3, $a0
    bal   puthex               /* value it held */
    nop
    move  $t3, $s2
    bal   puthex               /* how many were wrong in DRAM as well */
    nop
    move  $t3, $a1
    bal   puthex               /* UNCACHED value of the first bad line */
    nop
    b     halt
    nop

pass:
    li    $t0, 0x50            /* 'P' */
    mtc0  $t0, $7
    nop
    b     halt
    nop

backwards:
    li    $t0, 0x42            /* 'B' -- caught at a pass boundary */
    mtc0  $t0, $7
    nop
    move  $t3, $t8             /* expected */
    bal   puthex
    nop
    move  $t3, $t2             /* actual   */
    bal   puthex
    nop
    move  $t3, $t1             /* the line's ADDRESS -- correlate with [bi-ack] */
    bal   puthex
    nop
    b     halt
    nop

fail:
    li    $t0, 0x46            /* 'F' */
    mtc0  $t0, $7
    nop
    bal   puthex
    nop
    b     halt
    nop

/* prints $t3 as 8 hex nybbles; clobbers $t5/$t6/$t7/$at */
puthex:
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
    jr    $ra
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
