---
title: Cache, coherence & TLB
status: draft (MAME-validated)
---

# Cache, coherence & TLB

> Henry's caches are incoherent: r9999's L1i is **not** kept in sync with D-side stores, and the L2,
> while transparent and coherent, is hidden from software (`Config.SC=1` → kernel sees "R4000PC").
> DMA masters — HPC3 (SCSI/Ethernet) and the MC's VDMA graphics engine — are **NON-coherent in
> hardware** on a uniprocessor R4000 (HW snoop is R4000MP-only). So the `cache` instruction is
> load-bearing: software coherence is mandatory, and r9999 must **honor specific cache ops, not NOP
> them**. Every fact below was measured by booting real IRIX 6.5.22 in MAME (`indy_4610`, `-nodrc`
> interpreter), including C++-instrumented op histograms.

## The coherence contract

Two independent coherence axes, both software-managed:

1. **I-cache vs D-side stores (code writes).** The kernel writes instructions through L1d/L2 and the
   L1i then holds a stale copy. Sources of code writes on the boot path:
   - **Runtime CPU patching** at boot — `R4000_jump_war`, `mtext_fixup_inst`, the UTLB-vector patches
     (`need_utlbmiss_patch`/`utlbmiss_patched`).
   - **Loadable kernel modules** — `doelfrelocs` relocating module text after load.
   - Re-patch of already-executed code (the case early boot can't get lucky on).
   The L2 is coherent, so a *cold* L1i fetch pulls the patched line from L2 correctly; the failure mode
   is a line that was already resident in L1i before the patch. **⇒ I-cache `cache` ops MUST flush L1i.**

2. **D-cache vs DMA.** HPC3 and VDMA master directly to/from physical DRAM with no snoop. The driver
   issues the coherence ops by hand:
   - **DMA-in** (device → memory): `cache Hit-Invalidate-D` *after* the transfer — invalidate the stale
     cached copy **without** writeback.
   - **DMA-out** (memory → device): `cache Hit-Writeback-Invalidate-D` *before* the transfer — push
     dirty lines to DRAM so the device reads current data.
   This split is **architecturally mandated** (vdma.pdf p.1–2,7; hpc3.pdf has zero coherence language),
   not an IRIX quirk. r9999's L1d has no snoop logic today, so while all I/O stays backdoored these
   D-side ops are functionally moot — but the moment real incoherent DMA sits behind L1d, the
   invalidate-vs-writeback distinction becomes correctness-critical (see routing table).

!!! note "External corroboration (independent R4000SC implementation)"

    CYAN's **haterMIPS** — a clean-room R4000SC core for the SGI Indigo **IP20** (Project CYAN, see
    [methodology → related work](methodology.md#related-work)) — reaches the **same** conclusion from the
    CPU side: self-modifying code only works when software issues the full `CACHE` sequence —
    **D-cache Hit-Writeback-Invalidate + I-cache Hit-Invalidate** — exactly axes 1 and 2 above. Its `Config`
    reports `SC=0/SB=11` (a 1 MB / 128 B-line secondary cache) and it implements I$/D$ coherency *only* via
    those `CACHE` ops, no snoop. Two independent implementations agreeing the `cache` op is **load-bearing,
    not NOP-able** is strong evidence the model is right.

!!! question "FAQ: Do we need snoops (hardware cache coherence) in r9999? — **No.**"

    Snooping is a **multiprocessor / coherent-DMA** feature: it exists to keep one cache coherent with another
    bus agent (a second CPU or a snooping DMA engine). Henry is a faithful **uniprocessor** IP22 with
    **non-coherent DMA**, so there is no other agent to snoop and nothing to build. The whole platform does
    **software** cache coherence instead — which is exactly the contract above.

    The evidence is unanimous:

    - **HPC3** (the real SCSI/Ethernet DMA path) has **zero snoop hardware** — it just masters the bus to/from
      physical DRAM; coherence is the driver's job (hpc3.pdf has no coherence language).
    - **VDMA**'s snoop is **R4000MP-only** — a per-transfer `GIO_MODE[5]` bit that exists only on the
      multiprocessor part; on a uniprocessor R4000PC/SC (what r9999 presents as) it is never used, and the
      kernel software-flushes instead (vdma.pdf p.1–2). The MC's `CPUCTRL0.SNOOP_EN` bit is for that same
      MP graphics-DMA path → Henry treats it as a no-op storage bit.
    - **IRIX confirms it dynamically:** the ~5.2M `cache` ops/boot we measured *are* the software coherence —
      the kernel would not issue them if hardware snooped.

    **What r9999 needs *instead* of snoops** is just to **execute the software cache-management ops correctly
    (not NOP them)** — drive the L1i flush on I-cache invalidate (code coherence), and invalidate-*without*-
    writeback on `Hit-Invalidate-D` (DMA-in). See the routing table below. Not building snoop logic is a
    genuine **simplification**, not a shortcut.

    Snoops would only ever be needed if Henry went **multiprocessor** (multiple r9999 cores sharing memory) or
    chose to model **coherent DMA hardware** to spare IRIX the flushes — neither is in scope, and the latter
    would diverge from the real IP22.

## The `cache` instruction — decode & routing

r9999 must **fully decode `cache`** (opcode `0x2f`) and route by the op field — a blanket NOP is a
latent bug. Field decode of the op register field `op = instr[20:16]`:
`cache_sel = op[1:0]` (0=I-primary, 1=D-primary, 2=SD secondary-data, 3=SI secondary-instr);
`operation = op[4:2]`.

**Boot histogram** — C++ instrumentation on MAME's mips3 `case 0x2f`, **5,208,585 cache ops over a
120 s boot**:

| op   | cache / operation                  | boot count  | %      |
|------|------------------------------------|-------------|--------|
| 0x01 | D Index-Writeback-Invalidate       | 1,483,598   | 28.5%  |
| 0x00 | I Index-Invalidate                 | 1,481,976   | 28.5%  |
| 0x15 | D Hit-Writeback-Invalidate         | 1,400,427   | 26.9%  |
| 0x10 | I Hit-Invalidate                   | 839,506     | 16.1%  |
| 0x08 / 0x09 | I/D Index-Store-Tag (cache init) | 1,025 / 1,025 | —    |
| 0x14 | I Fill                             | 512         | —      |
| 0x11 | **D Hit-Invalidate (NO writeback)**| 489         | —      |
| 0x19 | D Hit-Writeback                    | 21          | —      |
| 0x0b | secondary Index-Store-Tag (L2 probe) | 6         | —      |

**Four primary-cache ops = 99.94%.** Secondary/L2 ops are ~0 (just a 6-hit probe). This Indy has no
L2 visible to software (`Config.SC=1`), so the ~30 static `cache_sel=2/3` code sites never execute —
**no L2 modeling needed**.

**Decode/handling obligations:**
- Decode the full op field; **privilege-check** (`cache` is kernel/CU0-only → user mode raises
  Coprocessor-Unusable); compute EA = `base + signext(offset)`.

**Routing table — what Henry must honor vs NOP:**

| op | name | cache_sel | Henry action | why |
|----|------|-----------|--------------|-----|
| 0x10 | I Hit-Invalidate | I | **MUST flush L1i** | code coherence — the one real obligation today |
| 0x00 | I Index-Invalidate | I | **MUST flush L1i** | code coherence |
| any I-side op | — | I | **drive L1i `flush_req`** | L1i is never dirty → a whole-L1i flush is a correct over-approximation of *every* I-cache op; simplest wiring is "any I-cache op → `flush_req`". The flush HW already exists in `l1i.sv` — this is a *wiring* task |
| 0x11 | **D Hit-Invalidate (NO writeback)** | D | invalidate WITHOUT writeback (NOP-safe today) | DMA-in. **CRITICAL: do NOT promote to writeback** or you write a stale/dirty line back over freshly DMA'd data — reintroduces the corruption window |
| 0x15 | D Hit-Writeback-Invalidate | D | writeback + invalidate (NOP-safe today) | DMA-out |
| 0x01 | D Index-Writeback-Invalidate | D | writeback + invalidate (NOP-safe today) | D-side flush |
| 0x19 | D Hit-Writeback | D | writeback (NOP-safe today) | D-side flush |
| 0x08 / 0x09 | I/D Index-Store-Tag | I/D | **NOP** | r9999 caches reset clean — no power-on tag scrub needed (unlike real R4000 silicon); cache *size* comes from `Config`, not the tag probe |
| 0x14 | I Fill | I | **NOP** | same — caches reset clean |
| 0x0b | SI Index-Store-Tag | SI (L2) | **NOP** | no software-visible L2 |

D-cache ops are **NOP-safe while I/O stays backdoored** (no snoop logic, no incoherent DMA behind L1d).
If real incoherent DMA is ever added, honor the invalidate-vs-writeback distinction — especially `0x11`.

## TLB

- **Size:** 48 dual-entry JTLB — identical on R4000/R4400/R4600/R4700/R5000/RM (only R10000/R12000 go
  to 64). r9999's 48-entry CAM matches. `start` sets **`Wired=8`** (slots 0–7 reserved).
- **Boot is 4 KB-only.** 3000 explicit TLB writes during boot → **100% `PageMask=0` (4 KB), zero large
  pages.** Large-page machinery (`large_pages_enable`, `lpage_*`) exists but is on-demand/under-load,
  never triggered by a vanilla boot ⇒ Henry can **boot with a 4 KB-only TLB**; variable-page-size CAM
  matching (16 KB…16 MB) is deferrable past boot. **But `PageMask` is NOT RAZ/WI** — the kernel writes
  `PageMask=0` before each `tlbw` and reads it back; it must hold its value.
- **R4000 vs R5000 refill (Henry = R4000 path):** R4000/R4600 fast refill is a **blind `tlbwr`** (load
  2 PTEs → `mtc0 entrylo0/1` → `tlbwr` → `eret`). R5000 does **`tlbp` first, `tlbwr` only if absent** (a
  guard against a duplicate TLB entry the R5000 mishandles). Henry presents **PRId imp `0x04` = R4000**,
  so it gets the blind-`tlbwr` refill. Just ensure the CAM **tolerates a duplicate write** (last-wins /
  overwrite) rather than asserting a machine-check.

## The wirepda / wired-entry finding

**MAME-confirmed (Q1, 2026-06-13): real HW takes NO miss at `wirepda`'s `jr $ra`; r9999 faulted
spuriously.** This was the VM-init bug that stranded r9999 ~805K cycles into boot.

!!! success "Resolved in RTL (r9999 `tlb.sv`, commit `e451d50`)"

    The root cause was **suspect #2** (high-VA match), now fixed; **suspect #1** (Random clamp) was
    refuted by RTL inspection. End-to-end confirmation ("IRIX boots past the 805K-cycle wall") is the
    remaining check; unit coverage exists (`tests/cheri/tlb/test_tlb_xkseg.s`, `test_tlb_wired.s`).

`wirepda` (@`0x881689b0`) `jal`s `tlbwired` (@`0x88004ba0`) to wire the per-CPU PDA. The golden wired
entry captured at the `tlbwi` inside `tlbwired` (0x88004c28):

```
EntryHi  = 0x00000000_FFFFA000   ; VPN2 for VA 0xFFFFFFFF_FFFFA000, ASID=0x00
EntryLo0 = 0x00000000_0020E39F   ; PFN=0x838E -> PA 0x0838E000; C=3 (cached), D=1, V=1, G=1 (GLOBAL)
EntryLo1 = 0x00000000_00000001   ; V=0 -> odd page INVALID; G=1
PageMask = 0                     ; 4 KB
Index    = 0     Wired = 8
```

So the **PDA is wired in slot 0**: VA `0xFFFFFFFF_FFFFA000` → PA `0x0838E000`, valid, dirty, cached,
**GLOBAL** (matches any ASID).

At the `jr $ra` (0x88168aec), single-stepped on real HW:
- The delay slot (`sw at,0xFFFFA240(zero)`) stores to **PDA+0x240** — hits the global wired entry,
  **no store miss**.
- Returns to **`0x8814a184`** (= `mlsetup+0xb4`, **kseg0 / UNMAPPED**) — clean, **no exception vector,
  Cause=0, no BadVAddr**.

**⇒ r9999 *was* faulting spuriously** — the fix was in r9999's TLB high-VA matching, NOT a missing
mapping (see the resolution box above). Generic xkseg/wired unit tests now exist
(`tests/cheri/tlb/test_tlb_xkseg.s`, `test_tlb_wired.s`), but a **directed regression test for the exact
wirepda scenario** — a *global wired high-kseg3* entry resolving an access *across ASID changes and `tlbwr`
churn* — is still worth adding, since the imported CHERI tests don't combine all three.

**Root cause & fix (the two original suspects, resolved):**

1. **Suspect #1 — `tlbwr` not clamping Random to `[Wired..47]`: REFUTED.** exec.sv resets `Random→47` on
   a `Wired` write (`n_random='d47`), decrements with wrap at `Wired` (`r_random==r_wired ? 47 :
   r_random-1`), and `TLBWR` writes index `r_random` (exec.sv:1965). So `Random ∈ [Wired..47]` always and
   `tlbwr` can never overwrite the wired slots 0–7. *(CYAN's independent haterMIPS implements the same
   clamp — confirming it's the correct behavior, which r9999 already has.)*
2. **Suspect #2 — high kseg3 VA `0xFFFFFFFF_FFFFA000` never matched: ROOT CAUSE, FIXED (`e451d50`).** The
   real asymmetry: `mtc0 EntryHi` stored `VPN2` **zero-extended**, while kseg VAs **sign-extend**
   (`va[63:62]=11`, `va[39:32]=ff`). Comparing the full `va[39:13]`+region against the zero-extended stored
   VPN2 → the wired high-VA entry never hit → spurious refill, EXL=1 spin. **Fix:** match only the low
   19-bit VPN2 (`r_tlb[i].vpn[18:0] == va[31:13]`), ignoring region `R` and `va[39:32]` (tlb.sv:81–88).
   ⚠️ This is a compare-side workaround valid under 32-bit addressing; the cleaner fix is sign-extending
   `VPN2` at the `mtc0 EntryHi` source. Could alias only if true 64-bit/region-distinguished VAs are used —
   not the case on the IRIX boot path.

**Suggested directed test (golden values above):** set `Wired=8`; write the PDA entry
(EntryHi=0xFFFFA000, EntryLo0=0x20E39F, EntryLo1=0x00000001, PageMask=0) at Index 0; churn the TLB with
many `tlbwr` and change ASID; then **store to `0xFFFFFFFF_FFFFA240` and load it back** — must hit
PA `0x0838E240` with no miss. With `e451d50` in place this should now **pass**; it guards against a
regression in the high-VA match (and would catch a re-introduction of the zero-extend asymmetry).

## CP0 timekeeping & misc

- **Steady-state timekeeping = on-chip `Count`/`Compare`** (not ARCS). The handler re-arms
  `Compare = Count + ~0x25000` per tick — confirmed live in MAME.
- **Status.FR (bit 26) IS used.** FR=0 for kernel/idle, **FR=1 once N32/N64 userland runs** (first seen
  mid-boot, ~19% of samples by multiuser). r9999's FP regfile must implement FR=1 (32 independent 64-bit
  registers), not just FR=0 even/odd 32-bit pairs; the FR bit must switch regfile aliasing. (Still no FP
  *arithmetic* in the kernel — this is the regfile mode for context save/restore + userland.)
- **Watch registers (WatchLo/WatchHi, r18/r19): unused → RAZ/WI** (already done in `exec.sv`, 272360d).
  The only references are two `mtc0 zero` clears in `start`; nothing ever programs a watch address, so
  ExcCode 23 never fires. IRIX's watchpoint facility is pure software. Henry needs only a functional
  register (accept `mtc0`/`mfc0` r18/r19 without faulting); no Watch-match HW required.

## Physical address width

- **29 bits observed; 30 bits architectural.** The test Indy measured a max PA of `0x1fffffff` (29 bits)
  only because it had ~16 MB RAM. The MC map (mc.pdf p.22) has a **second 256 MB "High System Memory"
  window at `0x20000000–0x2fffffff`** (kseg-mapped) → a maxed Indy needs **30-bit PA**.
- Low RAM window `0x08000000–0x17ffffff` (256 MB max); kernel/device region up to `0x1fffffff`.
  TLB-mapped PFNs observed only `0x0800_0000`–~`0x0900_0000` (max `0x0881a000`); EntryLo PFN is
  arch-24-bit but only ~17 significant bits are ever used on this platform.
- **The bottom 512 KB `0x0–0x7ffff` ALIASES RAM** (for exception vectors at `0x0`/`0x80`) — Henry must
  alias `0x0`/`0x80` to `0x08000000`/`0x08000080`.
- ⇒ cache/TLB **physical tags need 30 bits** to be safe (29 observed; bits above 30 always 0).

## Detailed working notes

- `/home/dsheffie/code/r9999/IRIX_KERNEL_GAPS.md` — the `cache`-instruction decode requirement + boot
  histogram; the TLB/CP0/physical-address section; Watch-register and Status.FR findings.
- `/home/dsheffie/code/r9999/MAME_QUESTIONS.md` — the Q1 `wirepda` answer (golden wired PDA entry,
  single-step trace, the two suspects, the directed test).
- `/home/dsheffie/code/r9999/IP22_CHIP_REGISTERS.md` — HPC3/VDMA non-coherence (the cache-op split is
  architecturally mandated), MC/IOC2 register maps, physical-address-width correction.
