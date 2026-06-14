---
title: FPU (COP1) — what IRIX boot needs
status: draft (MAME-validated)
---

# FPU (COP1) — boot requirements

> r9999 must present a working **COP1** (FPU). A full IRIX 6.5.22 boot to multiuser issues **~132K COP1
> ops** *plus* **~453K FP load/stores** (FP data movement is the bulk of FP work — see below). Of the COP1
> ops ~61% are register/control moves, but the remainder is **real FP arithmetic** (from userland —
> init/rc/daemons), so a multiuser boot needs a **functioning FP datapath**, not just the regfile
> plumbing. **MADD/MSUB (COP1X) never appear** → optional. Every number here was measured by booting real IRIX in MAME (`indy_4610`, `-nodrc`
> interpreter) with a COP1-instruction histogram compiled into `mips3.cpp`. This pairs with the
> **`Status.FR`** finding in [Cache, coherence & TLB](coherence-cache-tlb.md#cp0-timekeeping-misc).

## Why the FPU is on the boot path

- **`Status.FR=1` is load-bearing.** `DMTC1` (64-bit GPR→FPR move) is the single most-frequent COP1 op
  (48,951 / 37%) — that's FR=1 context save/restore of the 32×64-bit register file. r9999's FP regfile
  must implement FR=1 (32 independent 64-bit registers), with the `FR` bit switching regfile aliasing.
- **Early kernel = moves only; userland = real math.** A 3 s (early-kernel) capture is ~100% MFC1/MTC1.
  Once userland runs, genuine single/double arithmetic appears — so "boot to multiuser" cannot be done
  with a move-only FPU stub.

## Boot COP1 histogram (120 s boot → 131,884 COP1 ops)

| Category | Count | % | r9999 implication |
|---|---:|---:|---|
| **Moves / control** — MTC1/MFC1/DMTC1/DMFC1/CFC1/CTC1 | 80,306 | 60.9% | regfile + FCR31 plumbing, **no datapath** |
| **Single-precision** (`fmt=S`) math + compare | 25,147 | 19.1% | FP datapath |
| **Double-precision** (`fmt=D`) math + compare | 15,347 | 11.6% | FP datapath |
| **BC1** FP conditional branches | 9,839 | 7.5% | FCR31 condition code → branch resolution |
| **Int→FP converts** (`fmt=W/L`) | 1,245 | 0.9% | CVT.D.W / CVT.S.W / CVT.D.L |

Moves dominate, but ~31% (40,333 ops) is real FP work.

## The op set r9999 must implement to boot

Union of all nonzero op funcs observed (with the hottest counts):

- **Arithmetic:** `ADD.S` (12,974), `ADD.D` (702), `MUL.S` (2,757), `MUL.D` (439), `SUB.S/D`,
  **`DIV.D` (128 — double divide is exercised)**, `ABS.D`, `NEG.S`, `MOV.S` (287), `MOV.D` (10,083).
- **Convert / round:** `CVT.D.S`, `CVT.S.D`, `CVT.D.W` (502), `CVT.D.L` (672), `CVT.S.W`,
  **`TRUNC.W.D` (2,349)**, `TRUNC.L.D` (538).
- **Compare:** `C.LT.{S,D}` (C.LT.S = 6,819, the hottest compare), `C.LE.{S,D}` (C.LE.S = 2,070),
  `C.EQ.{S,D}`.
- **Branch:** `BC1{T,F}` (+ likely the `TL/FL` likely-variants).

### Deferrable past boot (zero hits in a full boot)

**`SQRT.S/.D`, `DIV.S`, and `CEIL/FLOOR/ROUND.{W,L}`** never execute during boot. A minimal boot-capable
FPU can omit square-root and single-precision divide and add them later for full userland coverage.

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

**`COP1X` (MADD/MSUB, opcode `0x13`) = 0** — never executes (R4600 / MIPS III target). **r9999 can omit
COP1X entirely** for boot, and for IRIX userland compiled to the MIPS III baseline.

**Combined picture.** Of all **~585K FP-related instructions** on the boot path: **~77% are load/stores**
(86% of them 64-bit), ~14% moves/control, ~7% arithmetic, ~2% branches. So the highest-volume,
must-be-correct FP items for r9999 are the **64-bit FP load/store datapath** and the **FR=1 64-bit register
file** — *not* the ALU. Arithmetic must work, but it is a small minority of the traffic.

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
- r9999 FPU RTL: `~/code/r9999/` (`exec.sv` FP regfile/FR handling; the FPU datapath).
