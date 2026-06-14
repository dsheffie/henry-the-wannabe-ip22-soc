---
title: CPU integration (r9999)
status: draft (MAME-validated)
---

# CPU integration — r9999 in Henry

> r9999 presents **PRId = R4000 (imp `0x04`)** → IRIX takes the **R4000/R4400 baseline path**
> (default UTLB/exception handlers, `*_r4000` clocks, Watch regs cleared; all r4600/r5000/RM/r10k
> code is dead for us). The integer / 64-bit / system / atomic ISA r9999 already implements is
> **COMPLETE** for booting the IRIX 6.5.22 kernel. The real remaining work is **(1) the FP
> subsystem**, **(2) cache coherence wiring**, and **(3) a wired-TLB / `wirepda` spurious-fault bug**.
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
- **System / CP0:** `mtc0/mfc0/dmtc0/dmfc0`, `tlbr/tlbwi/tlbwr/tlbp`, `eret`, `cache` (today NOP — see
  Gap 2), `sync`.
- **Atomics:** `ll/sc/lld/scd`.

The kernel runs **no FP arithmetic at all** (no `add.*/sub.*/mul.*/div.*/sqrt/abs/neg/c.*`), so an
FP ALU is **not required to boot** — see Gap 1.

---

## Gap 1 — FP subsystem  (boot needs the regfile + moves + 2 converts, NOT an FP ALU)

All FP activity in the kernel is **context save/restore** (the 32 FP regs + FCSR across context
switch / signal delivery) plus exactly **two** long→float converts. Static FP counts: `swc1` 96,
`sdc1` 81, `dmtc1/dmfc1` 65, `mtc1/mfc1` 64, `lwc1` 64, `ldc1` 49, `cfc1` 5, `ctc1` 4, `cvt.s.l` 1,
`cvt.d.l` 1. r9999 today has the FPU **ripped out** (`fp_prf/fp_uq/is_fp = 0` in `exec.sv`; only
vestigial MTC1/MFC1 decode with no execution).

Add, in this order (boot-first; no FP ALU):

1. **FP register file (32 × 64-bit) + `Status.CU1` + `Status.FR`.** `FR=1` **is used** — `FR=0` for
   kernel/idle, **`FR=1` once N32/N64 userland runs** (first seen mid-boot, ~19% of samples by
   multiuser). The regfile must implement true `FR=1` (32 independent 64-bit registers) and have the
   `Status.FR` bit switch the even/odd aliasing — not FR=0-only pairs.
2. **FP moves:** `mtc1/mfc1/dmtc1/dmfc1`, `cfc1/ctc1` (FCR31 / FCR0=FIR). Replace the vestigial
   decode with real execution.
3. **FP load/store:** `lwc1/swc1/ldc1/sdc1`.
4. **`cvt.s.l` / `cvt.d.l`** — the only two FP "math" ops the kernel executes.
5. **CU1 → Coprocessor-Unusable (Cause ExcCode 11):** extend the existing CpU mechanism (already
   present for CP0) to gate on `~Status.CU1`, so lazy-FP enable/disable works (reuse the `CPU` uop).
6. **FP Exception (Cause ExcCode 15) delivery** — the `fp_intr` handler path.
7. **PRECISE exceptions on delay-slot FP loads/stores.** When an FP load/store **in a branch delay
   slot faults**, the kernel's `emulate_branch`/`emulate_{lwc1,ldc1,swc1,sdc1}` decodes the branch,
   emulates the memory op, and resumes. This is **NOT an FP-arithmetic emulator** — it is a precise
   BD-slot fixup, and it **requires r9999 to deliver the correct EPC + `Cause.BD`** (the
   `WAIT_FOR_SERIALIZE_IN_FAULTED_DELAY_SLOT` corner). Get this contract right or the fixup spins.

**Not needed to boot:** the FP adder/multiplier/divider/compare. User FP can be **E-punted** to
IRIX's softfloat via the Unimplemented (E) trap (`_cvtd_s`, `_cvts_d`, … softfloat converters exist
in the kernel). Add a real FP ALU **later**, for userland, validated vs softfloat (see
`r9999/FPU_PORT_STUDY.md`, `FPU_ROUNDING_EXCEPTIONS.md`).

---

## Gap 2 — caches are incoherent → `cache`→NOP is a LATENT BUG  (see coherence doc)

r9999 has separate **L1i + L1d** over an L2 that **is** transparent/coherent (hidden from the kernel
via `Config.SC=1` → kernel sees "R4000PC", so all ~30 static secondary/L2 `cache_sel=2/3` sites are
gated out — confirmed **0 dynamic**; no L2 modeling needed). The live coherence axis is **L1i vs.
D-side stores**: the kernel **writes code** through L1d/L2 (runtime CPU patching at boot —
`R4000_jump_war`/`mtext_fixup`; loadable modules — `doelfrelocs`), and L1i then holds a **stale**
copy. So the I-cache `cache` ops **must be honored, not NOP'd**.

`cache` (op `0x2f`) is executed **5.2 M times** over a 120 s boot; four primary ops = 99.94%. Decode:
`op = instr[20:16]`, `cache_sel = op[1:0]` (0=I,1=D,2=SD,3=SI), `operation = op[4:2]`.

Decode / handling obligations:

- **Fully decode the op field** (do not blanket-NOP); **privilege-check** (`cache` is kernel/CU0-only
  → user mode = Coprocessor-Unusable); compute EA = `base + signext(offset)`.
- **I-cache ops (`0x10` Hit-Inval-I, `0x00` Index-Inval-I, and the I-side of any others): drive the
  existing `l1i.sv` `flush_req`/`FLUSH_CACHE`.** The I-cache is never dirty, so a **whole-L1i flush is
  a correct over-approximation of EVERY I-cache op** — simplest wiring: any I-cache `cache` op →
  `flush_req`. **This is the one real obligation today** — a *wiring* task; the flush HW already
  exists in `l1i.sv`.
- **D-cache ops (`0x01`/`0x15`/`0x11`/`0x19`): NOP-safe while there is no incoherent DMA** (no snoop
  logic in L1d; I/O is backdoored). **IF** incoherent DMA is ever added behind L1d, honor the
  invalidate-vs-writeback distinction — esp. **`0x11` D-Hit-Invalidate must invalidate WITHOUT
  writeback** (DMA-in); do not promote it to writeback-invalidate or you corrupt DMA'd data.
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
| **`cache` op decode + I-cache flush wiring** | decode missing (`cache`→NOP, **latent bug**) | **Gap 2** — decode full op field; any I-cache op → `l1i` `flush_req`; D-ops NOP-safe |
| **FP regfile 32×64b + `Status.CU1/FR` (FR=1)** | absent (FPU ripped out) | **Gap 1.1** — add, with FR aliasing switch |
| **FP moves** `mtc1/mfc1/dmtc1/dmfc1`, `cfc1/ctc1` | vestigial decode, no exec | **Gap 1.2** — add full exec |
| **FP load/store** `lwc1/swc1/ldc1/sdc1` (precise BD-slot faults) | absent | **Gap 1.3 + 1.7** |
| **`cvt.s.l` / `cvt.d.l`** | absent | **Gap 1.4** (2 converts only) |
| **CU1 → CpU (Cause 11)** | CpU mechanism exists (CP0) | **Gap 1.5** — extend to `~CU1` |
| **FP Exception (Cause 15)** | absent | **Gap 1.6** — add delivery |
| **Precise EPC + `Cause.BD` on delay-slot FP mem ops** | verify | **Gap 1.7** — required for `emulate_*` |
| **Wired-slot protection / `wirepda` high-kseg3 VA** | **spurious fault** | **Gap 3** — clamp Random `[Wired..47]`; fix kseg3 + global/ASID; add directed test |
| Count/Compare timer | required | ensure functional |
| WatchLo/WatchHi | **DONE (`272360d`)** | — |
| `wait` | not decoded | NOP for insurance (PRId-gated out anyway) |
| PageMask holds value (4 KB boot) | verify | must not be RAZ/WI |
| FP ALU (add/sub/mul/div/sqrt/cmp) | absent | **NOT boot-critical** — userland only; E-punt to softfloat |

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
