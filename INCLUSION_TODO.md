# inclusive-l2 — state on park, 2026-08-10

Branch parked to go chase Dhrystone config on `main`. Read this before resuming.

## The headline: everything measured before r9999 `b271ce1` was measuring an inert mechanism

l1d.sv's snoop engine did

```systemverilog
t_snp_clear = t_snp_won;     // ~16 lines BEFORE t_snp_won was computed
...
t_snp_won = ~(t_mark_invalid | ...);
```

in one `always_comb`. Blocking assignments run in order, so `t_snp_clear` always read
its `1'b0` default and the valid-bit clear (`else if(t_snp_clear)`) never fired. **The
L1D acked back-invalidates it never performed.** Fixed in r9999 `b271ce1`.

Consequences — do NOT trust these earlier results:
- the "full 300M IRIX boot, no panic" was clean *because nothing was invalidated*;
- `snoop_hit` frozen at 56 across every config;
- "inclusion did not reduce DMA staleness vs snoop-only" — so the 17.5%-orphan
  hypothesis behind this whole branch is **untested**, not refuted;
- "STALE-HIT 344 -> 271" was never real (and was already known not to be a valid
  cross-build metric — `l1d_cacheop` erasures rescale it).

## Where it actually stands

| config | result | what it proves |
|---|---|---|
| DMA micro, 4KB L1, snoop-only | P | snoop path works |
| DMA micro, 64KB L1, snoop+evict | P (was F) | snoop path works at 64KB |
| IRIX boot, 4KB, snoop-only | no panic, idler @121M, 26.4M insns | **nothing** — see below |
| IRIX boot, 4KB, snoop+**evict** | derail @101.9M, wild PC 0x9fff, `IS_KSEG2` double panic | eviction path is broken |

The clean boot fires inclusion **zero** times (`backinv_entries=0 snoop_req=0
inline_bi=0`; dmaprobe `pushes=0` — the SCSI DMA master never asserts in that tb
config). It shows only that the fix doesn't break an idle path. **`tests/dma/dma_coherence.S`
is the only vehicle that actually validates the snoop path.**

Correct posture: **snoop-only, `ENABLE_L2_EVICT_BACKINV` OFF.** The eviction path needs
the dedicated L1D snoop port before it can be enabled; the derail matches the earlier
bisect that proved it corrupts memory. The fix didn't break it, it stopped hiding it.

## TODO on resume

1. **Re-test the orphan hypothesis.** It was never actually measured. Now that
   invalidation is real, re-run the DMA stale detector — but validate the detector
   first (it has known false positives: lines flagged while their value *increments*
   are CPU stores, not DMA), and note `snoop_log` sits in an `always_comb` so its
   counts are 2x.
2. **Get DMA to actually fire in the boot tb**, or accept the micro as the only
   validation vehicle. `pushes=0` for a whole 300M boot means the boot is not
   exercising this code at all.
3. **PIdx** (task #76) — prereqs now cleared. Design in the `reference_l1_alias_pidx`
   memory note.
4. Eviction path: needs the L1D snoop port. Leave gated until then.

## Two measurement traps that cost most of a session — both the same shape

- The periodic `[incl]` readout's last sample was cycle 74999 while the snoops ran at
  75347-75848. Every "counter reads 0" conclusion described a machine that had not yet
  done anything. **Confirm the counter was SAMPLED AFTER the event.**
- `pres_clr_d` is dominated by the reset `INITIALIZE` walk — exactly `L2_LINES` clears,
  before any bit is ever set. A value equal to `2^LG_L2_LINES` is the walk, not a flush.

Both are the failure mode already recorded in the `feedback_validate_probes_first`
memory: an instrument reporting silence while structurally unable to report anything.
