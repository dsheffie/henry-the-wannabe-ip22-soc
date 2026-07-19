---
title: FPU (COP1) — what r9999 implements
status: implemented (MAME-validated workload)
---

# FPU (COP1) — implementation

> r9999 **presents a working COP1 (FPU)**: a clustered/banked FP register file, the full move and
> FP load/store plumbing, a real arithmetic datapath (unified single/double add/sub + multiply,
> compare, and converts in hardware), FP branches, and the IEEE/FCSR exception model. It is validated
> **booting an FPU Linux kernel to `/init`** with lazy-FPU (`Status.CU1`) and **running a double-precision
> self-test on henry silicon** (an `awk` arithmetic test: `22/7`, `3.5*2.0`, `sqrt(2)`, `exp(1)` — all
> correct). The histograms below come from booting real IRIX 6.5.22 in MAME (`indy_4610`, `-nodrc`
> interpreter) with a COP1-instruction histogram compiled into `mips3.cpp`; they remain accurate as the
> **workload context** — they show *what FP work the OS actually issues*, and r9999 covers all of it
> (the few ops not in the HW datapath — div/sqrt — trap to the OS soft-float emulator). This pairs with the
> **`Status.FR`** finding in [Cache, coherence & TLB](coherence-cache-tlb.md#cp0-timekeeping-misc).

## Why the FPU is on the boot path

- **`Status.FR=1` is load-bearing — and implemented.** `DMTC1` (64-bit GPR→FPR move) is the single
  most-frequent COP1 op (48,951 / 37%) — that's FR=1 context save/restore of the 32×64-bit register file.
  r9999's `fp_regfile.sv` is FR=1 (32 independent 64-bit registers); `Status.FR` is R/W (resets 1) and the
  FR=0 (o32) case is handled by decode-force (odd-reg compute / doubleword ops → Reserved Instruction;
  singleword `lwc1`/`mtc1`/`swc1`/`mfc1` half-merge/extract via the even reg).
- **Early kernel = moves only; userland = real math — both covered.** A 3 s (early-kernel) capture is
  ~100% MFC1/MTC1; once userland runs, genuine single/double arithmetic appears. r9999 runs both: the move
  plumbing *and* a real FP datapath, so it boots past early kernel into userland FP without a stub.

## Boot COP1 histogram (120 s boot → 131,884 COP1 ops)

| Category | Count | % | how r9999 handles it |
|---|---:|---:|---|
| **Moves / control** — MTC1/MFC1/DMTC1/DMFC1/CFC1/CTC1 | 80,306 | 60.9% | regfile + FCR31 (FCR rename domain) |
| **Single-precision** (`fmt=S`) math + compare | 25,147 | 19.1% | unified `fpu_add`/`fpu_mul`/`fpu_compare` (S) |
| **Double-precision** (`fmt=D`) math + compare | 15,347 | 11.6% | same unified add/mul/compare (D) |
| **BC1** FP conditional branches | 9,839 | 7.5% | FCR cc bit → branch resolution |
| **Int→FP converts** (`fmt=W/L`) | 1,245 | 0.9% | `fpu_i2f` (CVT.D.W / CVT.S.W / CVT.D.L) |

Moves dominate, but ~31% (40,333 ops) is real FP work — and r9999 has the datapath for it.

## The op set r9999 implements

Union of all nonzero op funcs observed (with the hottest counts) — **all of these are covered**, either
by the hardware datapath or (div/sqrt) by the soft-float trap:

- **Arithmetic (HW):** `ADD.S` (12,974), `ADD.D` (702), `MUL.S` (2,757), `MUL.D` (439), `SUB.S/D`,
  `ABS.D`, `NEG.S`, `MOV.S` (287), `MOV.D` (10,083). Add/sub and multiply are the unified single/double
  `fpu_add` and `fpu_mul` units (fixed 2-cycle latency, `fmt` selects S/D, FCSR.RM rounding); abs/neg/mov
  are single-cycle bit-twiddles.
- **Divide (soft-float):** **`DIV.D` (128 — double divide is exercised)** is *not* in the HW datapath —
  r9999 raises the Unimplemented-Op (E) FP exception (see below) and the OS soft-float emulator computes it.
- **Convert / round (HW):** `CVT.D.S`, `CVT.S.D`, `CVT.D.W` (502), `CVT.D.L` (672), `CVT.S.W`,
  **`TRUNC.W.D` (2,349)**, `TRUNC.L.D` (538) — single-cycle `fpu_f2i`/`fpu_i2f`/`fpu_f2f`.
- **Compare (HW):** `C.LT.{S,D}` (C.LT.S = 6,819, the hottest compare), `C.LE.{S,D}` (C.LE.S = 2,070),
  `C.EQ.{S,D}` — `fpu_compare` implements **all 16 `C.cond` predicates** and writes the FCR cc bit.
- **Branch (HW):** `BC1{T,F}` plus the `BC1{TL,FL}` likely-variants, off the FCR cc bit.

### Previously "deferrable" ops — handled via soft-float trap, not omitted

**`SQRT.S/.D`, `DIV.S`, and `CEIL/FLOOR/ROUND.{W,L}`** had zero hits in a full IRIX boot, so an earlier
plan deferred them. They are now **all handled**: the CEIL/FLOOR/ROUND converts are in the HW `fpu_f2i`
datapath (rm-selectable W/L variants), and **divide and square-root — plus any COP1 op the decoder does
not recognize — raise the Unimplemented-Op (E) FP exception** (`FCSR.Cause.E`, FP Exception **ExcCode 15**)
so the **OS soft-float emulator** (linux-mips `arch/mips/math-emu`; the IRIX equivalent) runs them. The
catch-all `FP_UNIMPL` uop means an unimplemented COP1 op is **trap-and-emulate, never SIGILL**.

## FP loads/stores & COP1X (MADD/MSUB)

Counted separately (different primary opcodes). **FP load/store traffic dwarfs the COP1 ops** — 452,790
load/stores vs 131,951 COP1 ops over the same boot, i.e. moving FP data in/out of the register file is
~3.4× all the arithmetic + moves + branches combined:

| Op | Count | Note |
|---|---:|---|
| `LDC1` (64-bit FP load)  | 207,182 | dominant |
| `SDC1` (64-bit FP store) | 183,519 | |
| `LWC1` (32-bit FP load)  | 43,459  | |
| `SWC1` (32-bit FP store) | 18,630  | |
| **total** | **452,790** | 64-bit (`LDC1`+`SDC1`) = **86%** |

**`COP1X` (MADD/MSUB, opcode `0x13`) = 0** — never executes (R4600 / MIPS III target). r9999 does not
implement COP1X; consistent with the MIPS III baseline, and any such op would fall through `FP_UNIMPL` to
the soft-float trap anyway.

**Combined picture.** Of all **~585K FP-related instructions** on the boot path: **~77% are load/stores**
(86% of them 64-bit), ~14% moves/control, ~7% arithmetic, ~2% branches. So the highest-volume,
must-be-correct FP items are the **64-bit FP load/store datapath** and the **FR=1 64-bit register file** —
both implemented (`lwc1`/`swc1`/`ldc1`/`sdc1` with precise BD-slot faults; the banked `fp_regfile.sv` with
a dedicated memory bank for FP loads). Arithmetic is a small minority of the traffic but is also fully
built (unified add/mul, compare, converts), so r9999 is correct across the whole histogram, not just the
hot path.

## Methodology

`mips3.cpp` (the `indy_4610` maincpu, legacy `mips3` interpreter) carries file-static histograms dumped at
`device_stop()`:

- `g_cop1_hist[fmt][func]` incremented at `case 0x11 /*COP1*/` — the table above.
- `g_cop1x_hist[func]` at `case 0x13 /*COP1X*/`, and `g_fpls_hist[]` at the LWC1/LDC1/SWC1/SDC1 cases —
  the section above.

Reproduce: rebuild MAME (`make -j`), then boot to exit:

```sh
cd ~/code/chd-dumper/irix652_download
SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy ~/code/mame/mame indy_4610 -gio64_gfx xl24 \
  -hard1 irix65.chd -rompath indy_4610/ -nodrc -video none -sound none -nothrottle \
  -seconds_to_run 120 2> boot.log
grep -E 'COP1_HIST|COP1X_HIST|FPLS_HIST' boot.log
```

See [Methodology](methodology.md) for the broader MAME-oracle recipe.

## Sources

- MAME `indy_4610` booting IRIX 6.5.22 (the oracle), COP1/COP1X/FP-load-store histogram hooks in
  `~/code/mame/src/devices/cpu/mips/mips3.cpp` (uncommitted instrumentation).
- The `Status.FR` transition finding — [Cache, coherence & TLB](coherence-cache-tlb.md).
- r9999 FPU RTL: `~/code/r9999/` — `fp_regfile.sv` (clustered/banked FP RF), `fpu_add.sv` / `fpu_mul.sv`
  (unified single/double add-sub / multiply), `fpu_compare.sv` (all 16 predicates), `fpu_f2i.sv` /
  `fpu_i2f.sv` / `fpu_f2f.sv` (converts), `uop.vh` (FP uop set incl. `FP_UNIMPL` / div / sqrt E-trap),
  `exec.sv` (FR/CU1/FCSR + FP issue), `decode_mips.sv` (COP1 decode, FR=0 force, CU1 gate). Validated by
  `tests/fpu/*` (co-sim clean + directed), an FPU Linux boot to `/init`, and a double self-test on henry
  silicon; the FP-complete branch is synthesized separately (not the default synth path) and meets timing @ 100 MHz.
