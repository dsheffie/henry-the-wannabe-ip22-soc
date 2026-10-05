---
title: CPU integration (r9999)
status: draft (MAME-validated)
---

# CPU integration — r9999 in Henry

> r9999 presents **PRId = R4400 (`0x0440`: imp `0x04`, rev `0x40`)** → IRIX takes the **R4000/R4400
> baseline path** (default UTLB/exception handlers, `*_r4000` clocks, Watch regs cleared; all
> r4600/r5000/RM/r10k code is dead for us). `Config` advertises 16 KB I$/D$ with **16-byte lines**
> (`DB=0`) and **no secondary cache** (`SC=1`). The integer / 64-bit / system / atomic ISA is
> **COMPLETE** for IRIX 6.5.22, the **FP subsystem is DONE** (Gap 1), `cache` is honored (Gap 2), and
> the `wirepda` TLB fault is fixed (Gap 3) — **all three gaps are CLOSED and IRIX boots to multi-user
> on Henry silicon**. The analysis below was validated against IRIX 6.5.22 driven in MAME
> (`indy_4610` = r4600be / mips3); it is kept as the record of *why* each piece is needed.
> Henry is a pseudo-IP22 "wannabe Indy" SoC; r9999 is the CPU core (git submodule, @ `5c89b70`).

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
  flush-wired — see Gap 2), `sync`. CP0 writes take effect **at retire**, and all CP0 reads/writes
  (including the TLB ops and `eret`) are ordered by a single CP0 sequence number, so wrong-path or
  nullified `mtc0`s never change CP0 (see [r9999 microarchitecture](r9999-microarchitecture.md)).
- **Atomics:** `ll/sc/lld/scd`.

The kernel runs **no FP arithmetic at all** (no `add.*/sub.*/mul.*/div.*/sqrt/abs/neg/c.*`), so an
FP ALU is **not required to boot** — see Gap 1.

---

## Gap 1 — FP subsystem  (CLOSED — full COP1, regfile + moves + ld/st + a real FP ALU + HW div/sqrt)

**Status: CLOSED.** The FP subsystem is **fully implemented** in r9999 (`main`): the FP regfile,
all moves, FP load/store, `Status.FR`/`Status.CU1` with lazy-FPU CpU, FP-exception delivery, AND a
**real FP ALU** — add/sub/mul/compare/converts in hardware, **div/sqrt on the shared iterative
divider** (`uni_divider.sv`), with denormal operands/results + any undecoded COP1 op **E-trapped to the
OS soft-float emulator**. This goes well past the boot-minimum (which was just
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

**Real FP ALU (also done):** a unified single/double `fpu_add` (add+sub) + `fpu_mul` (mul), fixed
**4-cycle** latency (`FPU_LAT=4`), honoring `FCSR.RM`; a unified `fpu_compare` (all 16 `C.cond`);
`abs/neg/mov`; plus the converts above. **`DIV.{S,D}` / `SQRT.{S,D}`** run in hardware on
`uni_divider.sv` — the same iterative unit as the integer divides (one op in flight, wired into
`exec.sv` as `d0`). **Denormal operands/results and any undecoded COP1 op** raise
**Unimplemented-Op (E)** → FP Exception (ExcCode 15, `FCSR.Cause.E`) → the **OS soft-float emulator**
(linux-mips `math-emu` / the IRIX equivalent); the catch-all `FP_UNIMPL` is **trap-and-emulate, not
SIGILL**. IEEE flags go to `FCSR.Cause` on a trap or accumulate in the sticky `FCSR.Flags` otherwise.
FP branches `BC1T/F/TL/FL` are implemented. (Until the unified divider landed, div/sqrt were also
E-punted to soft-float.)

**Validation:** `tests/fpu/*` co-sim clean + directed; the FPU Linux kernel boots to `/init`
(lazy-FPU, no "orphaned FPU"); an `awk` double-precision self-test ran correctly on Henry **silicon**
at FPU bring-up (when `sqrt` still went via soft-float). The FPU is part of every henry build; the
current bitstream (r9999 `5c89b70`, `ENABLE_DEBUG_WATCHPOINT` on) closes at **WNS +0.120 ns @ 100 MHz**
(see [FPGA stats](fpga_stats.md)). See `r9999/FPU_PORT_STUDY.md`, `r9999/FPU_ROUNDING_EXCEPTIONS.md`.

---

## Gap 2 — CLOSED: `cache` is fully decoded + flush-wired  (was a latent NOP bug)

r9999 has separate **L1i + L1d** over a shared 128 KB L2 that is **transparent to software** (hidden
from the kernel via `Config.SC=1` → kernel sees "R4000PC", so all ~30 static secondary/L2
`cache_sel=2/3` sites are gated out — confirmed **0 dynamic**; no L2 modeling needed). It is *not*
snooped by DMA on Henry — see the last bullet below. The live coherence axis is **L1i vs.
D-side stores**: the kernel **writes code** through L1d/L2 (runtime CPU patching at boot —
`R4000_jump_war`/`mtext_fixup`; loadable modules — `doelfrelocs`), and L1i then holds a **stale**
copy. So the I-cache `cache` ops **must be honored, not NOP'd**.

`cache` (op `0x2f`) is executed **5.2 M times** over a 120 s boot; four primary ops = 99.94%. Decode:
`op = instr[20:16]`, `cache_sel = op[1:0]` (0=I,1=D,2=SD,3=SI), `operation = op[4:2]`.

**Implemented in r9999** (`decode_mips.sv` op `0x2f`; `core.sv` serialize path; `l1i.sv` / `l1d.sv`):

- ✅ **Fully decoded** (no blanket-NOP) and **kernel-mode-gated** — a user-mode `cache` decodes to a
  **Coprocessor-Unusable** fault.
- ✅ **Primary-D Hit ops** — Hit-Invalidate (`0x11`), Hit-WB-Invalidate (`0x15`), Hit-WB (`0x19`) —
  are **memory uops** (`CHINV`/`CHWBINV`/`CHWB`): AGU → LSU → L1D, **translated by the D-TLB** like a
  load (IRIX invalidates *mapped* K2SEG buffer-cache lines before DMA; the old path masked
  `VA & 0x1fffffff`, wrong for mapped EAs → stale superblock → `EWRONGFS`). Hit-Invalidate drops the
  line **without** writeback (the DMA-in case). They are admitted only at the ROB head.
- ✅ **Every other `cache` op** is a serializing `CACHE_OP` handled at the ROB head (`CACHE_FLUSH`
  state): **I-cache ops → a whole-L1i flush** (the correct over-approximation — the I-cache is never
  dirty; the L2 flush is chained after it), and **other D-cache ops (Index-type) → a per-line
  writeback/invalidate** (`flush_cl`) at `EA & 0x1fffffff`. This is what makes runtime CPU patching /
  module loads code-coherent. Index-Store-Tag / Fill are therefore *not* no-ops; they fold into these
  two over-approximations (r9999's caches reset clean, and cache size comes from `Config`, not a tag
  probe).
- ✅ **Every L1D flush starts from a drained L1D** — the CACHE line op, the whole-cache flush, the
  injected page ops and the DMA invalidate all wait for `w_l1d_drained` (no queued or owed requests,
  both pipe stages empty, no retired store pending). Without that, a flush could consume a fill
  response as a flush beat and wedge the next `DRAIN`/`EXCEPTION_DRAIN` (an IRIX hang on silicon,
  fixed in r9999 `5c89b70`).
- **Henry-only: injected flushes for ARM-side DMA.** Because Henry's SCSI/ENET data is moved by the
  ARM, the SoC can also *inject* flushes into the core like an interrupt: `XFLUSH` (whole L1D + L2)
  and the page ops `XPG_WBINV` / `XPG_INV`, driven by AXI control writes from the ARM driver (see
  [Architecture](architecture.md)). IRIX on Henry needs these on top of its own `cache` ops.

---

## Gap 3 — CLOSED: wired-TLB / `wirepda` spurious fault

**Symptom (historical):** r9999 faulted on the `jr $ra` return from `wirepda` (kernel `mlsetup` path).
**MAME ground truth: real HW takes NO miss here** — both the return fetch and the delay-slot PDA store
resolve through a **global wired entry**, so r9999 was faulting *spuriously*.

**The golden wired PDA entry** (captured at the `tlbwi` inside `tlbwired`, `0x88004c28`):
`EntryHi VA = 0xFFFFFFFF_FFFFA000` → `PA = 0x0838E000`, **valid, dirty, cached, GLOBAL** (matches any
ASID), wired in **slot 0**, `Wired = 8` (slots 0–7 reserved). The PDA store target `0xFFFFA240` hits
this same global wired entry.

**Resolution (all in r9999 `main`):**

1. **High-kseg3 VA match** — the TLB now compares the **full `VPN2 = va[39:13]` plus region
   `R = va[63:62]`** (Sail `tlbEntryMatch`), with `EntryHi` holding the full VPN2/R written by
   `mtc0`/`dmtc0`. This supersedes the interim "match the low 19-bit VPN2 only" workaround (`e451d50`);
   see [r9999 microarchitecture — The TLB](r9999-microarchitecture.md#the-tlb-translation-datapath).
2. **`tlbwr` respects `Wired`** — `Random` counts down and wraps from `Wired` back to 47
   (`exec.sv`: `n_random = (r_random==r_wired) ? (N_TLB_ENTRIES-1) : (r_random-1)`), so wired slots
   are never replaced.
3. **Global/ASID** — the match term is `(asid == ASID) | (g0 & g1)`, gated by a per-slot
   "written" bit rather than `(v0|v1)`.

**Tests:** `tests/tlb/test_wired.S` installs two wired entries, hammers `tlbwr` 64×, and checks both
still translate (covers "`tlbwr` never replaces a wired slot" and "a wired entry resolves a load").
A directed test of a *global wired entry at a high kseg3 VA across ASID changes* (the exact
`wirepda` shape) is still not in the suite; IRIX booting through `mlsetup` on every run is the
de-facto coverage.

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
  pure hint — correctness never depends on it. r9999 **decodes it as a NOP** in kernel mode.
- **PageMask:** **not RAZ/WI** — the kernel writes `PageMask=0` before each `tlbw` and reads it back;
  it must **hold its value**. IRIX boot is **4 KB-only** (3000 boot TLB writes, 100% `PageMask=0`), but
  r9999 now implements **variable page sizes (4 KB–16 MB)** in both TLB CAMs and the micro-ITLB anyway
  (Linux with large pages needs it).
- **TLB size:** 48 dual-entry JTLB (matches R4000/R4400/R4600/R5000); r9999's 48-entry CAM matches.
  Use the **R4000 blind-`tlbwr` refill** path; ensure the CAM tolerates a **duplicate write**
  (last-wins/overwrite) rather than asserting a machine-check.
- **Physical address width:** IRIX on IP22 needs 29 bits (512 MB ceiling); the highest PA the kernel
  forms is the device/PROM region `0x1f000000–0x1fffffff`. r9999 carries **36-bit** physical addresses
  (`PA_WIDTH=36`); a TLB PFN beyond that raises an Address Error on the D-side.
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
| **`cache` op decode + I/D flush wiring** | **DONE** — was `cache`→NOP (latent bug) | **Gap 2 CLOSED** — full op-field decode, kernel-gated (user → CpU); D Hit-ops = D-TLB-translated LSU ops; I-ops → whole-L1i flush; other D-ops → per-line `flush_cl` |
| **FP regfile 32×64b + `Status.CU1/FR` (FR=1)** | **DONE** (`fp_regfile.sv`; FR R/W reset 1, CU1 R/W reset 0, FIR=R4000) | **Gap 1.1 — CLOSED** |
| **FP moves** `mtc1/mfc1/dmtc1/dmfc1`, `cfc1/ctc1` | **DONE** (full exec) | **Gap 1.2 — CLOSED** |
| **FP load/store** `lwc1/swc1/ldc1/sdc1` (precise BD-slot faults) | **DONE** (precise BD-slot faults) | **Gap 1.3 + 1.7 — CLOSED** |
| **`cvt.s.l` / `cvt.d.l`** | **DONE** (full convert set, not just these 2) | **Gap 1.4 — CLOSED** |
| **CU1 → CpU (Cause 11)** | **DONE** (COP1 with CU1=0 → CpU, `Cause.CE=1`) | **Gap 1.5 — CLOSED** |
| **FP Exception (Cause 15)** | **DONE** (`FCSR.Cause.E` delivery) | **Gap 1.6 — CLOSED** |
| **Precise EPC + `Cause.BD` on delay-slot FP mem ops** | **DONE** | **Gap 1.7 — CLOSED** |
| **Wired-slot protection / `wirepda` high-kseg3 VA** | **DONE** — Random wraps at `Wired`; full VPN2+R match | **Gap 3 CLOSED** (`tests/tlb/test_wired.S`) |
| Count/Compare timer | implemented (drives the IRIX/Linux tick) | — |
| WatchLo/WatchHi | **DONE (`272360d`)** | — |
| `wait` | decoded as NOP | — (PRId-gated out anyway) |
| PageMask holds value | **DONE** (R/W; variable page sizes 4 KB–16 MB implemented) | — |
| FP ALU (add/sub/mul/cmp/cvt/div/sqrt) | **DONE** (`fpu_add`/`fpu_mul`/`fpu_compare` + converts in HW; div/sqrt on `uni_divider`) | — (denormals + undecoded COP1 → E-trap to soft-float) |

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
  (written before div/sqrt moved onto `uni_divider.sv`).
