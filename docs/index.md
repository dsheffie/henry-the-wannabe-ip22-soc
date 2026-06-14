---
title: Henry — the wannabe IP22 SoC
status: draft
---

# Henry — the wannabe IP22 SoC

**Henry** is a from-scratch, FPGA/RTL **System-on-Chip** that impersonates the SGI **Indy** (board code
**IP22**) closely enough to boot **IRIX 6.5.22**. It is built around the **[r9999](https://github.com/dsheffie/r9999)**
MIPS R4000-class core (included here as a git submodule) plus a set of re-implemented IP22 peripheral blocks.

> **Why "Henry"?** The SGI **Indy** is named for **Indiana Jones** — whose real name is **Henry** (Walton Jones Jr.;
> "Indiana" was the dog). Henry is a machine that answers to a name that isn't quite its own: a *wannabe* IP22.

This site is the **platform specification and implementation reference**: the address map, each peripheral block's
register interface and "minimum to boot" subset, the ARCS firmware shim, the IRIX boot/console contract, and the
cache/coherence/TLB rules the CPU must honor. Every claim is **cross-validated against MAME** booting the real Indy
IRIX image — MAME is Henry's **golden reference model**, and the values captured from it are the block-level test
vectors. Tags: ✅ = confirmed in MAME, ⚠️ = a correction to an earlier reverse-engineering finding.

## The system at a glance

```mermaid
flowchart TD
    CPU["<b>r9999</b> — MIPS R4000 core<br/><small>L1i + L1d (incoherent) · L2 (coherent) · git submodule</small>"]
    CPU -->|"sysad — 64-bit, big-endian"| MC["<b>MC</b> — memory controller<br/><small>RAM banks · GIO64 arbiter · (V)DMA</small>"]
    MC --> RAM[("Main RAM<br/>0x08000000+")]
    MC -->|"GIO64 bus<br/>0x1f000000–0x1f9fffff"| GIO{{GIO64}}
    GIO --> GFX["graphics — slot 0"]
    GIO --> EXP["exp slot 0 / 1<br/><small>bus-error when empty</small>"]
    MC -->|local I/O bus| LIO{{local I/O}}
    LIO --> HPC3["<b>HPC3</b><br/><small>SCSI×2 · Ethernet · PBUS DMA<br/>ds1386 RTC/NVRAM · EEPROM</small>"]
    LIO --> IOC2["<b>IOC2</b><br/><small>Z8530 serial console · INT3<br/>8254 timer · kbd · parallel</small>"]
    LIO --> PROM["Boot PROM / ARCS shim"]
```

## Canonical physical address map (IP22 / Henry)

| Physical range | Size | Block | Henry notes |
|---|---|---|---|
| `0x00000000–0x0007ffff` | 512 KB | **RAM alias** | aliases `0x08000000`; holds the exception vectors (`0x0`, `0x80`) |
| `0x08000000–0x17ffffff` | 256 MB | **Main RAM** (MC banks) | base of physical DRAM; sized via MC MEMCFG |
| `0x18000000–0x1effffff` | 112 MB | reserved | bus-error |
| `0x1f000000–0x1f9fffff` | 10 MB | **GIO64 bus** | graphics @`0x1f000000`; exp slots @`0x1f400000`/`0x1f600000`; bus-error empty slots |
| `0x1fa00000–0x1faffff` | 1 MB | **MC registers** | ⚠️ big-endian `+4/+c` register alias |
| `0x1fb80000–0x1fbfffff` | 512 KB | **HPC3** | + IOC2 @`0x1fbd9800` (serial console), ds1386 RTC/NVRAM @`0x1fbe0000` |
| `0x1fc00000–0x1fffffff` | 4 MB | **Boot PROM** | Henry plants the ARCS shim |
| `0x20000000–0x2fffffff` | 256 MB | **High system memory** | kseg-mapped only → physical address space is **30-bit** |

(See [Memory & address map](peripherals/mc.md) for the MC/MEMCFG detail.)

## Where to start

| If you want to… | Read |
|---|---|
| understand the whole system | this page + [Architecture](architecture.md) |
| wire r9999 in & know what to implement | [CPU integration](cpu-integration.md) |
| get IRIX to print "IRIX is alive" | [Boot & console](boot-and-console.md) + [IOC2](peripherals/ioc2.md) |
| build the firmware Henry presents | [Firmware / ARCS shim](firmware-arcs.md) |
| get cache/DMA/TLB right | [Cache, coherence & TLB](coherence-cache-tlb.md) |
| implement a chip | the [peripheral specs](peripherals/mc.md) |
| reproduce/extend the findings | [Methodology](methodology.md) |

## Status

First-pass foundation. Peripheral specs (MC, IOC2, HPC3, GIO64, VDMA) and the cross-cutting docs are drafted from
the SGI IP22 chip documents + MAME validation. Not yet covered: `dmux1`, the Newport graphics set, audio (HAL2),
and the actual RTL (`rtl/`) and co-simulation harness (`sim/`). The detailed working notes live in the
[`r9999/`](https://github.com/dsheffie/r9999) submodule (`IRIX_CPU_REQUIREMENTS.md`, `IRIX_KERNEL_GAPS.md`,
`IP22_CHIP_REGISTERS.md`, `MAME_QUESTIONS.md`).
