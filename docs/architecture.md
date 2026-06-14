---
title: Architecture
status: draft
---

# Henry architecture

Henry is the **r9999** CPU core wired to a re-implementation of the SGI **IP22** chipset, in a memory-mapped
system that boots IRIX. This page is the system-level view; each block has its own spec under
[Peripherals](peripherals/mc.md).

## Blocks & responsibilities

| Block | Role | Spec |
|---|---|---|
| **r9999** | MIPS R4000-class CPU core (PRId = R4000). L1i + L1d (incoherent), transparent/coherent L2. | [CPU integration](cpu-integration.md) |
| **MC** | Memory controller: DRAM banks + sizing, the GIO64 bus arbiter, error/refresh/timers, the graphics (V)DMA master. | [MC](peripherals/mc.md) |
| **HPC3** | Peripheral/DMA controller: SCSI ×2, Ethernet, PBUS; the ds1386 RTC/NVRAM and serial EEPROM. | [HPC3](peripherals/hpc3.md) |
| **IOC2** | I/O controller: the **Z8530 serial console**, the INT3 interrupt controller, the 8254 timer, keyboard/mouse, parallel. | [IOC2](peripherals/ioc2.md) |
| **GIO64** | The expansion/graphics bus (16 × 4 MB slots). Headless Henry bus-errors empty slots. | [GIO64](peripherals/gio64.md) |
| **VDMA** | The MC's virtual-DMA graphics master (future-work; its own page-table walker). | [VDMA](peripherals/vdma.md) |
| **ARCS shim** | The firmware state Henry plants so `/unix` boots without the real PROM/sash. | [Firmware](firmware-arcs.md) |

## Buses & topology

- **sysad** — the 64-bit, **big-endian** processor bus between r9999 and the MC. The big-endianness has a
  concrete consequence: 32-bit MC registers sit on the low 32 data lines, so a big-endian CPU reads each
  register at its **`+4`/`+c`** byte alias (see [MC](peripherals/mc.md)).
- **GIO64** (`0x1f000000–0x1f9fffff`) — the expansion/graphics bus, mastered by the CPU (through the MC
  arbiter), by graphics, and by long-burst DMA. Sixteen 4 MB slots; IP22 wires only graphics + two expansion
  slots, and an access to an unpopulated slot returns a **bus error** — which is exactly how IRIX's GIO probe
  decides "no device."
- **Local I/O** (`0x1fb80000+`) — HPC3 + IOC2 + the boot PROM. HPC3 bridges GIO64 to the peripherals and the
  PBUS (where the RTC/NVRAM, EEPROM, audio, and parallel live).

## Memory-mapped layout

See the [canonical address map](index.md#canonical-physical-address-map-ip22-henry). The essentials:

- **DRAM** at physical `0x08000000` (sized from the MC `MEMCFG` registers, *not* via firmware), aliased into
  the bottom 512 KB so the exception vectors at `0x0`/`0x80` are real RAM. Physical addresses are **30-bit**
  (a high-memory window exists at `0x20000000`), though a small-RAM Henry only exercises ~29 bits.
- **Device space** at `0x1f000000+`: GIO64, then the MC registers (`0x1fa00000`), then HPC3/IOC2
  (`0x1fb80000`), then the boot PROM (`0x1fc00000`).

## DMA & coherence (the architecturally load-bearing part)

There are two DMA masters — **HPC3** (SCSI/Ethernet/PBUS, the real system I/O path) and the MC's **VDMA**
(graphics). **Neither snoops the CPU caches** on a uniprocessor R4000, and HPC3 DMA uses **raw physical
addresses** (no IOMMU). Combined with r9999's **incoherent L1i**, this means Henry's correctness depends on
software cache management: the IRIX `cache` instruction is **not** a NOP, and r9999 must honor specific
ops (I-cache invalidate for code coherence; D-cache invalidate-*without*-writeback for DMA-in). This is the
single most important cross-block contract — see [Cache, coherence & TLB](coherence-cache-tlb.md).

## Interrupts

Peripheral interrupt sources (HPC3 DMA-done/error, GIO64 device lines, the 8254 timers) aggregate in the
**INT3** controller inside IOC2, which drives five `CPU_INT_N` lines into r9999's CP0 `Cause.IP[6:2]`. The CPU's
own periodic tick is the on-chip **CP0 Count/Compare** timer, not a peripheral. See [IOC2](peripherals/ioc2.md).

## Build/verify strategy

The spec is the contract; **MAME is the oracle**. Each block is implemented against its register spec and the
golden vectors captured from MAME (e.g. `MEMCFG0=0x23200000`, the SPB bytes, the wired-PDA TLB entry, the SCC
TX stream), then co-simulated/diffed against MAME booting the same IRIX image. See [Methodology](methodology.md).
