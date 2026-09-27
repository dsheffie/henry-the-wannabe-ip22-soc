---
title: CPU integration (r9999)
status: draft (MAME-validated)
---

# CPU integration — r9999 in Henry

> r9999 presents **PRId = R4000 (imp `0x04`)** → IRIX takes the **R4000/R4400 baseline path**
> (default UTLB/exception handlers, `*_r4000` clocks, Watch regs cleared; all r4600/r5000/RM/r10k
> code is dead for us). The integer / 64-bit / system / atomic ISA r9999 already implements is
> **COMPLETE** for booting the IRIX 6.5.22 kernel. The **FP subsystem is now DONE** (full COP1 —
> regfile, moves, ld/st, and a real FP ALU; see Gap 1, CLOSED). The real remaining work is **(1)
> cache coherence wiring** and **(2) a wired-TLB / `wirepda` spurious-fault bug**.
> Everything here is validated against IRIX 6.5.22 driven in MAME (`indy_4610` = r4600be / mips3).
> Henry is a pseudo-IP22 "wannabe Indy" SoC; r9999 is the CPU core (git submodule).

Detailed working notes live in the submodule:
`r9999/IRIX_KERNEL_GAPS.md` (static kernel instruction working set) and
`r9999/IRIX_CPU_REQUIREMENTS.md` (MAME ground truth: ARCS handoff, SPB, MC sizing).

---

## What's already complete  (MIPS-III integer / system / atomic set)

Per the gaps-doc headline: **the integer / 64-bit / system / atomic ISA r9999 already implements is
COMPLETE for this kernel** (125 distinct mnemonics, all confirmed decoded+executed except the FP set
and `wait`). No action needed for any of:

- **Integer / branch (MIPS I/II):** the full ALU/shift/mul/div set, all **branch-likely** forms
  (`beqzl`…`bgezl`), `j/jal/jr/jalr`, unaligned `lwl/lwr/swl/swr`, `mfhi/mflo/mthi/mtlo`, `teq`,
  `break`, `syscall`.
- **64-bit (MIPS III):** `ld/sd/lwu/ldl/ldr/sdl/sdr`, `daddu/daddiu/daddi/dsubu/dnegu`, the full
  `d*` shift family, `dmult/dmultu/ddiv/ddivu`.
- **System / CP0:** `mtc0/mfc0/dmtc0/dmfc0`, `tlbr/tlbwi/tlbwr/tlbp`, `eret`, `cache` (fully decoded +
  flush-wired — see Gap 2), `sync`.
- **Atomics:** `ll/sc/lld/scd`.

The kernel runs **no FP arithmetic at all** (no `add.*/sub.*/mul.*/div.*/sqrt/abs/neg/c.*`), so an
FP ALU is **not required to boot** — see Gap 1.

---

## Gap 1 — FP subsystem  (CLOSED — full COP1, regfile + moves + ld/st + a real FP ALU)

**Status: CLOSED.** The FP subsystem is **fully implemented** in r9999 (`main`): the FP regfile,
all moves, FP load/store, `Status.FR`/`Status.CU1` with lazy-FPU CpU, FP-exception delivery, AND a
**real FP ALU** — add/sub/mul/compare/converts in hardware, with div/sqrt + any undecoded COP1 op
**E-trapped to the OS soft-float emulator**. This goes well past the boot-minimum (which was just
the regfile + moves + the two long→float converts). For reference, the kernel's static FP working set
is mostly **context save/restore** (the 32 FP regs + FCSR across context switch / signal delivery)
plus exactly **two** long→float converts. Static FP counts: `swc1` 96, `sdc1` 81, `dmtc1/dmfc1` 65,
`mtc1/mfc1` 64, `lwc1` 64, `ldc1` 49, `cfc1` 5, `ctc1` 4, `cvt.s.l` 1, `cvt.d.l` 1.

Implemented (all present in r9999 `main`):

1. **FP register file (32 × 64-bit) + `Status.CU1` + `Status.FR`.** Clustered/banked
   `fp_regfile.sv`. `Status.FR` is R/W and **resets to 1** (FR=1 = 32 independent 64-bit regs for
   n32/n64); FR=0/o32 even/odd pairing is forced via decode (`fr` gates the odd-reg / half-select
   path). `Status.CU1` is R/W and **resets to 0** (lazy-FPU). `FIR` (FCR0) reads back the
   R4000-family FPU id.
2. **FP moves:** `mtc1/mfc1/dmtc1/dmfc1`, `cfc1/ctc1` (FCR31 / FCR0=FIR) — full execution, not
   vestigial decode.
3. **FP load/store:** `lwc1/swc1/ldc1/sdc1`, with precise delay-slot faults (item 7).
4. **Converts:** the kernel's `cvt.s.l` / `cvt.d.l` plus the **full** convert set — `CVT.S.D`/`D.S`,
   `CVT.{W,L}.{S,D}` (incl. `ROUND`/`TRUNC`/`CEIL`/`FLOOR`), `CVT.{S,D}.{W,L}` — via a single-cycle
   f2i/i2f/f2f path (`fpu_f2i.sv`/`fpu_i2f.sv`/`fpu_f2f.sv`).
5. **CU1 → Coprocessor-Unusable (Cause ExcCode 11):** a COP1 op with `Status.CU1=0` raises CpU
   (`Cause.CE=1`), so lazy-FP enable/disable works.
6. **FP Exception (Cause ExcCode 15) delivery** — `FCSR.Cause.E`; the `fp_intr` handler path.
7. **PRECISE exceptions on delay-slot FP loads/stores.** When an FP load/store **in a branch delay
   slot faults**, the kernel's `emulate_branch`/`emulate_{lwc1,ldc1,swc1,sdc1}` decodes the branch,
   emulates the memory op, and resumes. This is **NOT an FP-arithmetic emulator** — it is a precise
   BD-slot fixup, and it **requires r9999 to deliver the correct EPC + `Cause.BD`** (the
   `WAIT_FOR_SERIALIZE_IN_FAULTED_DELAY_SLOT` corner). r9999 delivers it.

**Real FP ALU (also done):** a unified single/double `fpu_add` (add+sub) + `fpu_mul` (mul), 2-cycle,
honoring `FCSR.RM`; a unified `fpu_compare` (all 16 `C.cond`); `abs/neg/mov`; plus the converts
above. **DIV/SQRT and any undecoded COP1 op** raise **Unimplemented-Op (E)** → FP Exception
(ExcCode 15, `FCSR.Cause.E`) → the **OS soft-float emulator** (linux-mips `math-emu`); the catch-all
`FP_UNIMPL` is **trap-and-emulate, not SIGILL**. Denormal operands/results always trap to E; IEEE
flags go to `FCSR.Cause` on a trap or accumulate in the sticky `FCSR.Flags` otherwise. FP branches
`BC1T/F/TL/FL` are implemented. The "E-punt" to soft-float (planned only for div/sqrt) is the
**shipped** strategy, not a deferral.

**Validation:** `tests/fpu/*` co-sim clean + directed; the FPU Linux kernel boots to `/init`
(lazy-FPU, no "orphaned FPU"); an `awk` double-precision self-test runs correctly on Henry **silicon**
(including `sqrt` via soft-float); the FP-complete branch was synthesized separately and meets timing (the
current henry synth, `ENABLE_DEBUG_WATCHPOINT` on, closes at **WNS +0.096 ns @ 100 MHz**).
See `r9999/FPU_PORT_STUDY.md`, `r9999/FPU_ROUNDING_EXCEPTIONS.md`.

---

## Gap 2 — CLOSED: `cache` is fully decoded + flush-wired  (was a latent NOP bug)

r9999 has separate **L1i + L1d** over an L2 that **is** transparent/coherent (hidden from the kernel
via `Config.SC=1` → kernel sees "R4000PC", so all ~30 static secondary/L2 `cache_sel=2/3` sites are
gated out — confirmed **0 dynamic**; no L2 modeling needed). The live coherence axis is **L1i vs.
D-side stores**: the kernel **writes code** through L1d/L2 (runtime CPU patching at boot —
`R4000_jump_war`/`mtext_fixup`; loadable modules — `doelfrelocs`), and L1i then holds a **stale**
copy. So the I-cache `cache` ops **must be honored, not NOP'd**.

`cache` (op `0x2f`) is executed **5.2 M times** over a 120 s boot; four primary ops = 99.94%. Decode:
`op = instr[20:16]`, `cache_sel = op[1:0]` (0=I,1=D,2=SD,3=SI), `operation = op[4:2]`.

**Implemented in r9999** (`decode_mips.sv` op `0x2f` → `CACHE_OP`; `l1i.sv` / `l1d.sv`):

- ✅ **Fully decoded** (no blanket-NOP) and **kernel-mode-gated** (`in_kernel_mode` → a user-mode
  `cache` does not execute the op); serializing; EA = `base + signext(offset)` is computed into the
  uop (`cache_is_d = insn[16]`, `cache_inval = insn[20:18]==3'b100`).
- ✅ **I-cache ops → `l1i.sv` `flush_req`** — a **whole-L1i flush**, the correct over-approximation of
  every I-cache op (the I-cache is never dirty). This is what makes runtime CPU patching / module
  loads code-coherent.
- ✅ **D-cache ops → `l1d.sv` `flush_cl_req`/`flush_cl_addr`** — a **per-line writeback** of the line
  at the EA (pushing it to L2). **D-Hit-Invalidate** (`cache_inval`, op field `0b100`) drops the line
  **WITHOUT** writeback (the DMA-in case), correctly distinguished from writeback ops.
- **Index-Store-Tag (`0x08`/`0x09`) / Fill (`0x14`): NOP** — r9999's caches reset clean (no power-on
  tag scrub); cache size comes from `Config`, not the tag probe.

---

## Gap 3 — wired-TLB / `wirepda` spurious fault  (MAME-confirmed r9999 bug)

**Symptom:** r9999 faults on the `jr $ra` return from `wirepda` (kernel `mlsetup` path). **MAME ground
truth: real HW takes NO miss here** — both the return fetch and the delay-slot PDA store resolve
through a **global wired entry**, so **r9999 is faulting *spuriously*** (treating a mapped access as a
miss). The fix is in r9999's TLB/Wired/segment/ASID handling, **not** a missing mapping.

**The golden wired PDA entry** (captured at the `tlbwi` inside `tlbwired`, `0x88004c28`):
`EntryHi VA = 0xFFFFFFFF_FFFFA000` → `PA = 0x0838E000`, **valid, dirty, cached, GLOBAL** (matches any
ASID), wired in **slot 0**, `Wired = 8` (slots 0–7 reserved). The PDA store target `0xFFFFA240` hits
this same global wired entry.

**Suspects (fix + verify):**

1. **`tlbwr` not respecting `Wired`.** If Random isn't clamped to `[Wired..47]`, a `tlbwr` between
   `wirepda` and the access can overwrite the wired PDA entry (slot 0) → the access misses → refill
   can't find it (no page-table backing for a wired-only mapping) → spins in EXL. **Clamp Random to
   `[Wired..47]`.**
2. **High-kseg3 VA decode.** Confirm r9999 translates the 64-bit kseg3 VA `0xFFFFFFFF_FFFFA000`
   (sign-extended high segment) through the JTLB rather than mishandling/short-circuiting it.
3. **Global-bit / ASID matching** on a wired entry across ASID changes.

**Test gap (found in `r9999/tests/`):** the wired mechanism is **untested**. `tests/cp0/test_cp0.S`
Test 2 only R/W-tests the `Wired` register; `tests/tlb/test_tlb.S` Step 7 `tlbwr` round-trips with
`Wired=0` (no wired-slot exclusion), Step 8 tests the global bit on a non-wired low-VA entry. **Not
covered:** (a) `tlbwr` never replacing a wired slot; (b) a wired entry resolving a load/store/fetch;
(c) a **global wired entry at a high kseg3 VA resolving across ASID changes** — the exact
`wirepda`/PDA pattern. **Add a directed test** using the golden values above (set `Wired=8`, write the
PDA entry, then fetch/load/store against `0xFFFFA000` under a changed ASID, and prove a `tlbwr` storm
never evicts slot 0).

Cross-ref: `r9999/MAME_QUESTIONS.md` Q1 (full capture + single-step trace; caller `mlsetup`
@ `0x8814a0d0`, return to `mlsetup+0xb4`).

---

## CP0 / misc

- **Count / Compare timer:** steady-state timekeeping is the **on-chip R4000 timer**, not ARCS — the
  handler re-arms `Compare = Count + ~0x25000` per tick (confirmed live; `Count` climbs monotonically
  and wraps). Must be functional.
- **Watch regs (WatchLo/WatchHi, r18/r19): RAZ/WI is sufficient** — already **DONE in r9999 commit
  `272360d`** (functional register: store on `mtc0`, read back on `mfc0`, reset 0; modeled on
  `Compare`). The kernel only ever does two `mtc0 zero` clears in `start`; **no Watch-match hardware
  or ExcCode-23 delivery is required** (the kernel's watchpoint facility is software).
- **`wait`:** **not a real gap.** It is R4600+/MIPS32, absent from the R4000/R4400 ISA; IRIX gates the
  idle WAIT by PRId (`wait_for_interrupt`) and on imp `0x04` returns without ever executing it. It is a
  pure hint — correctness never depends on it. **Decode as NOP for insurance.**
- **PageMask:** **not RAZ/WI** — the kernel writes `PageMask=0` before each `tlbw` and reads it back;
  it must **hold its value**. Boot is **4 KB-only** (3000 boot TLB writes, 100% `PageMask=0`); large-
  page CAM matching is **deferrable past boot**.
- **TLB size:** 48 dual-entry JTLB (matches R4000/R4400/R4600/R5000); r9999's 48-entry CAM matches.
  Use the **R4000 blind-`tlbwr` refill** path; ensure the CAM tolerates a **duplicate write**
  (last-wins/overwrite) rather than asserting a machine-check.
- **Physical address width:** 29 bits (512 MB ceiling); highest PA the kernel forms is the device/PROM
  region `0x1f000000–0x1fffffff`. Cache/TLB physical tags need 29 bits (bits 31:29 always 0).
- **PRId-gated R4000 workarounds:** IRIX applies the R4000 set (`R4000_jump_war`, `init_mfhi_war`, …)
  — generally conservative/harmless on a clean core. **Verify** that the two that assume *buggy* R4000
  behavior — `R4000_jump_war` (page-boundary branch errata) and `init_mfhi_war` (hi/lo read hazard) —
  are harmless no-ops on r9999's clean OOO core (it already enforces precise control flow + correct
  hi/lo).

---

## Boot-critical checklist

| Need | r9999 status | Action |
|---|---|---|
| Integer / branch-likely / unaligned / traps | implemented | — |
| 64-bit MIPS-III (`d*`, `ld/sd`, `ldl`…`sdr`) | implemented | — |
| System CP0 (`mtc0/mfc0/dmtc0/dmfc0`, `tlb*`, `eret`, `sync`, `syscall`, `break`) | implemented | — |
| Atomics (`ll/sc/lld/scd`) | implemented | — |
| **`cache` op decode + I/D flush wiring** | **DONE** — was `cache`→NOP (latent bug) | **Gap 2 CLOSED** — full op-field decode, kernel-gated; I-ops → `l1i` `flush_req` (whole-L1i); D-ops → `l1d` per-line `flush_cl` (+ Hit-Invalidate, no-writeback) |
| **FP regfile 32×64b + `Status.CU1/FR` (FR=1)** | **DONE** (`fp_regfile.sv`; FR R/W reset 1, CU1 R/W reset 0, FIR=R4000) | **Gap 1.1 — CLOSED** |
| **FP moves** `mtc1/mfc1/dmtc1/dmfc1`, `cfc1/ctc1` | **DONE** (full exec) | **Gap 1.2 — CLOSED** |
| **FP load/store** `lwc1/swc1/ldc1/sdc1` (precise BD-slot faults) | **DONE** (precise BD-slot faults) | **Gap 1.3 + 1.7 — CLOSED** |
| **`cvt.s.l` / `cvt.d.l`** | **DONE** (full convert set, not just these 2) | **Gap 1.4 — CLOSED** |
| **CU1 → CpU (Cause 11)** | **DONE** (COP1 with CU1=0 → CpU, `Cause.CE=1`) | **Gap 1.5 — CLOSED** |
| **FP Exception (Cause 15)** | **DONE** (`FCSR.Cause.E` delivery) | **Gap 1.6 — CLOSED** |
| **Precise EPC + `Cause.BD` on delay-slot FP mem ops** | **DONE** | **Gap 1.7 — CLOSED** |
| **Wired-slot protection / `wirepda` high-kseg3 VA** | **spurious fault** | **Gap 3** — clamp Random `[Wired..47]`; fix kseg3 + global/ASID; add directed test |
| Count/Compare timer | required | ensure functional |
| WatchLo/WatchHi | **DONE (`272360d`)** | — |
| `wait` | not decoded | NOP for insurance (PRId-gated out anyway) |
| PageMask holds value (4 KB boot) | verify | must not be RAZ/WI |
| FP ALU (add/sub/mul/cmp/cvt) | **DONE** (`fpu_add`/`fpu_mul`/`fpu_compare` + converts in HW) | — (div/sqrt + undecoded COP1 → E-trap to soft-float, the shipped strategy) |

> Boot-environment note (separate from CPU ISA): a sash-less direct `/unix` boot also needs the ARCS
> shim — SPB @ phys `0x1000` (sig "ARCS"), a 35-entry romvec with a working `GetEnvironmentVariable`,
> entry to `start` (`0x88005960`) with `a0=8, a1=0, a2=0`, and `MEMCFG0/MEMCFG1` @ `0x1fa000c4/0xcc`
> describing Henry's DRAM. That is platform/SoC integration, not CPU ISA — see
> `r9999/IRIX_CPU_REQUIREMENTS.md` (P0-A/B/C). Listed here only so it isn't mistaken for a CPU gap;
> the first observed derail (`0x880059f0`) is the missing SPB, **not** an ISA gap.

---

## Detailed working notes

- `r9999/IRIX_KERNEL_GAPS.md` — static kernel instruction working set (125 mnemonics), FP gap
  analysis, `cache` op histogram, TLB/CP0/PA requirements, PRId support map, console path.
- `r9999/IRIX_CPU_REQUIREMENTS.md` — MAME ground truth: PROM→kernel handoff at `start`, the ARCS SPB +
  romvec layout, and how the kernel sizes RAM via the MC (`MEMCFG0/1`).
- `r9999/MAME_QUESTIONS.md` Q1 — the `wirepda` wired-TLB capture (golden entry + single-step trace).
- `r9999/FPU_PORT_STUDY.md`, `r9999/FPU_ROUNDING_EXCEPTIONS.md` — FP ALU plumbing + E-trap strategy
  for the later userland-FP stage.
