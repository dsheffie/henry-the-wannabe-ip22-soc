---
title: GIO64 — expansion/graphics bus
status: draft (MAME-validated)
source: SGI GIO bus spec (gio64.pdf); MAME golden reference
---

# GIO64 — Expansion / Graphics Bus (Henry block spec)

> Intro: GIO64 = 0x1f000000–0x1fffffff, sixteen 4 MB slots (graphics = slot 0). For a HEADLESS Henry the key
> behavior is the device-probe: IRIX reads a Product-ID word at each slot base; an empty slot bus-errors; Henry
> can bus-error ALL GIO accesses = "no devices," and IRIX skips graphics/expansion cleanly. Legend ✅/⚠️.

## Role in Henry (and the headless simplification)

GIO64 is SGI's synchronous, multiplexed address-data expansion bus (64-bit AD, ≤40 MHz) used for graphics
(Newport / Express), the HPC3 I/O bridge, and option cards. On real IP22 the bus has masters (graphics DMA,
HPC3 SCSI/enet) and slaves; arbitration, pipelined transfers, parity, ROM, and INT routing all matter.

Henry is **headless** — no framebuffer, no option cards. The bus protocol (the AD-cycle handshake, MASDLY /
SLVDLY / GRXDLY / MEMDLY flow control, tristate turnover, parity) is **not implemented**. What Henry must do is
satisfy IRIX's **boot-time device probe** so the kernel cleanly concludes "no GIO devices present" and moves on.

The whole peripheral collapses to one rule (✅ sufficient for boot):

> **Bus-error every access into 0x1f000000–0x1fffffff** (including the graphics slot). The spec defines an empty
> slot as "read times out → bus-error," and IRIX *uses that bus-error as the negative probe result.* No device
> ever answers, so IRIX finds nothing in every slot and skips graphics + expansion. ⚠️ This is the spec-correct
> "all slots empty," not a hack.

The only register state Henry keeps is the MC `GIO64_ARB` word (R/W storage, see Arbitration) because the PROM
writes it; with no masters on the bus the arbiter never actually runs.

## Address map / slot decoding

Slot N base = `0x1f000000 + N*0x400000`; `board_addr[25:22]` selects the slot, `[21:0]` is the 4 MB offset.
Graphics is always slot 0 (`0x1f000000`). IP22 physically wires only the first few slots; the rest bus-error.

| Slot | Base (abs)   | Size  | IP22 use            | MAME aperture (offset from 0x1f000000) |
|------|--------------|-------|---------------------|----------------------------------------|
| 0    | 0x1f000000   | 4 MB  | graphics (GFX)      | 0x000000–0x3fffff                      |
| 1    | 0x1f400000   | 2 MB* | expansion slot 0    | 0x400000–0x5fffff (EXP0, 2 MB)         |
| 1.5  | 0x1f600000   | 4 MB  | expansion slot 1    | 0x600000–0x9fffff (EXP1)               |
| 2–15 | +N*0x400000  | 4 MB  | unwired → bus-error | —                                      |

⚠️ **Slot-size correction (vs my earlier MAME 2 MB note):** GIO64 slots are natively **4 MB**. The "2 MB"
expansion aperture at 0x1f400000 is the older **GIO32-legacy** option-slot map (0x1f400000 / 0x1f600000 = 2 MB
each); MAME models exactly these three IP22 apertures (GFX 4 MB, EXP0 2 MB, EXP1 4 MB). Both maps are valid for
their bus generation. For Henry the distinction is moot — every aperture bus-errors regardless of size.

⚠️ Note: `0x1f800000–0x1f9fffff` is reserved by SGI for future definition (GIO32 spec §2.11.1); also bus-errors.

## Device probe & identification

The probe is **read-based, NOT a VME-style address probe.** During boot config IRIX does a single **word read**
of the slot's **base address** (the read must be word-width for endian independence). A real device responds in
the slave cycle following the base-address read by driving its **Product Identification Word** onto AD[31:0].

Product Identification Word (read @ slot base; on GIO64 it aliases base+0 AND base+4 — both must return it):

| Bits    | Field             | Meaning                                                                   |
|---------|-------------------|---------------------------------------------------------------------------|
| [7:0]   | Product ID Code   | unique SGI-assigned ID. **Bit [7]=1 ⇒ all 32 bits valid; [7]=0 ⇒ only [7:0] valid** |
| [15:8]  | Product Revision  | manufacturer-assigned rev                                                 |
| [16]    | GIO interface size| 0 = 32-bit, 1 = 64-bit (must be 0 for GIO32/GIO32-bis; may be 0/1 for GIO64) |
| [17]    | ROM present       | 0 = none; 1 = next words are special ROM/serial registers                 |
| [31:18] | Manufacturer code | manufacturer-assigned                                                      |

ROM/serial special registers (GIO64, present only when bit[17]=1; aliased on both word addresses of each dword):
- base+0x00 / +0x04 — Product Identification Word
- base+0x08 / +0x0c — Board Serial Number (optional)
- base+0x10 / +0x14 — ROM Index register (CPU writes 0 to start; auto-increments by 4 on each ROM-Read read)
- base+0x18 / +0x1c — ROM Read register (returns ROM word at current Index; reading bumps Index by 4)

(GIO32 placed these at base+0x4/+0x8/+0xc instead; Henry implements none of them.)

**Empty-slot behavior = the probe's "no" answer:** if no slave responds, the bus times out after **25 µs**
(SLVDLY/MEMDLY/GRXDLY never asserted in reply to the address strobe), the GIO64 arbiter drives the delay line to
end the cycle, and a **bus-error interrupt** is raised to the CPU. IRIX uses exactly this to decide "no device in
this slot." ⇒ **Henry headless: bus-error every GIO access immediately** (no need to model the 25 µs timer —
returning a bus-error synchronously is equivalent from IRIX's standpoint) = "all slots empty." ✅

## Interrupts

Each slot has **3 interrupt/status lines** `INTERRUPT(n)[2:0]` (active-low) plus one **STATUS(n)** line (CPU can
read STATUS but it cannot raise an interrupt). Reservation:

| Line | Reserved for                          |
|------|---------------------------------------|
| INT2 | graphics boards only (high priority)  |
| INT0 | graphics boards only                  |
| INT1 | **option/expansion slot devices**     |

Lines are shared across devices, so drivers must tolerate spurious calls. On IP22 these route through **IOC2**,
are OR'd onto the **GIO/INT3** aggregate, and surface in CP0 `Cause.IP` (exact bit mapping lives in the IOC2
spec). Henry has no GIO devices ⇒ **no GIO interrupt is ever asserted**; nothing to wire beyond the IOC2 input
staying deasserted. ✅

## DMA & endianness

A GIO master moves data **physical, page-bounded** (a transfer may not cross a 4 KB page) to/from main memory.
The byte-count cycle carries device-ID (for MP cache coherence), endian-mode bit, count direction, and CPU
sub-block ordering. On IP22 the MC's **VDMA** graphics engine and HPC3 are the real GIO64 masters running this.

Endianness: GIO64 carries a 32-bit byte address; one byte-count-cycle bit selects big/little endian. **Big-endian
(IRIX default): byte 0 → AD[31:24]** (and for 64-bit, byte 0 → AD[63:56]). Bit numbering is always little-endian
(bit 0 = LSB). Henry implements **no DMA master and no slave data path** ⇒ endianness is irrelevant here. ✅

## Arbitration

GIO64 defines three bus-request classes (§4.5):
- **Real-time** (e.g. audio): highest priority, ≤5 µs per acquisition, requests no more than every 20 µs.
- **Short-burst** (e.g. EISA bridge): preempts long-burst; holds bus ≤1 µs; serviced ~every 4 µs.
- **Long-burst** (graphics DMA, **and the CPU**): preemptable, low priority, can hold the bus for long stretches.

The **CPU is a long-burst device and the default bus master** — when no other device requests the bus, control
falls to the CPU. Arbitration timing is programmed via the MC **`GIO64_ARB`** register (the PROM writes the
class/timing knobs at init). On Henry there are **no other masters**, so arbitration never actually runs; Henry
only needs `GIO64_ARB` to behave as **R/W storage** (PROM writes, reads back the same value). ✅

## Minimum for a Henry IRIX boot

1. **Decode** the range `0x1f000000–0x1fffffff` (all 16 slots + reserved holes). → verify: address hits Henry's GIO block.
2. **Bus-error every access** to it (populated graphics slot included → "all slots empty"). → verify: IRIX probe finds no GIO device in any slot and skips graphics/expansion. ✅
3. **MC `GIO64_ARB`** = plain R/W register (no side effects; no masters → arbiter idle). → verify: PROM write then read returns the written value.
4. GIO interrupt input to IOC2 stays **deasserted** (no devices). → verify: no spurious GIO IRQ during boot.

Everything else — bus protocol/handshake, DMA master sequence, parity, ROM read path, real INT routing — is
deferred until a real GIO device is added (see Open).

## Golden vectors

| # | Access                                  | Henry response                          | Why                                              |
|---|-----------------------------------------|-----------------------------------------|--------------------------------------------------|
| 1 | word read @ 0x1f000000 (gfx slot base)  | **bus-error** (DBE)                     | empty-slot probe → "no graphics"                 |
| 2 | word read @ 0x1f400000 (exp0 base)      | **bus-error**                           | "no expansion 0"                                 |
| 3 | word read @ 0x1f600000 (exp1 base)      | **bus-error**                           | "no expansion 1"                                 |
| 4 | word read @ 0x1fc00000 (unwired slot)   | **bus-error**                           | unwired slot                                     |
| 5 | any write into 0x1f000000–0x1fffffff    | **bus-error**                           | no slave to accept                               |
| 6 | MC `GIO64_ARB` write V then read        | returns **V**                           | R/W storage, no side effect                      |

(All probe reads bus-error ⇒ IRIX device tree shows zero GIO devices ⇒ clean headless boot.)

## Open / not-yet-needed

Implement only when adding a real GIO device:
- **Product Identification Word** responder (drive the ID word on the base-address read; set bit[7] valid, bit[16] size, bit[17] ROM).
- **ROM / serial registers** (Index + Read auto-increment path at base+0x10/+0x18, dword-aliased).
- **INT line routing** (graphics INT2/INT0, option INT1 → IOC2 → INT3 → CP0).
- **DMA master sequence** (physical page-bounded transfers, byte-count cycle fields, big-endian byte0→AD[31:24]).
- Full **bus protocol** (AD address/byte-count/data cycles, MASDLY/SLVDLY/GRXDLY/MEMDLY flow control, tristate
  turnover dead cycles, pipelined-vs-nonpipelined timing, parity ADP/VLD_PARITY) and **real arbitration** with
  BREQ/BGNT/BPRE.

## Sources

- SGI **GIO Bus Specification** v1.1 (gio64.pdf): §2.7 bus time-outs (25 µs), §2.9–2.10 interrupts + Product ID
  Word, §2.11.1 option-slot address ranges, §4.2 byte addressing, §4.4.4 GIO64 time-outs, §4.5 arbitration
  (three request classes), §4.8 GIO64 interrupts, §4.12 device ID / serial / ROM registers.
- `r9999/IP22_CHIP_REGISTERS.md` — GIO64 section (16×4 MB slots, read-based probe + bus-error-on-empty, the
  4 MB-vs-GIO32-legacy-2 MB correction, headless "bus-error everything" simplification, MC `GIO64_ARB`).
- **MAME** golden reference: `src/devices/bus/gio64/gio64.{cpp,h}` (GFX/EXP0/EXP1 apertures 0x000000/0x400000/
  0x600000), `src/mame/sgi/indy_indigo2.cpp` (0x1f000000–0x1f9fffff GIO64 map), `src/mame/sgi/ip20.cpp` (slot
  aperture comments).
