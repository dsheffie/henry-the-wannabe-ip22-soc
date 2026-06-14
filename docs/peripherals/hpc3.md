---
title: HPC3 — Peripheral/DMA controller
status: draft (MAME-validated)
source: SGI IP22 HPC3 spec (hpc3.pdf); MAME golden reference
---

# HPC3 — Peripheral / DMA Controller (Henry block spec)

> Intro: HPC3 @ phys 0x1fb80000–0x1fbfffff bridges GIO64 to SCSI(×2)/Ethernet/PBUS and holds the ds1386
> RTC/NVRAM + serial EEPROM. Two headline facts up front: (1) DMA is pure-physical scatter-gather with NO
> address map; (2) HPC3 has NO cache coherence — software must flush/invalidate (this is WHY Henry's r9999
> cache ops are mandatory). Legend ✅ = MAME-confirmed / matches our golden reference; ⚠️ = correction,
> known-bug, or gotcha to model carefully.

HPC3 is SGI's third-generation "High Performance Peripheral Controller." Six functional blocks: the 64-bit
GIO64 bus interface, two SCSI ports (WD33C93 or Fujitsu 86603), one Ethernet port (Seeq 8003/8020), the PBUS
controller (boot PROM, battery-backed SRAM, 8 general-purpose DMA channels, 10 chip selects), and the serial
EEPROM interface. HPC3 runs GIO64 at 33 MHz; it is a bus slave for all PIO and a bus master for all DMA.

## Role in Henry

In the Indy/IP22 datapath HPC3 is the **real system-DMA engine** — the path that actually moves disk and
network bytes in and out of DRAM. The MC's VDMA engine is the *graphics* GIO64 master (`v3f()` etc.); HPC3 is
the *peripheral* master and is the one Henry must implement to boot, because it owns the SCSI channel that
reads the root disk and the ds1386 NVRAM that holds the boot environment. It also sits on the IOC2/INT2–INT3
interrupt path back to the r9999 core.

Henry must model HPC3 as: a GIO64 slave for PIO register/PROM/fifo access, and a GIO64 master that walks
descriptor chains and reads/writes **physical DRAM directly with no coherence hardware**.

## DMA model — descriptor format + pure-physical addressing

DMA is **descriptor-based linked-list scatter-gather, and all addresses are PURE PHYSICAL** — there is no
address map, no page table, no translation (this is the key difference from VDMA, which goes through the MC's
DMA map). Software builds a chain of descriptors in DRAM, configures the channel registers + device registers,
then sets the channel's **start-DMA** bit; HPC3 becomes the GIO64 master, fetches the first descriptor, and
walks the chain via the `DP` link until it hits a descriptor with `EOX` set, at which point the channel goes
inactive.

Each descriptor is **3 consecutive 32-bit words, quadword (16-byte) aligned, and must not cross a page
boundary**. "Page" = the smaller of the CPU page and DRAM page (4 KB or 8 KB). Word order is `{BP, BC, DP}`
from low address up:

| Off | Word | Field layout |
|-----|------|--------------|
| 0x0 | `BP` | Memory Buffer **PHYSICAL** address [31:0] — the data buffer in DRAM |
| 0x4 | `BC` | `EOX`[31] `EOXP`[30] `XIE`[29] `RES`[28:24] `IPG`[23:16] `TXD`[15] `RES`[14] `ByteCount`[13:0] |
| 0x8 | `DP` | Next-descriptor **PHYSICAL** address [31:0] (the chain `link`; unused when `EOX` set) |

`BC` field meanings (hpc3.pdf p6–7):

| Field | Bit(s) | Meaning |
|-------|--------|---------|
| `EOX` | 31 | End-of-chain. Last descriptor; channel deactivates after processing it. `DP` ignored. |
| `EOXP` | 30 | End-of-packet (Ethernet only). Exactly one per enet-rx packet. |
| `XIE` | 29 | Interrupt-enable: raise the channel interrupt after this descriptor completes. (Enet: ignored unless `EOXP`.) |
| `IPG` | 23:16 | Inter-packet-gap byte (Ethernet transmit only). |
| `TXD` | 15 | Transmit-done marker (Ethernet transmit only). |
| `ByteCount` | 13:0 | Bytes to transfer for this buffer (max one page). On enet-rx, written back with the actual count. |

Buffer rules: the `BP` buffer is **≤ one page and cannot cross a page boundary**; enet-rx buffers must be
doubleword-aligned. For DMA **write** (memory→device) there are no alignment constraints — HPC3 packs bytes
seamlessly into the fifo. For DMA **read** (device→memory) each buffer's start byte must align with the byte
*after* the end of the previous buffer (buffers need not be contiguous but must *appear* contiguous), because
HPC3 packs device data into the fifo without knowing the buffer seams.

Endianness: each channel has a big/little endian config bit for the data transfer; one **global** config bit
sets the endianness of *all descriptor fetches*. Big-endian IRIX → both 0 (`gio.misc[1] des_endian` = 0).
HPC3 never runs DMA with the GIO64 "count direction = down" bit asserted.

The transfer is two-stage: device↔fifo and fifo↔DRAM (a GIO64 burst). Each channel also has a **flush** bit
(drain remaining fifo bytes to memory and deactivate) and a direction bit (receive/transmit; not present on
the two Ethernet channels, where direction is implicit). Clearing the start bit aborts the current op.

## Cache coherence — NONE in hardware (the mandatory software contract)

⚠️ **HPC3 has zero coherence hardware — no snoop, no invalidate-on-DMA.** The entire spec contains no
coherence language; HPC3 simply masters GIO64 to/from physical DRAM. On Henry's uniprocessor R4000-class
r9999 this means **software is solely responsible** for keeping the L1 D-cache consistent with DMA buffers.
This is the actual hardware path that the r9999 cache-op findings came from, and it is **why Henry's L1d
`cache` ops are mandatory, not optional** (see the coherence doc):

- **DMA-in (device→memory, "read/receive"):** after the DMA completes, software must `cache Hit-Invalidate-D`
  the buffer lines (no writeback) so the stale clean copies in the D-cache are dropped and the next CPU read
  fetches the freshly-DMA'd data from DRAM.
- **DMA-out (memory→device, "write/transmit"):** before starting the DMA, software must
  `cache Hit-Writeback-Invalidate-D` the buffer so dirty CPU writes are pushed to DRAM where HPC3 will read
  them.

Henry's correct model: HPC3 DMA reads/writes DRAM directly (no cache probe), and the r9999 core honors those
L1d cache ops. Zero coherence HW on the HPC3 side is spec-correct — do **not** add snooping.

## I/O sub-map

Offsets from base `0x1fb80000`. (✅ = matches MAME golden ref; ⚠️ = MAME correction.)

| Offset range | Region | Notes |
|--------------|--------|-------|
| 0x00000–0x0ffff | PBUS DMA channel registers | 8 general-purpose PBUS DMA channels |
| 0x10000–0x1ffff | SCSI(HD0/HD1) + ENET DMA channel registers | per-channel descriptor ptr / control / status |
| 0x20000–0x2ffff | **DMA FIFO ports** (doubleword access) | PBUS 0x20000, HD0 0x28000, HD1 0x2a000, ENET-rx 0x2c000, ENET-tx 0x2e000 ✅ |
| 0x30000–0x3ffff | General/PIO registers | `intstat`@0x30000 [4:0], `gio.misc`@0x30004, `eeprom.data`@0x30008, `intstat`@0x3000c [9:5] ⚠️split, `bus_error`@0x30010 |
| 0x40000–0x47fff | SCSI HD0 device window | decode base 0x40000; **WD33C93 regs at +0x4000 = 0x44000** ⚠️ |
| 0x48000–0x4ffff | SCSI HD1 device window | decode base 0x48000; **WD33C93 regs at +0x4000 = 0x4c000** ⚠️ |
| 0x54000 | ENET device (Seeq 8003) | |
| 0x58000 | PBUS device PIO | + dma/pio config 0x5c000 / 0x5d000 |
| 0x60000–0xfffff | **bbRAM / RTC (ds1386)** | 32K-word decode, byte-per-word ×4 ⚠️ (MAME stopped at 0x7ffff) |

⚠️ **SCSI window correction:** the WD33C93 register windows live at **0x44000 / 0x4c000** (device-base
**+0x4000**), *not* 0x40000 / 0x48000 — those are the decode bases. MAME's earlier sub-map had this wrong.

⚠️ **bbRAM window correction:** the battery-backed RAM / RTC decodes the full **0x60000–0xfffff** (broader than
MAME's 0x60000–0x7ffff).

PIO access rules: all HPC3 register accesses are **word (32-bit)** accesses with word-aligned addresses (the
two LSBs of the register address are ignored); FIFO-RAM accesses are **doubleword**; PROM accesses may be
halfword/word/doubleword. Each register access transfers exactly one word regardless of GIO64 byte count;
unused bits read back 0 (except PBUS external regs, where the 8/16-bit value is replicated to fill the word).
Word-oriented register code is *not* endian-sensitive; byte/halfword external-register code *is*.

## ds1386 RTC / battery-backed NVRAM @0x60000

bbRAM/RTC is a **Dallas ds1386** RTC-with-NVRAM at offset 0x60000, accessed **one byte per 32-bit word (×4
address spacing)** — i.e. ds1386 internal byte `i` is read/written at HPC3 offset `0x60000 + i*4`, in the low
byte of the word. This is the SGI NVRAM that holds the boot-monitor environment: **`eaddr` (MAC address),
`console`, `OSLoad*`, `netaddr`** and the rest of the `setenv` variables the PROM reads at power-on.

**Required for boot:** the IP22 PROM reads its boot parameters here; without a populated, correctly-spaced
ds1386 Henry will not get through the boot monitor. The ds1386 *internal* register/NVRAM layout (clock
registers, NVRAM bytes) follows the Dallas datasheet, not the HPC3 spec — Henry should reuse the standard
ds1386 model (MAME has one) behind the ×4 byte-per-word address wrapper.

## Serial EEPROM (NMC93CS56) @0x30008

A separate serial EEPROM (National **NMC93CS56**) holds the chassis serial number and boot-monitor env;
**distinct from the ds1386 NVRAM**. It is bit-banged through the single PIO register `eeprom.data` @0x30008:

| Bit | Signal | Dir |
|-----|--------|-----|
| 0 | `pre` (program-enable / preamble) | out |
| 1 | `cs` (chip select) | out |
| 2 | `clk` (serial clock) | out |
| 3 | `dato` (data → EEPROM, MOSI) | out |
| 4 | `dati` (data ← EEPROM, MISO) | in |

Henry models this as a 5-bit bit-bang shift interface driving a standard 93CS56 serial EEPROM state machine.
Stub-friendly for first boot (PROM tolerates a blank/default serial), but the bit-bang register must exist.

## SCSI (WD33C93) & Ethernet (seeq) glue

HPC3 is *glue*, not the device. The actual SCSI controller is a **WD33C93** (or Fujitsu 86603) reached
through the device window (HD0 @0x44000, HD1 @0x4c000); HPC3 supplies its DMA channel (descriptor walk +
fifo) and PIO path. The actual Ethernet controller is a **Seeq 8003** (with 8020 transceiver) at 0x54000;
HPC3 supplies the enet-tx/enet-rx DMA channels (the `EOXP`/`IPG`/`TXD` `BC` fields are for it). Henry reuses
MAME's WD33C93 and Seeq device models and only implements the HPC3 channel/fifo/PIO wrapper around them. The
WD33C93 generates its own interrupts, so the HPC3 `XIE` per-descriptor interrupt is often redundant for SCSI.

## Interrupts

HPC3 raises a small set of interrupt sources:

- **`dma_complete_int`** — shared by *all* DMA channels **except** Ethernet; asserted when a channel finishes
  a descriptor that has `XIE` set. Exact timing: DMA-read+`XIE` → after the last byte is written to the main-
  memory buffer; DMA-write+`XIE`+`EOX` → after the last byte reaches the device; DMA-write+`XIE` without
  `EOX` → when the last byte has been read into the HPC3 fifo (fifo-to-buffer correspondence is unknown
  because the fifo is packed seamlessly).
- **`enet` interrupt** — the Ethernet channels have their own dedicated interrupt pin (not shared with
  `dma_complete_int`).
- **`bus_error_int`** — GIO64 parity / bus error during a master cycle.

All of these route through **IOC2 → INT2/INT3 → MC → r9999 CP0 Cause IP** (exact bit mapping lives in the IOC
doc). Per-channel DMA interrupt status is readable from two HPC3 registers (the split `intstat` @0x30000 /
@0x3000c — see known bugs).

## Minimum for a Henry IRIX boot

To get IRIX off the root disk, Henry needs:

1. **Address decode** of 0x1fb80000–0x1fbfffff and the sub-map above.
2. **PIO register R/W** for the general regs (`intstat`, `gio.misc`, `bus_error`) and channel/config regs.
3. **ds1386 RTC/NVRAM @0x60000** (byte-per-word ×4) — boot env, **mandatory**.
4. **Serial EEPROM @0x30008** (bit-bang; default/blank contents OK).
5. **One SCSI channel + WD33C93 @0x44000** — descriptor-walk DMA into DRAM to read the root disk / load the
   kernel.

Stub until real I/O is needed: **Ethernet (Seeq) DMA, audio (HAL2), parallel, floppy, the other SCSI channel,
and the general PBUS DMA channels.** They can be decode-only / read-as-0 stubs initially.

## Golden vectors / known chip bugs to model

- ⚠️ **PIO read-back of DMA descriptors (single-stage write-queue bug, hpc3.pdf p10):** HPC3 has a one-stage
  PIO write queue. **Before reading any DMA-descriptor port, software must flush it by doing a PIO read of any
  register immediately before the descriptor read, back-to-back.** Skipping the dummy read returns wrong data.
  Henry must reproduce this so PROM/IRIX driver sequences (which issue the dummy read) match real timing.
- ⚠️ **`intstat` split (chip quirk):** DMA interrupt status is split across two registers — bits [4:0] at
  0x30000 and bits [9:5] at 0x3000c. Drivers read both; model the split exactly.
- ⚠️ **SCSI-rx drops the last byte:** the SCSI receive path leaves the final byte stuck in the fifo. The IRIX
  driver works around it by appending a **0-count descriptor** to flush. Henry must model the last-byte-stuck
  behavior so the workaround descriptor is actually needed (and harmless).

## Open / not-yet-needed

- Exact per-channel register layouts within 0x00000–0x1ffff (PBUS DMA, SCSI/ENET channel ctrl/status) — only
  the SCSI channel needs full fidelity for boot; the rest can come as devices are added.
- DMA/PIO config-register fields at 0x5c000/0x5d000 (PBUS access timing) — PROM writes them; treat as R/W
  storage until a real PBUS device cares.
- Ethernet `IPG`/`TXD`/`EOXP` semantics and the enet-rx byte-count write-back — only when wiring real
  networking.
- HAL2 audio, parallel port, floppy (PC8477) — out of scope for first boot.

## Sources

- SGI IP22 **HPC3 Chip Specification** (`~/code/sgi/docs/indy_docs/ip22/hpc3.pdf`) — authoritative: features
  (p1), DMA descriptor format + buffer rules (p6–7), PIO/word-access + single-stage-write-queue bug (p5,10),
  DMA interrupt timing + flush/coherence absence (p8).
- `~/code/r9999/IP22_CHIP_REGISTERS.md` (HPC3 section + corrections #8/#9) — sub-map, SCSI-window correction
  (0x44000/0x4c000), bbRAM window 0x60000–0xfffff, ds1386 byte-per-word ×4, EEPROM bit-bang, coherence finding.
- MAME IP22/Indy driver — golden reference for FIFO-port offsets, ds1386, WD33C93 and Seeq device models.
