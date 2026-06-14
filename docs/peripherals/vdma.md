---
title: VDMA — Virtual DMA (graphics/GIO master)
status: draft / future-work (MAME-reference)
source: SGI IP22 Virtual DMA spec (vdma.pdf)
---

# VDMA — Virtual DMA (Henry block spec)

> Intro: VDMA = the MC's GIO/graphics DMA master that DMAs directly from USER VIRTUAL addresses, walking the
> CPU's page tables via its OWN 4-entry PTEBase µTLB (separate from the 48-entry JTLB but R4000-PTE-compatible).
> NOT needed for headless boot; NOT the SCSI/enet path (that's HPC3). Non-coherent on uniprocessor R4000 ->
> reinforces Henry's mandatory cache ops. Legend ✅ = confirmed against spec/MAME, ⚠️ = subtle / easy-to-miss.

The "FastForward" project DMA engine that lives **inside the MC** (Memory Controller). Its job: move
variable-sized blocks between **user-space main memory** and the **graphics/GIO subsystem**, with the block
described by *user virtual addresses* that the engine translates on the fly. Optimised for the graphics
library `v3f()` call (ship a 3-float / 12-byte vertex to the pipe). Authored by Karim Abdalla & James Tornes,
Draft 1.5 (1992).

## Role in Henry  (future-work; graphics-only; uniprocessor = no snoop)
- ⚠️ **Not boot-critical.** Henry boots headless: GIO slots bus-error as "no device" (see `gio64`), there is no
  graphics card, so nothing ever programs the VDMA descriptor registers. VDMA can be a no-op / unimplemented
  decode and IRIX still boots. This doc exists because the block is architecturally interesting (a DMA engine
  with its own page-table walker) and because it *confirms* Henry's cache-coherence contract.
- ✅ **Distinct from HPC3.** VDMA is the **graphics/GIO** master and the only DMA path that touches *virtual*
  addresses + page tables. The real SCSI / Ethernet / PBUS DMA (the boot-critical I/O) is **HPC3**, which is
  pure-physical scatter-gather — see `hpc3`. Don't conflate them.
- ⚠️ **Henry is uniprocessor R4000.** Cache snooping in VDMA is an **R4000MP-only** feature (the large package).
  r9999 / Henry never get hardware snoop, so the engine is **non-coherent** and software cache ops are
  load-bearing (see Cache coherence below).

## Address translation — the PTEBase µTLB + hardware page-table walker
The novel feature: the engine translates user virtual addresses *itself*, page-by-page, so the OS no longer has
to pre-translate + lock-down a long physical descriptor list per transfer. Flow:

```
 user virtual addr  ──split──>  VPNhi  +  VPNlo  +  page-offset
                                  │
                  VPNhi ── associative lookup ──> 4-entry PTEBase µTLB (CAM)
                                  │  hit -> PTEBase[25:6] (phys base of that page table) + V
                                  ▼
        PTE_addr = PTEBase  indexed by  VPNlo     (one memory indirection)
                                  │  HW reads the PTE from DRAM
                                  ▼
                          PTE  ── decode ──>  PFN  (+ valid / dirty bits)
                                  │
              physical addr = PFN | page-offset   ──> DMA the data
```

- **The µTLB** (`GIO_TLBHI[n]` / `GIO_TLBLO[n]`, n = 0..3). Each PTEBase maps one ~2 MB-aligned slice of user
  VA (a single user page table). 4 entries -> 4 such slices resident without a miss. ⚠️ The µTLB is
  **software-loaded and software-maintained**: the DMA engine *reads* it but never modifies it; the CPU sets the
  hardware-valid `V` bit when writing an entry and must *clear* it when the mapping goes stale (context switch,
  unmap). It is **separate from the CPU's 48-entry JTLB** but walks the *same* R4000 page tables in DRAM.
  - `GIO_TLBHI[n]`: `VPNhi[31:21]` (CAM tag), rest zero. Which VA bits form VPNhi depends on page size (GIO_CTL).
  - `GIO_TLBLO[n]`: `PTEBase[25:6]`, `V[1]` (hw-valid). ⚠️ Remaining bits read as zero.
- ✅ **PTE format is R4000-compatible.** "The format of GIO_TLBLO is chosen for maximum compatibility with the
  R4000 (MIPS II & III) EntryLo format." That's the key Henry reuse hook — the walker can share the core's
  existing EntryLo/PTE decode rather than inventing a second one.
- **Geometry from `GIO_CTL`** (set once at boot): `Page Size` (CTL[1]) 0=4 KB / 1=16 KB; `PT Size` (CTL[0])
  0=4 B/PTE / 1=8 B/PTE (so VPNlo indexes the right stride); `Cache Size` (CTL[3:2]) = L line size 16·2^x.
- **`GIO_CTL.Xlate` (CTL[8])** gates the whole thing. Set (the normal user-mode case) -> `GIO_MEMADR` is a
  **virtual** address and goes through the µTLB+walker. Clear -> `GIO_MEMADR` is taken as a **physical** address
  directly (kernel-only debug / OS-initiated DMA to a known physical block). The top bit of GIO_MEMADR is
  ignored in the virtual case.
- **Four fault causes** (reported in `GIO_CAUSE`, also mirrored read-only in `GIO_RUN[3:0]`):
  1. **PTEBase miss** — VPNhi not in the µTLB. Engine interrupts the CPU (or, optionally, the CPU re-loads the
     µTLB) and the transfer is restarted.
  2. **TLB miss** (`CAUSE[1]`) — the PTE itself is missing/invalid at the end of the lookup.
  3. **Page Fault** (`CAUSE[0]`) — the user data page is not resident.
  4. **Clean** (`CAUSE[2]`) — a DMA *write* (GIO->memory) hit a page marked clean (so the OS can do
     dirty-bit/COW bookkeeping before the write lands).
  All four are **restartable**: the descriptor registers hold enough state to resume; the CPU services the fault
  then re-asserts `GIO_STDMA.Start` to continue.

## Cache coherence  (non-coherent on uniprocessor; snoop = R4000MP-only)
⚠️ **This is the load-bearing part for Henry, even though VDMA itself is future-work.** The spec lays out two
coherence options and explicitly scopes one of them out for the uniprocessor:
- **Snoop** (the engine watches the CPU's cache) — `GIO_MODE.Snoop` (MODE[5]) requests it, but it exists
  **only on R4000MP**. Henry / r9999 is uniprocessor R4000: there is **no snoop hardware**.
- **Flush** (software keeps memory and cache consistent) — the only option on a uniprocessor. The R4000 cache
  ops are **privileged**, so the DMA is set up/managed inside a **system call**.
- ✅ Therefore the writeback-vs-invalidate split is **architecturally mandated, not an IRIX quirk** (vdma.pdf
  p.1–2, 7):
  - **DMA-in** (device -> memory, GIO->memory write): after the transfer, **`cache Hit-Invalidate-D`** the target
    lines (no writeback — the DMA'd data is the truth; writing back stale cache lines would clobber it).
  - **DMA-out** (memory -> device, memory->GIO read): before the transfer, **`cache Hit-WB-Invalidate-D`** so
    dirty lines are flushed to DRAM and the engine reads current data.
- This is the *same* coherence story as HPC3 (which has zero coherence hardware) — see the cache/coherence notes
  in `hpc3` and the chip-registers digest. Henry modeling DMA as direct-to-DRAM + honoring those exact L1d ops =
  correct, with **zero coherence hardware**.

## Descriptor register set  (a register set, not an in-memory linked list)
⚠️ Unlike HPC3's in-memory descriptor chain, a VDMA "descriptor" *is* the set of MC registers below. Once a DMA
starts they implicitly hold the running state, so the whole transfer is **context-switchable** (read them out /
write them back to save/restore). It is a **2D strided/zoom blitter** over *virtual* memory.

| Register | Fields | Notes |
|---|---|---|
| `GIO_MEMADR` (RW) | Memory Address[31:0] | next mem addr (virtual unless Xlate=0); written plain = "don't set defaults" |
| `GIO_MEMADRD` (RW) | Memory Address[31:0] | write **also loads the default descriptor** (Table 2) + clears Byte/Zoom counts — the "kick a simple DMA in few writes" path |
| `GIO_SIZE` (RW) | Line Count[31:16], Line Width[15:0] | #scan lines remaining; bytes per scan line |
| `GIO_STRIDE` (RW) | Line Zoom[25:16], Stride[15:0] | Stride is **signed** (negative = x-axis reflect); Line Zoom = vertical zoom replication |
| `GIO_ADR` (RW) | GIO Address[31:0] | phys addr of the GIO device; write does **not** start DMA |
| `GIO_ADRS` (RW) | GIO Address[31:0] | write-only alias of GIO_ADR that **starts the DMA** |
| `GIO_MODE` (RW) | Long[6] Snoop[5] Dir[4] Fill[3] Sync[2] Mode[1:0] | see below |
| `GIO_COUNT` (RW) | Zoom Count[25:16], Byte Count[15:0] | down-counters, context-switch state only |

`GIO_MODE` fields: **Mode[1:0]** 00 = DMA read (mem->GIO), 10 = DMA write (GIO->mem), X1 = accumulation
(unimplemented). **Long[6]** = use the GIO bus time-slice (long burst) vs the CPU slice. **Snoop[5]** = R4000MP
snoop (n/a on Henry). **Dir[4]** = scan-line address increment (1) / decrement (0). **Fill[3]** = on a memory
write, use `GIO_ADR` itself as the source *data* (constant fill, GIO device not involved). **Sync[2]** = delay
start until the external `DMASYNC` pin (vertical-retrace, anti-flicker). The transfer loop is the nested
linecount→zoomcount→bytecount walk with `stride`/`linewidth` address arithmetic (vdma.pdf p.15).

**Kernel-only control registers** (`GIO_CTL` page, protected for security):
- `GIO_MASK` / `GIO_SUBST` — per-bit clamp on the user-supplied GIO physical address: where MASK[i]=1 the engine
  substitutes SUBST[i] for the user's bit, so user-mode can only reach the GIO range the OS allows.
- `GIO_CAUSE` — interrupt cause: Complete[3], Clean[2], TLB miss[1], Page Fault[0]; CPU clears by writing zeros.
- `GIO_CTL` — TLimit[29:20] (max GIO-bus cycles held before re-arbitration), SLimit[16:12] (R4000SC snoop lines),
  DecSlv[9], **Xlate[8]**, IntMask[4] (masks only Complete), Cache Size[3:2], Page Size[1], PT Size[0].

**Run/start (unprotected, user-visible):**
- `GIO_STDMA.Start` (bit0, RW) — CPU sets to begin / **restart-after-fault**; clears to stop (response not
  instantaneous — engine winds down to a save-able point).
- `GIO_RUN` (R only) — `Run` (bit4) polled to tell if a transfer is in flight; `[3:0]` mirrors the CAUSE cause
  bits. ⚠️ A Cause bit and Run can both read 1 transiently (fault set before the engine fully halted).

## Software model  (system-call DMA on uniprocessor; kick-off; restartable on fault)
- ✅ On a uniprocessor R4000 (Henry), VDMA is a **system call** (the cache ops are privileged, and the OS wants
  to swap in another process rather than spin). The R4000MP user-mode-DMA path needs snoop and does not apply.
- **Kick-off (short transfer):** load the default descriptor via `GIO_MEMADRD`, then `GIO_SIZE`, then the
  `GIO_ADRS` write that starts it — a `v3f()` DMA is just **2–3 register writes**.
- **Synchronization:** the program **polls `GIO_RUN.Run`** (the MC stalls that read until the transfer / snoop
  completes), or the OS takes the maskable **Complete** interrupt and reschedules.
- **Fault path:** on any of the four faults the engine stops with full state in the descriptor registers; the
  CPU services it (load a µTLB entry, page in, set dirty) and **re-asserts `GIO_STDMA.Start`** to resume from
  exactly where it stopped. Context switch = read out all descriptor regs, restore later.

## Henry implications / future model  (what Henry would add to model VDMA)
If/when Henry grows a graphics device and someone wants VDMA:
1. **GIO-DMA state machine in the MC** running the nested linecount/zoomcount/bytecount blitter loop over
   `GIO_MEMADR`/`GIO_SIZE`/`GIO_STRIDE`/`GIO_MODE`, sourcing/sinking on the GIO64 bus as a long-burst master.
2. **4-entry PTEBase µTLB (CAM) + hardware page-table walker**, gated by `GIO_CTL.Xlate`. ✅ **Reuse the r9999
   core's existing R4000 PTE/EntryLo decode** — GIO_TLBLO is deliberately EntryLo-compatible — rather than a
   second decoder. Software loads/invalidates the µTLB; HW only reads it.
3. **Restartable fault path**: latch the four causes into `GIO_CAUSE`/`GIO_RUN`, stop at a save-able boundary,
   resume on `GIO_STDMA.Start`. All descriptor state lives in the (already context-switchable) registers.
4. **Non-snooping**: model the engine as **direct-to-DRAM** and rely entirely on the L1d cache ops
   (`Hit-Invalidate-D` after DMA-in, `Hit-WB-Invalidate-D` before DMA-out). No snoop logic, no coherence
   hardware — uniprocessor-correct, and identical to the HPC3 contract.

This block reinforces (does not introduce) Henry's coherence rule: the cache-op discipline that makes HPC3
correct is the *same* discipline VDMA's spec mandates, and the spec says so explicitly for the uniprocessor.

## Sources
- `~/code/sgi/docs/indy_docs/ip22/vdma.pdf` — SGI "Virtual DMA Specification", FastForward Project, Draft 1.5,
  Feb 13 1992 (Abdalla, Tornes). §2.1 cache coherency, §2.3 + §3.3 PTEBase µTLB / why-in-HW, §5.2 Table 1
  descriptor registers + Table 2 default descriptor, §5.3 Tables 3–4 control registers, §5.4 Table 5 µTLB entry
  format (EntryLo-compatible).
- `~/code/r9999/IP22_CHIP_REGISTERS.md` — VDMA section (FUTURE WORK) + coherence findings #8/#9; cross-checked
  against this session's MAME reverse-engineering.
- Related Henry docs: `gio64` (the bus VDMA masters; bus-error-on-empty headless), `hpc3` (the real SCSI/enet
  DMA path; same zero-coherence-hardware + mandatory cache-ops contract).
