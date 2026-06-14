---
title: DMUX — data mux
status: draft
source: SGI IP22 DMUX spec (dmux1.pdf)
---

# DMUX — Data Mux (Henry block spec)

> DMUX ("MUX" in the chip's own spec; "DMUX" in the MC/board context) is the IP22 **datapath gate array** that
> sits between the R4000 SysAd bus, the interleaved DRAM (Memory A / Memory B), and the GIO64 bus. It is pure
> plumbing: a clock-domain-crossing data path with a 32-deep CPU write FIFO, an interleave mux for memory, a
> word-swap mux for GIO transfers, GIO read/write packers (32↔64-bit packing), and per-byte-lane parity gen/check.
> **It has no CPU-visible registers** — every control input comes from the MC chip, not from software. **Bottom
> line: a Henry SoC that integrates r9999 with its own memory/GIO datapath subsumes DMUX entirely. Henry does not
> need to model DMUX as a block for a headless IRIX boot.** The one externally observable behavior to keep in mind
> is end-to-end *parity* and *endianness/word-swap*, and even those are datapath properties Henry already owns.

## Role in Henry  (the "do we need it?" answer)

**No DMUX block is required.** DMUX is the physical IP22 implementation of the data path that an SoC integrating
r9999 already provides intrinsically:

- On a real IP22 board the CPU, the DRAM SIMMs, and the GIO64 bus are three separate physical interfaces running
  on different clocks (CPU 50–65 MHz, GIO 33–40 MHz). DMUX is the gate array that physically routes 36-bit slices
  (32 data + 4 parity) between them, crosses the clock domains with FIFOs, and does the interleave/word-swap
  muxing. Two DMUX parts are used per machine, each handling 36 bits (dmux1.pdf p.1).
- In Henry, r9999's load/store path, the MC's memory interface, and the GIO64 bridge are all internal to the SoC
  and already move data between CPU, memory, and peripherals. There is no asynchronous 36-bit gate-array boundary
  to bridge, so the function DMUX performs has no separate existence.
- DMUX exposes **zero memory-mapped registers**. IRIX never addresses it. Nothing in the boot/PROM/kernel path
  reads or writes a "DMUX register," so there is no register model to implement (the *MC* registers that *control*
  DMUX — e.g. the FIFO high-water mark — live in the MC, and are documented in `mc.md`).

What Henry must still get right is the *effect* DMUX has, which Henry's own datapath is responsible for anyway:
correct data parity end-to-end (or simply not modeling parity errors), and correct byte/word ordering for
big-endian IRIX. Those are not "model DMUX"; they are "make loads/stores and GIO transfers return the right
bytes," which any working SoC datapath does.

## What DMUX does

DMUX is a sliced data path (two parts × 36 bits) performing **six** primitive operations, selected by a pair of
mutually-exclusive selects driven by MC: `cpu_sel` (CPU↔memory) and `gio_sel` (the other four). The two are never
asserted together (dmux1.pdf p.2). The six operations and how parity is handled (p.2):

| Operation | cpu_sel | gio_sel | mux_dir | parity |
|---|---|---|---|---|
| CPU GIO64 device read | 0 | 1 | 0 | generated |
| GIO64 write to memory | 0 | 1 | 0 | generated |
| CPU GIO64 device write | 0 | 1 | 1 | generated |
| GIO64 read from memory | 0 | 1 | 1 | from memory |
| CPU memory write | 1 | 0 | — | generated |
| CPU memory read | 1 | 0 | — | from memory |

Functional blocks (dmux1.pdf pp.2–3, 6–19):

- **CPU write FIFO** — a **32-entry × 40-bit** ("40 bits 32 data, 4 generated parity, 4 parity-error") write
  buffer on the CPU→memory and CPU→GIO path. It decouples the 50 MHz CPU from the slower memory/GIO sides and
  acts as the CPU write buffer. Data is pushed with `cpu_push` (a dedicated signal — data can be pushed even when
  DMUX is busy with another op). 32 deep so it can hold **two complete 32-word cache block writes**, the largest
  block the CPU issues. The MC tracks fill level; DMUX itself "does not have to worry about the write buffer
  being over filled." Implemented as a 32×40 triple-port RAM with bypass muxes (ping-pong read) to meet 65 MHz
  (pp.4, 7).
- **Interleave mux (CPU reads from memory)** — DRAM is 2-way interleaved (Memory A / Memory B, each 36 bits).
  On a CPU read, DMUX selects/merges the two 36-bit memory ports onto SysAd under `data_sel`, with the swap
  options listed below (pp.8–9).
- **Word-swap mux (CPU↔GIO)** — On CPU reads from / writes to GIO, DMUX performs one of several
  word-swap/duplicate operations so a 32-bit GIO device, a 64-bit GIO device, and the high/low SysAd words line
  up. `data_sel(1:0)` picks: pass-through `gio_ad(63:0)→sysad(63:0)`, duplicate-low-word-onto-both (needed when
  R4000 reads a 32-bit GIO device), or move-high-word-to-low (R3000 reading high bits) (pp.10–11).
- **GIO write packer + GIO64 write buffer** — packs 32- and 64-bit GIO bus-master writes into 128-bit quad words
  for memory; a **six-entry** write buffer between GIO and the memory data outputs isolates GIO stalls from the
  memory write. Driven by GIO *commands* the MC feeds via a **12-entry command FIFO** (pp.12, 14–16).
- **GIO read buffer / unpacker** — a **three-entry** GIO memory-read FIFO; unpacks memory data back onto the GIO
  bus, again command-driven from MC (pp.17–19).
- **Parity** — DMUX carries parity on every 36-bit slice (32 data + 4 parity). It **generates** parity on writes
  and on reads sourced from the CPU/GIO, and **passes/checks** parity on reads sourced from memory. `par_err(3:0)`
  reports detected parity errors to MC. `par_flush` (qualified with `cpu_sel` after the Rev 1.2 fix) can
  deliberately write *bad* parity to memory for diagnostics (pp.2, 5, 36 [Rev 1.2], 37 [problems]).

Two clock domains: `cpu_clk` (50–65 MHz) and `gio_clk` (33–40 MHz). All MC control signals are flopped before
use; `cpu_sel` ops are synchronous to `cpu_clk`, `gio_sel` ops to `gio_clk` (p.2). `csize64` (R4000 = full 64-bit
SysAd) was removed as a pin — pulled high internally; R3000 support is gone (pp.2, 4).

## Register interface

**None.** DMUX has no CPU-addressable registers and is not in any peripheral address map. It is a slave to the MC
chip: all of its behavior is selected cycle-by-cycle by MC-driven control pins, not by software. The pins are
(dmux1.pdf pp.20–22):

- **Selects / direction:** `gio_sel`, `cpu_sel`, `mux_dir`, `cpu_push`, `cpu_mem_oe`.
- **Mux source / packing:** `data_sel(2:0)`, `graphics(1:0)` (which slave delay signal), `aen_mem`, `ben_ctrl`,
  `cen_fifo`, `giostb` (a valid GIO command), `par_flush`.
- **Delay / handshake in:** `masdly`, `slvdly`, `grxdly(2:0)`, `mc_dly`.
- **Data buses:** `sysad(31:0)+sysad_par(3:0)` (R4000), `gio_data(31:0)+gio_par(3:0)` (GIO64),
  `mem_a(31:0)+par`, `mem_b(31:0)+par` (interleaved DRAM).
- **Out:** `par_err(3:0)` (parity error to MC).
- **Infra:** `cpu_clk`/`gio_clk` + PLLs, `reset_n`, JTAG/ATPG (`jtdi/jtdo/jtms/jtck/tp0/tp1/entei`).

Total 189 signal pins; 240-pin and 299-pin MQFP packages (pp.20, 23–31). None of this is software-visible.

## Relationship to MC / GIO64 / CPU write FIFO

DMUX is the *muscle*; MC is the *brain*. The MC decodes the CPU/GIO addresses, arbitrates the GIO64 bus, tracks
how full the CPU write FIFO is, and drives every DMUX control pin (including `cpu_push` to load CPU write data and
the `giostb`/command stream for GIO packing). DMUX just routes bytes when told.

The **"MUX HWM" / CPU-write-FIFO high-water mark** referenced from the MC spec lives in MC's CPUCTRL1 (see
`mc.md`, where `MC fifo HWM[3:0]` defaults to `0xC`). That is the MC telling itself how full to let *DMUX's*
32-entry CPU write FIFO get before it deasserts `cpu_wrrdy_n` to throttle the processor (dmux1.pdf p.4: "When the
fifo is full the MC chip will deassert the processor cpu_wrrdy_n signal"). So the HWM is an MC register about a
DMUX resource — and in Henry it's purely an MC-side concern. From the GIO64 side, MC throttles GIO bus masters
with `slvdly` when DMUX's GIO write/read FIFOs back up.

## Minimum for a Henry IRIX boot

**Nothing DMUX-specific.** Concretely:

- **No register model** — DMUX has no software-visible registers, so there is nothing for the PROM/ARCS/kernel to
  probe. (The HWM and friends are already covered by the MC model.)
- **No separate block** — Henry's r9999↔memory and r9999↔GIO64 datapaths are the SoC-internal equivalent of what
  DMUX does on a physical IP22 board; integrating the core subsumes the gate array. The clock-domain FIFOs, the
  interleave mux, and the GIO packers are artifacts of three physical chips on different clocks — Henry doesn't
  have that boundary.
- **Do get the datapath *effects* right** (these are Henry's datapath responsibility, not a "DMUX block"):
  1. **Endianness / word ordering.** Big-endian IRIX expects the byte/word lane mapping DMUX's word-swap muxes
     produce. Henry's load/store and GIO paths must return the correct bytes. (Compare with the MC big-endian
     alias note in `mc.md` — same theme: get the lanes right.)
  2. **Parity** can be ignored. DMUX parity exists to *detect DRAM faults*; on simulated/SoC memory there are no
     bit flips, and the parity-error interrupt path is maskable. Henry need not model parity gen/check to boot.
- The known DMUX silicon bug (bad-parity-on-`par_flush` corrupting the GIO FIFO, IDE-then-SCSI failure, p.37) is
  a hardware erratum with no bearing on a clean Henry datapath — do not replicate it.

If Henry ever grows a *cycle-accurate, multi-chip* model of an IP22 board (separate MC + DMUX + GIO devices on
real clocks), DMUX becomes a real block: the 32-entry CPU write FIFO, the 6-entry GIO write buffer, the 3-entry
GIO read buffer, the 12-entry GIO command FIFO, and the interleave/word-swap muxes would all need modeling. For a
*functional headless IRIX boot* on an r9999 SoC, none of that is needed.

## Sources

- dmux1.pdf p.1 — full-machine block diagram; "two MUX parts handle 36 bits including parity."
- dmux1.pdf p.2 — block overview, two clock domains, `cpu_sel`/`gio_sel`, six-operation/parity table, `csize64` removed.
- dmux1.pdf p.3 — MUX block diagram (CPU write buffer, packer, GIO/MEM FIFOs, parity gen/chk).
- dmux1.pdf p.4 — CPU writes to memory: two-part write, **32-entry** FIFO, `cpu_push`, `cpu_wrrdy_n` throttle, `csize64` pulled high.
- dmux1.pdf pp.5–7 — write control signals (`aen_mem`/`ben_ctrl`/`cen_fifo`/`par_flush`), CPU write buffer = 32×40 triple-port RAM.
- dmux1.pdf pp.8–9 — CPU reads from memory: interleave mux, `data_sel` source select.
- dmux1.pdf pp.10–11 — CPU reads from GIO64/EISA: word-swap mux options.
- dmux1.pdf pp.12–13 — CPU writes to GIO64: 12-entry GIO command FIFO.
- dmux1.pdf pp.14–16 — GIO writes to memory: packer, **6-entry** write buffer, 8×72 triple-port RAM.
- dmux1.pdf pp.17–19 — GIO reads from memory: unpacker, **3-entry** read FIFO.
- dmux1.pdf pp.20–22 — MUX pins: data buses, control signals, GIO64/clock/JTAG signals (189 pins, no registers).
- dmux1.pdf pp.23–31 — pin cross-reference (299- and 240-pin packages).
- dmux1.pdf p.36 — Rev 1.2: `par_flush` qualified with `cpu_sel`.
- dmux1.pdf p.37 — known problem (par_flush/GIO-FIFO, IDE→SCSI), power (1.28 W).
- mc.md — MC CPUCTRL1 `MC fifo HWM[3:0]=0xC` (the high-water mark that governs DMUX's CPU write FIFO).
