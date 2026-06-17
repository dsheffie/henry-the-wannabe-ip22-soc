---
title: Minimum MMIO to the IRIX boot banner
status: draft (functional-sim validated, MAME-corroborated)
source: interp_mips functional ISS (first model to reach the banner); MAME golden reference; r9999/MAME_QUESTIONS.md Q1–Q7
---

# Minimum MMIO device models to reach the IRIX boot banner

> This is the **empirically minimal set of MMIO devices** an IP22 model must answer to get IRIX 6.5.22 to
> print its release banner and run into device configuration. It was pinned down by booting the **real
> `/unix`** on the **interp_mips functional ISS** — the first Henry-family model to actually banner — and
> cross-checked against MAME (the golden oracle). Treat it as the *boot-critical subset* of the full
> per-block specs in [`peripherals/`](peripherals/mc.md); each block's complete register interface lives in
> its own page.
>
> Legend: ✅ confirmed by a booting model · 🩹 must return a specific Indy constant the kernel branches on ·
> 🗂 inert storage / write-absorb is enough.

## What "the banner" means

```
IRIX Release 6.5 IP22 Version 10070055 System V
Copyright 1987-2003 Silicon Graphics, Inc.  All Rights Reserved.
```

This prints **after** the full VM/CPU bring-up (TLB, pmap, heap, scheduler init) and **before** the root
filesystem is mounted. So the banner is the milestone that proves *CPU + memory + console + the platform-ID
constants* are all correct. It does **not** require working SCSI, DMA, or graphics — those gate the *next*
wall (root-device mount). See [Boot sequence & console](boot-and-console.md) for the entry/console contract.

## The boot-critical MMIO map

All device MMIO lives in **phys `0x1f000000`–`0x1fffffff`** (kseg1 `0xbf…`). Reads outside the blocks below
return 0 (probed-empty); that is itself load-bearing (the kernel probes many empty GIO/PBUS slots and must
read back 0).

| Block | Phys base | Boot role | Minimum to banner |
|---|---|---|---|
| **MC** (memory controller) | `0x1fa00000` | RAM sizing, sysid, clocks, EEPROM | 🩹 a handful of constant regs + a working serial EEPROM + the free-running counter |
| **IOC2** (system ID) | `0x1fbd9800` | board-type select | 🩹 one register: SYSID `+0x58` = `0x26` |
| **Z8530 SCC** (serial console) | `0x1fbd9830` | `console=d` output | ✅ TX-only: status reads "ready", data writes → host stdout |
| **HPC3** (DMA/PBUS/SCSI window) | `0x1fb80000` | early device probe | 🗂 a few status regs + write-absorbing register windows |

Everything else (Newport graphics, GIO64 cards, VDMA, the WD33C93 SCSI engine, the RTC) is **not** touched on
the path to the banner, or is only probed-empty.

---

## MC — Memory Controller (`0x1fa00000`)

The single most-consulted block. **Big-endian IRIX reads the `+4`/`+c` alias of each register** (see
[mc.md](peripherals/mc.md#address-base--the-big-endian-alias)) — a functional model must decode both the
table offset and its `+4` alias.

| Reg (BE alias) | Value the kernel needs | Why / who reads it |
|---|---|---|
| **MEMCFG0** `0x1fa000c4` | 🩹 **`0x23200000`** | `mlreset`/`szmem` → **16 MB single bank @ PA `0x08000000`**. The wrong size (e.g. 128 MB `0x3f200000`) reshapes the whole VM bootstrap and the kernel walls/loops before the banner. |
| **MEMCFG1** `0x1fa000cc` | 🩹 `0x00000000` | banks 2/3 empty |
| **SYSID** `0x1fa0001c` | 🩹 `0x00000013` | MC revision, read by `mlreset` |
| MC sysid `0x1fa00004` | `0x3c802472` | repeatedly read by `flushbus` to drain the write buffer (round-trips fine; value not branch-critical) |
| **CPUCTRL0/1** `0x1fa00004/0xc` | 🗂 read/write storage | endian/cache/watchdog control word; round-trips |
| **serial EEPROM** `0x1fa00034` | 🩹 **bit-banged** | the PROM/kernel clock CS/CLK/DATA through this to read NVRAM (incl. the `eaddr`); a model must shift data out, not return a constant |
| **RPSS counter** `0x1fa01004` | 🩹 free-running, increments | drives `us_delay`/spin-calibration; a stuck value hangs delay loops |
| GIOPAR / CMACC / GMACC / CSTAT / GSTAT | 🗂 storage / clear-on-write | GIO arbiter + DRAM timing + error capture; inert is fine for boot |

!!! note "MEMCFG0 → memory size"
    `bank0 size = (MEMCFG0[28:24] + 1) × 4 MB`, `base = (MEMCFG0[23:16] & 0xff) << 22`. `0x23200000` →
    field `0x03` → **16 MB** @ `0x08000000`. The kernel reads this **directly from the MC**, not from ARCS
    `GetMemoryDescriptor`. (MAME `MAME_QUESTIONS.md` Q3/Q4.)

---

## IOC2 — System ID (`0x1fbd9858`)

🩹 **One register decides the whole board type.** `getsysid` does `lw 0(0xbfbd9858); andi 0xe0`:

- **`0x26`** (`& 0xe0 == 0x20`) → **guinness / Indy** — the value you want.
- `0x11` → Indigo² (`full_house`) — wrong machine, diverges.

Return `0x26` at phys `0x1fbd9858`. (`getsysid` uses bits `[7:5]` for the system class + bit 0.) Getting this
wrong steers cache/TLB sizing and the page-table layout downstream — it's a silent, far-reaching divergence.

---

## Z8530 SCC — the serial console (`0x1fbd9830`–`0x1fbd983f`)

✅ **This is how the banner physically appears.** For `console=d` the IRIX kernel writes to its **own** Z8530
driver (it does *not* route console through ARCS — `arcs_write` = 0 over a whole boot). A minimal **TX-only**
model is sufficient:

- **Control/status read (RR0)** → always return `TX_EMPTY | ALL_SENT` (`0x04 | 0x40`) so the "ready to
  transmit?" poll always succeeds.
- **Data write** → emit the byte to the host console (stdout).
- **Data read** → 0 (no Rx char); **control writes** (WR pointer/config) → ignored.

Address decode: channel/data vs control is selected by an address bit (`(offs>>2)&1` in the interp_mips
model). RX, interrupts, and baud programming are not needed for a one-way boot console.

---

## HPC3 — early device-probe window (`0x1fb80000` base)

🗂 The Indy's first HPC3 (boot PROM / SCSI / enet / EEPROM / PBUS); `offs = phys − 0x1fb80000`. To reach the
banner the kernel only needs a few **status** regs and for the rest of the register windows to **absorb
writes and read back sanely**:

| Offset | Phys | Role |
|---|---|---|
| `0x30000` | `0x1fbb0000` | `istat0` — interrupt status `[4:0]` |
| `0x30004` | `0x1fbb0004` | `gio_misc` |
| `0x00000`–`0x0ffff` | … | PBUS DMA channel registers (storage) |
| `0x10000`–`0x1ffff` | … | HD0/HD1/ENET DMA registers (storage) |
| `0x58000`–`0x5bfff` | … | PBUS PIO data ports (probe) |

The **WD33C93 SCSI** engine lives at offset `0x40000` (phys `0x1fc0000`) — a write-absorbing stub gets you to
the banner, but **real SCSI behavior is the next wall** ("pbus configuration failed" / "Root device … not
available"), which is *past* the banner. See [hpc3.md](peripherals/hpc3.md).

---

## Required to banner, but NOT MMIO

The banner is gated as much by CPU/firmware correctness as by devices. A model that has all the MMIO above but
misses these will still wall before the banner:

- **A real 48-entry R4000 translating TLB** + refill/general exception vectoring (BEV-aware). The 1:1 va2pa
  shortcut hides this but cannot reach the banner.
- **EPC/Cause.BD frozen on nested exceptions** (updated *only* when `Status.EXL==0`). IRIX's self-mapped
  page-table refill takes a **nested TLB miss inside the `0x80000000` refill handler**; the `eret` must
  return to the *original* faulting instruction. Updating EPC mid-handler → eret resumes with `k0` clobbered
  → recursion → KPTEBASE panic. **This was the last wall before the banner** (interp_mips
  `MAME_QUESTIONS.md` Q5 round-7) — the r9999 RTL must implement the same freeze.
- **PRId = `0x00002020` (R4600)** and **Config = `0x0002e4b3`** (16K I$/16K D$, 32-byte lines). `start`
  branches on PRId's IMP field; Config drives `cachecolormask` (a wrong mask hangs `pagecoloralign`).
- **CP0 Count/Compare timer interrupt** (IP[7]).
- **The sash→/unix handoff in RAM**: ARCS SPB/romvec/env at phys `0x1000`, **plus the `argc/argv/envp`
  arrays** (`a0=argc, a1=argv, a2=envp` as kseg0 pointers). ⚠️ This **corrects** the older
  [boot-and-console](boot-and-console.md) note ("a1=0, a2=0, NOT argc/argv/envp"): with a real TLB the kernel
  *does* consume argv/envp via `getargs`/`_envirn`, and `a1=a2=0` makes `getargs` derail long before the
  banner. (MAME `MAME_QUESTIONS.md` Q5 follow-up; interp_mips `pseudo_bios.cc`.)
- An **`eaddr`** must be supplied (NVRAM EEPROM or env) — the kernel panics in early init without it.

## What is NOT needed for the banner

- **Newport graphics** (REX3/VC2/XMAP9/RB2/RO1) — only for `console=g`; serial console skips it entirely.
- **GIO64 cards / VDMA / DMUX** — probed-empty (read 0) is sufficient.
- **RTC (ds1386)** — touched but not banner-critical.
- **Working SCSI/DMA** — first needed at root mount, after the banner.

## Sources & cross-refs

- Empirical minimum set + the EPC nested-exception fix: **interp_mips** functional ISS (the `interpret.cc`
  TLB/exception model, `sgi_mc.cc` / `sgi_hpc.cc` / `sgi_scc.cc` device models, `pseudo_bios.cc` handoff).
- Ground-truth values + the divergence hunt: **`r9999/MAME_QUESTIONS.md`** (Q1 wired PDA, Q2/Q3 pmap +
  memory size, Q4 MEMCFG/16 MB, Q5 the PRId/Config/SYSID/handoff/EPC chain to the banner).
- Per-block detail: [MC](peripherals/mc.md) · [IOC2](peripherals/ioc2.md) · [HPC3](peripherals/hpc3.md) ·
  [Boot & console](boot-and-console.md) · [Cache/coherence/TLB](coherence-cache-tlb.md).
