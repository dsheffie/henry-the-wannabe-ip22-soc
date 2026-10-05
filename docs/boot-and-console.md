---
title: Boot sequence & console
status: draft (MAME-validated; Henry FSBL/console re-checked 2026-10-04 against henry 209e6f6 / r9999 5c89b70)
---
# Boot sequence & console

> Intro: the real chain is PROM → sash → /unix; Henry collapses this by loading `/unix` directly
> and entering it with the sash→kernel handoff already done (SPB planted, entry registers set).
> Console: the IRIX kernel writes to its **own** console driver — a graphics framebuffer driver for
> `console=g`, or the Z8530 SCC serial driver for `console=d` — it does **NOT** route console
> output through ARCS. Measured over a full boot in MAME: `arcs_write` = 0 calls.

All numbers below were captured by booting real **IRIX 6.5.22** (Indy `indy_4610` / `r4600be`) in
headless MAME with a debugger-driven Lua autoboot script. MAME is the ground-truth oracle.
Cross-refs: `r9999/IRIX_KERNEL_GAPS.md` (console + entry sections), `r9999/IRIX_CPU_REQUIREMENTS.md`
(ARCS/SPB/romvec), `docs/peripherals/ioc2.md` (the SCC console device).

## The boot chain

**Real Indy:** PROM POST (power-on diagnostics) → **sash** (the OSLoader: enumerates RAM via ARCS
`GetMemoryDescriptor` ×14, builds the component/config tree, seeds the wall clock, loads the `/unix`
ELF) → jumps into `/unix` `start`.

**Henry (sash-less, with a tiny PROM):** the host loads the `/unix` ELF into DRAM (the ARM driver on the
FPGA; `sim/henry_tb --kernel` in simulation) and the **`henry_arcs` FSBL** at the reset vector
`0xBFC00000` synthesizes the small amount of state sash normally leaves behind, then jumps to `start`.
The same FSBL boots IP22 Linux and IRIX; the host patches the kernel entry into the word at
`0xBFC00008` (see [Firmware](firmware-arcs.md#henrys-fsbl-henry_arcs)). The running kernel barely touches
firmware — over a 100 s emulated boot to multiuser the kernel calls the ARCS romvec **exactly once**
(`GetEnvironmentVariable`). So the shim's job is to leave correct *in-memory* state, not to implement
a live firmware. The collapsed handoff is: **shim → /unix `start` with `a0=argc, a1=argv, a2=envp`**
(argc=8; argv/envp are kseg0 pointers to arrays the shim plants in RAM — see [Kernel entry](#kernel-entry)).

## Kernel entry

- **ELF entry = `0x88005960`, symbol `start`.** kseg0-cached vaddr → **PA `0x08005960`**; the image
  loads at VA base `0x88000000` / **PA `0x08000000`** (DRAM `0x08000000`–`0x0fffffff`).
- **Entry registers — `a0 = argc, a1 = argv, a2 = envp`** (the ARCS §4.4 "Loaded Program Conventions"
  handoff sash gives `/unix`). ⚠️ **Correction:** an earlier note here read these as "`a1=0, a2=0`,
  NOT argc/argv/envp." That was wrong — it held only because a 1:1 va2pa shortcut masked the null
  pointers. With a **real translating TLB**, the kernel *does* consume argv/envp (via
  `getargs`/`_envirn`, see prologue), and `a1=a2=0` makes `getargs` **derail** long before the banner
  (interp_mips / `r9999/MAME_QUESTIONS.md` Q5 follow-up).
    - `a0 = argc = 8`.
    - `a1 = argv` — kseg0 pointer (MAME: `0x88fff300`) to a NULL-terminated `char*[]` of 8 strings,
      e.g. `"scsi(0)disk(1)rdisk(0)partition(0)/unix"`, `"OSLoadOptions=auto"`, `"ConsoleIn=serial(0)"`,
      `"ConsoleOut=serial(0)"`, `"OSLoader=sash"`, … .
    - `a2 = envp` — kseg0 pointer (MAME: `0x88fff908`) to a NULL-terminated `char*[]` of `"KEY=value"`
      env strings (`eaddr=…`, `console=d`, `cpufreq=100`, `OSLoadPartition=…`, `TimeZone=…`, …).
    - Arrays + strings live just under the top of RAM (kseg0 pointers). The shim plants them; the full
      string list is in `r9999/MAME_QUESTIONS.md` (Q5 follow-up) / interp_mips `pseudo_bios.cc`.
  - Registers also carry sash leftovers (`t0=0x11 t1=7 …`) but the shim can enter with a clean GPR
    file. MAME's entry Status is **`SR = 0x30004801`** (reset Status `0x70400004`: KX=0, ERL=1, 32-bit
    kernel). **Henry's FSBL does not write Status**: the kernel starts with r9999's reset values
    (`ERL=1`, `BEV=1`, `CU0=1`, `FR=1`, KX=0; `exec.sv` reset block) and sets its own. The FSBL zeroes
    `a3`, `v0`/`v1` and `t0`–`t9`; the other GPRs keep their reset state.
- **`start` prologue (verified disassembly):** sets `gp = 0x88332bf0`, loads `sp = *(0x8832bfa0)`,
  immediately `sw`s the three boot args to gp-relative globals — `a0→_argc`, `a1→_argv`,
  **`a2→_envirn`** (`0x8832d7c0`) — then `jal`s its first C routine
  `0x880255e8(a0,a1,a2,a3=0x880059b0)`. `mlsetup`/`getargs` later consume `_envirn`/`_argv`; a zero
  `_envirn` is exactly where the old `a2=0` handoff diverged. Early calls `_check_dbg`(`0x880255e8`)
  and `debug`(`0x880152c8`) are debug hooks that return.
- The kernel pulls its config from the **ARCS SPB at phys `0x1000`** (signature "ARCS", kseg1
  `0xA0001000`) + a 35-entry FirmwareVector — NOT from the entry registers. RAM size/layout it reads
  **directly from the SGI MC** (`MEMCFG0/1` at phys `0x1fa000c4/0xcc`, via `szmem`@`0x8800790c`),
  not from ARCS. From there it proceeds through early init to multiuser.

## The eaddr requirement — #1 boot gotcha

IRIX's early kernel **PANICs** (UTLB miss around `0x88007488`) if the PROM Ethernet address (`eaddr`)
is unset. In MAME this required a one-time `setenv -f eaddr <mac>` at the PROM prompt or the boot
died before reaching multiuser. **Henry's shim / NVRAM must supply an `eaddr`** (any valid-looking
MAC) or the kernel dies in early init. With a placeholder MAC the kernel boots but later complains
`ec0: machine has bad ethernet address: 08:01:02:03:04:05` and falls back to standalone networking —
harmless for bring-up. Set this first; it is the single most common reason a fresh boot wedges.

**Henry today:** the FSBL plants `eaddr=08:01:02:03:04:05` in `envp`, but its `GetEnvironmentVariable`
stub returns **`08:00:69:12:34:56`** (a real SGI OUI) for every name, and the FSBL also writes that MAC
into the ds1386 bbRAM (`0xbfbe04e8…`). The HPC3 NMC93CS56 EEPROM model returns it from words 125–127
(`hpc3.sv`), so the kernel's Ethernet driver sees a valid station address and networking can come up.

## Console — NOT via ARCS

Measured over a whole boot (both `console=g` and `console=d` runs): **`arcs_write` = 0**,
`romvec[Write]` = 0, `call_prom_cached` = 2 (a non-console early PROM query). There is **no early
ARCS console window** — IRIX's own console driver comes up early enough that the firmware console is
never exercised. The console device is selected by the ARCS `console` env var (`arg_console`):

- **`console=g` / `G` (graphics):** kernel's own **graphics framebuffer driver** (over GIO64). This
  is what MAME runs by default; the boot banner is drawn by the kernel, not the firmware.
- **`console=d` (serial duart):** kernel's `cn*` console subsystem dispatches to the serial driver
  `du_*` (`du_putchar` / `ducons_write`), which drives the **Z8530 / SCC85230** in the **IOC2/INT2**
  ASIC directly. `du_putchar` works through a per-port struct at kdata `0x8832d670 + port*0x84`; the
  mapped SCC base is stored there at driver init.

**Important:** the "free output via the ARCS `Write` hook (`arcs_fw`)" trick does **not** work for
the IRIX kernel console. Both the PROM phase ("Running power-on diagnostics…") and the kernel phase
("IRIX Release 6.5 IP22…") write the Z8530 **directly**. A `du_putchar`/`ducons_write` entry
breakpoint *undercounts* TX (output is buffered / interrupt-driven); the SCC-write hook (`scc_dc_w`
in MAME `src/mame/sgi/ioc2.cpp`) is ground truth — it caught 972 console bytes.

### For a HEADLESS Henry: set `console=d` and emulate the minimal SCC

The Indy console is the **first Z85230 channel** at `0x1FBD9830` (Zilog **channel B**; an earlier
version of this page said "channel A", which was wrong; see [IOC2](peripherals/ioc2.md) and
[SCC](peripherals/scc.md)). For polled output the whole console is two registers:

- **Write `0x1FBD9834`** (Port1 chan A data) → take `data[7:0]`, append to the console sink (stdout).
  That byte is the printed character — this is `du_putchar`'s store.
- **Read `0x1FBD9830`** (Port1 chan A command / RR0) → always return **`0x04`** (RR0 bit2 = Tx Buffer
  Empty), so the driver's "wait for Tx empty" poll (`while(!(RR0 & 4));`) never stalls.
- **Write `0x1FBD9830`** → swallow (WR-pointer selects / WR-register loads: baud, mode, IE).

That stateless polled-TX drain is enough to print the banner — IRIX's `du` driver polls RR0.

**What Henry's `ioc.sv` actually implements (more than the minimum):** RR0 = `0x44` (Tx-empty | all-sent)
with **Tx-empty cleared while the SoC console FIFO is full** (backpressure, so bytes aren't dropped) and
bit 0 = Rx char available; an 8-deep **Rx FIFO** fed by the host (`scc_rx_push`); the WR0/WR1 register
pointer machine, Tx/Rx interrupt-pending bits and **RR3**; and the Tx/Rx interrupt on INT3 mappable
source bit 5 (`henry_soc.sv` `map_src`). Interactive use (getty, Linux `ip22zilog`) needs those. The SCC
TX stream and the core's CP0 reg-7 putchar stream are merged into one 8-deep SoC console FIFO
(`henry_soc.sv` `putchar_fifo_*`), which the AXI wrapper / `henry_tb` drain. Details:
[SCC implementation](peripherals/scc.md).

## What "booted" looks like (serial transcript, `console=d`)

```
                         Running power-on diagnostics...
                           Starting up the system...
               To perform system maintenance instead, press <Esc>
IRIX Release 6.5 IP22 Version 10070055 System V
Copyright 1987-2003 Silicon Graphics, Inc.
All Rights Reserved.
ec0: machine has bad ethernet address: 08:01:02:03:04:05
The system is coming up.
...
```

The PROM-phase lines ("Running power-on diagnostics…", "press &lt;Esc&gt;") are **PROM** code writing
the Z8530; the "IRIX Release 6.5 IP22…" banner onward is the **kernel's** serial driver writing the
Z8530. (Henry has no SGI PROM, so the PROM-phase lines won't appear. Its FSBL prints one heartbeat
line, `r9999 PROM: CPU alive, handing off to the kernel`, plus some MAC/EEPROM readback hex left in as
TEMP DEBUG in `henry_arcs.S`; the kernel banner follows.) Full MAME capture:
`~/code/mame/irix_serial_console.txt`.

## Minimum for Henry to print "IRIX is alive"

1. Load the `/unix` ELF (VA `0x88xxxxxx` → PA `0x08xxxxxx`, base PA `0x08000000`).
2. Plant the **ARCS shim**: SPB at phys `0x1000` (sig "ARCS" + field layout) → 35-entry romvec with
   a working **GetEnvironmentVariable** (the one call the kernel makes); return sane **MEMCFG0/1**
   from the MC model (e.g. `MEMCFG0=0x23200000` → bank @ `0x08000000`). Also plant the **argv/envp
   arrays + strings** in RAM (kseg0 pointers) — these are the `a1`/`a2` handoff (step 5).
3. Provide an **`eaddr`** in the ARCS env / NVRAM (see the eaddr gotcha above) — or early init panics.
4. Set **`console=d`** in the ARCS env (and in the planted `envp`).
5. Enter `start` (`0x88005960`) with **`a0=argc=8, a1=argv, a2=envp`** (kseg0 pointers to the step-2
   arrays — **not** `a1=a2=0`, which derails `getargs`), clean GPRs, `SR=0x30004801`.
6. Emulate the **minimal Z8530 SCC** at IOC2 (write `0x1FBD9834` = TX byte → stdout; read
   `0x1FBD9830` → `0x04`; swallow writes to `0x1FBD9830`).

With those six, the kernel runs through early init and its `du` driver prints the IRIX banner to
Henry's serial sink. On Henry, steps 2–5 are done by the `henry_arcs` FSBL (it also programs
`MEMCFG0=0x3f203f40`, 2 × 128 MB), and step 6 is `ioc.sv`.

## Detailed working notes

- `r9999/IRIX_KERNEL_GAPS.md` — "Serial console output — how IRIX prints" and "Kernel entry & boot
  handoff" sections (the `arcs_write=0` measurement, `du_*` dispatch, SCC address, entry regs).
- `r9999/IRIX_CPU_REQUIREMENTS.md` — P0-A (`start` handoff, entry registers, SPB layout, romvec),
  P0-B (who calls the romvec and when), P0-C (RAM sizing via the MC), and the eaddr note.
- `docs/peripherals/ioc2.md` — the Z8530 SCC console device map and minimal-TX recipe.
