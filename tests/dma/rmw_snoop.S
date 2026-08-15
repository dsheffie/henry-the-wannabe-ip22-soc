/* rmw_snoop.S -- hammer a read-modify-write on a large working set while the
 * synthetic snoop injector tries to take each line away underneath it.
 *
 * WHY: the IRIX repro takes ~90M cycles and lands as "PANIC: pagedequeue" long
 * after the damage.  Bisecting it showed the corruption needs the L1D
 * back-invalidate specifically (L1I-only and L2-invalidate-only both survive),
 * and the first divergence in a clean run was inside bset() -- a read-modify-write
 * of a bitmap word that came back missing exactly one bit.  This reproduces that
 * shape directly, in a few million cycles, with an exact expected value.
 *
 * SELF-DESCRIBING DATA -- the point of this version.
 * The previous version stored a bare pass counter (0..4), so EVERY line in the
 * working set held the SAME value.  A wrong line therefore told us only that a
 * store had gone missing; it could not distinguish
 *     (a) our store was lost           -- line keeps its own previous version
 *     (b) we were handed another line's data -- a misroute/alias
 *     (c) we were handed something that was never stored data at all
 * and (b) is precisely what a broken back-invalidate would produce.  So each word
 * now NAMES ITSELF:
 *
 *     value = (physical_line_address | pass) ^ MAGIC
 *
 * Lines are 16 B aligned, so the low nybble is free to carry the version (pass
 * 0..4).  XOR by MAGIC is not decoration: without it the stored value would BE an
 * address, so an address leaking out of an address path into a data path would look
 * like perfectly valid data.  With the key, only data that was genuinely stored
 * decodes to a sane (address|pass).
 *
 * Decoding a failure:  d = observed ^ MAGIC
 *     d & ~0xf == this line   -> our store was lost (d & 0xf gives which version)
 *     d & ~0xf == some other  -> THAT line's data landed here; the low nybble says
 *                                which version of it
 *     d looks like neither    -> never-stored garbage
 *
 * IT MUST MISS TO BE TESTED AT ALL.  The injector arms on L2 line FILLS.  A first
 * version hammered ONE line, which fills once and then hits in the L1D forever --
 * zero snoops fired and it "passed" without testing anything.  So the RMW walks a
 * WORKING SET larger than the L2 -- not the L1D.  Sizing it past the 4 KB L1D was
 * not enough: the injector arms on L2->DRAM fills, so an L1D miss that HITS in the
 * 1 MB sim L2 (BIG_SIM_L2, LG_L2_NUM_SETS=16) arms nothing, and a 64 KB set again
 * produced zero snoops.  4 MB overflows the L2, so every iteration reaches DRAM,
 * every fill arms a snoop, and each line is read-modify-written while snoops take
 * it away.
 *
 * ORACLE: each line is checked AT THE START OF EVERY PASS before being rewritten,
 * not just at the end.  Checking only the final value cannot tell a store that never
 * landed from a line that reached the right value and was then REVERTED (the L2
 * merging a pre-store copy over a good one): both end one version short.
 *
 * Checked through the UNCACHED alias as well, so a correct-looking cached read
 * cannot mask a wrong value in memory.
 *
 * Prints 'P' on success, or 'C' followed by EIGHT 8-digit hex fields:
 *   badlines firstaddr expected observed dramwrong  zerobucket lostbucket misroutebucket
 * The last three classify EVERY failure, not just the first: garbage = badlines
 * - (zero + lost + misroute).
 *
 *   build: make -C tests/dma
 *   run:   ./obj_dir/henry_tb --kernel tests/dma/rmw_snoop.elf --maxcyc 200000000
 */
    .set noreorder
    .set noat
    .globl _start
    .text

/* register map -- written down because a previous version lost an hour to $t9 being
 * both the loop address register and a scratch, and to the pass-entry check and the
 * verify loop sharing one "first bad address" register:
 *   $s0 cached base   $s1 uncached base  $s2 MAGIC        $s3 kseg0->PA mask
 *   $s4 line count    $s5 (unused)       $s6 pass count   $s7 bad-line count
 *   $t8 pass          $t0 index          $t1 cached addr  $t2 PA scratch
 *   $t3 expected      $t4 observed       $t9 uncached addr
 *   $v0 first bad addr $v1 first bad observed  $a0 first bad expected
 *   $a1 uncached value of first bad line       $a2 capture flag
 *   $a3 magic-halt reg
 *   $gp zero-bucket   $sp lost-bucket   $fp misroute-bucket
 *     (bare metal: no stack is used, so $sp/$fp/$gp are free counters)
 *   puthex clobbers $t3 (input), $t5, $t6, $t7, $at, $ra
 */
_start:
    lui   $s0, 0x8830          /* working set, CACHED   (kseg0) = phys 0x08300000 */
    lui   $s1, 0xa830          /* same set,    UNCACHED (kseg1)                   */
    lui   $a3, 0xbfd0          /* magic-halt register = phys 0x1fd00000           */
    lui   $s2, 0xa5a5          /* MAGIC: low half zero so a raw dump stays legible
				* -- the value reads as the address with a marked
				* top half, and the version in the low nybble  */
    lui   $s3, 0x1fff
    ori   $s3, $s3, 0xffff     /* kseg0/kseg1 VA -> PA */

    lui   $s4, 0x0004          /* 0x40000 = 262144 lines x 16 B = 4 MB */
    li    $s6, 4               /* passes over the whole set */
    move  $s7, $zero           /* bad-line events */
    move  $v0, $zero           /* first failing address (0 = none captured) */
    li    $v1, 0xdead          /* ... value observed there   (sentinel: 0 is a
				* legal observation, so it cannot double as
				* "never captured") */
    li    $a0, 0xdead          /* ... value expected there */
    li    $a1, 0xdead          /* ... value via the uncached alias */
    move  $a2, $zero           /* "capture the next uncached read" flag */
    move  $t2, $zero           /* lines also wrong via the uncached alias -- counted
				* in $s5 below; $t2 reused as scratch after */
    move  $s5, $zero           /* wrong-in-DRAM-too count */
    move  $gp, $zero           /* bucket: read as ZERO (store never landed) */
    move  $sp, $zero           /* bucket: OWN line, older version */
    move  $fp, $zero           /* bucket: ANOTHER line's data (misroute) */

    /* ---- seed: every line gets version 0, tagged with its own address ---- */
    move  $t8, $zero
    move  $t0, $zero
zloop:
    sll   $t1, $t0, 4
    addu  $t1, $s0, $t1        /* cached VA of this line */
    and   $t2, $t1, $s3        /* -> PA */
    or    $t2, $t2, $t8        /* | version 0 (line is 16B aligned) */
    xor   $t3, $t2, $s2        /* ^ MAGIC */
    sw    $t3, 0($t1)
    addiu $t0, $t0, 1
    bne   $t0, $s4, zloop
    nop

    /* ---- passes 0..3: verify version $t8, then write version $t8+1 ---- */
oloop:
    move  $t0, $zero
loop:
    sll   $t1, $t0, 4
    addu  $t1, $s0, $t1
    and   $t2, $t1, $s3
    or    $t2, $t2, $t8
    xor   $t3, $t2, $s2        /* expected = (PA | pass) ^ MAGIC */

    lw    $t4, 0($t1)          /* the read of the read-modify-write */
    nop
    /* CHECK BEFORE MODIFYING.  COUNT, do not halt: stopping at the first bad line
     * reports exactly one failure no matter how many there are, which once made a
     * systematic fault look like a single unlucky line. */
    beq   $t4, $t3, ok
    nop
    addiu $s7, $s7, 1
    bal   classify             /* bucket it: zero / lost / misrouted / garbage */
    nop
    bne   $v0, $zero, ok       /* keep only the FIRST, with its own expected value */
    nop
    move  $v0, $t1
    move  $v1, $t4
    move  $a0, $t3
ok:
    /* write the next version -- also repairs the line, so later passes stay
     * meaningful after a failure */
    and   $t2, $t1, $s3
    addiu $t5, $t8, 1
    or    $t2, $t2, $t5
    xor   $t3, $t2, $s2
    sw    $t3, 0($t1)

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
     * At 0x88800000, past the 4 MB working set (0x88300000-0x886fffff), so it cannot
     * alias any line under test in DRAM -- only in the cache, which is the point. */
    lui   $t6, 0x8880
    lui   $t7, 0x0002          /* 0x20000 = 131072 lines = 2 MB */
    move  $t0, $zero
floop:
    sll   $t1, $t0, 4
    addu  $t1, $t6, $t1
    lw    $t4, 0($t1)          /* read only: the fill is what evicts */
    nop
    addiu $t0, $t0, 1
    bne   $t0, $t7, floop
    nop

    /* ---- verify: every line must hold version $s6, tagged with its own addr ---- */
    move  $t0, $zero
vloop:
    sll   $t1, $t0, 4
    addu  $t1, $s0, $t1        /* cached */
    and   $t2, $t1, $s3
    or    $t2, $t2, $s6
    xor   $t3, $t2, $s2        /* expected final value */

    lw    $t4, 0($t1)
    nop
    beq   $t4, $t3, vok
    nop
    /* count, do not halt -- the last pass's stores have no pass-entry check after
     * them, so this loop is the ONLY place a final-pass loss shows up */
    addiu $s7, $s7, 1
    bal   classify
    nop
    bne   $v0, $zero, vok
    nop
    move  $v0, $t1
    move  $v1, $t4
    move  $a0, $t3
    li    $a2, 1               /* capture this line's UNCACHED value below.  A
				* pointer compare cannot work here -- the uncached
				* address differs from the cached one by construction */
vok:
    /* NO cache op here on purpose.  A `cache 0x15` would (a) exercise the very
     * coherence machinery under test, confounding the result, and (b) force a
     * writeback before the uncached read, so "wrong in DRAM" would measure
     * DRAM-after-a-flush rather than DRAM as it actually stands. */
    sll   $t9, $t0, 4
    addu  $t9, $s1, $t9        /* uncached alias of the same line */
    lw    $t4, 0($t9)
    nop
    beq   $a2, $zero, notfirst
    nop
    move  $a1, $t4
    move  $a2, $zero
notfirst:
    beq   $t4, $t3, vok2
    nop
    addiu $s5, $s5, 1          /* wrong in MEMORY too, not just in cache */
vok2:
    addiu $t0, $t0, 1
    bne   $t0, $s4, vloop
    nop

    /* ---- census ---- */
    beq   $s7, $zero, pass
    nop
    li    $t0, 0x43            /* 'C' */
    mtc0  $t0, $7
    nop
    move  $t3, $s7
    bal   puthex               /* how many lines went wrong */
    nop
    move  $t3, $v0
    bal   puthex               /* first failing address */
    nop
    move  $t3, $a0
    bal   puthex               /* value expected there */
    nop
    move  $t3, $v1
    bal   puthex               /* value actually found -- XOR by MAGIC to name its
				* true owner and version */
    nop
    move  $t3, $s5
    bal   puthex               /* how many were wrong in DRAM as well */
    nop
    move  $t3, $gp
    bal   puthex               /* bucket: read as ZERO */
    nop
    move  $t3, $sp
    bal   puthex               /* bucket: own line, older version (lost store) */
    nop
    move  $t3, $fp
    bal   puthex               /* bucket: ANOTHER line's data (misroute) */
    nop
    b     halt
    nop

pass:
    li    $t0, 0x50            /* 'P' */
    mtc0  $t0, $7
    nop
    b     halt
    nop

/* classify the bad value in $t4 for the line at cached address $t1.
 * The whole point of the self-describing encoding: a wrong value NAMES its owner.
 *   observed == 0            -> the store never landed anywhere (DRAM still empty)
 *   owner == this line       -> our store was lost, an older version survived
 *   owner == another line    -> that line's data was misrouted here  <-- coherence
 *   otherwise                -> never-stored garbage
 * clobbers $t5/$t6/$t7/$at, updates $gp/$sp/$fp */
classify:
    bne   $t4, $zero, cnotz
    nop
    addiu $gp, $gp, 1
    jr    $ra
    nop
cnotz:
    xor   $t6, $t4, $s2        /* decode */
    li    $at, 0xfffffff0
    and   $t7, $t6, $at        /* owner PA (version stripped) */
    and   $t5, $t1, $s3        /* this line's PA */
    bne   $t7, $t5, cother
    nop
    addiu $sp, $sp, 1          /* own line, wrong version -> lost store */
    jr    $ra
    nop
cother:
    /* inside the working set (0x08300000 .. 0x086fffff) => a real misroute */
    lui   $at, 0x0830
    sltu  $t5, $t7, $at
    bne   $t5, $zero, cgarb
    nop
    lui   $at, 0x0870
    sltu  $t5, $t7, $at
    beq   $t5, $zero, cgarb
    nop
    addiu $fp, $fp, 1
cgarb:
    jr    $ra
    nop

/* prints $t3 as 8 hex nybbles; clobbers $t5/$t6/$t7/$at */
puthex:
    li    $t5, 8
    move  $t6, $t3
hexlp:
    srl   $t7, $t6, 28
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
