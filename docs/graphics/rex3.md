---
title: REX3 — Raster Engine (Newport)
status: draft / future-work
source: SGI Newport REX3 spec (rex3.pdf)
---

# REX3 — Raster Engine (Henry/Newport block spec)

> REX3 = the host-programmable rendering engine of the Indy Newport board, a GIO64
> slave at `0x1f000000`. The host writes its registers to issue draw primitives;
> REX3 rasterizes them and writes pixels into the VRAM framebuffer through the RB2s.
> It is also the master of the Display Control Bus (DCB) that programs the rest of
> the Newport display chain (VC2, XMAP9, CMAP, RAMDAC).
>
> **NOT needed for headless Henry** — a headless Henry bus-errors any access to this
> address window. This document is future-work for a Henry graphics console: it
> captures the architecture, programming model, and register-group map well enough
> to (a) understand the part and (b) scope what a Henry REX3 would entail, without
> exhaustively transcribing all 149 spec pages.

Part: REX3, SGI 099-9005-001, LSI L1A9040, 0.6µm CMOS gate array, 304 MQUAD,
~149K gates incl. 5.7Kb dual-port RAM. (rex3.pdf p.5)

---

## Role & architecture

REX3 ("the least graphics you'll ever need") is the raster engine of the Newport
graphics subsystem. It is the successor to REX1 and, like REX1, has **no geometry
engine** — the host CPU's FPU does the geometry, and Z-buffering is done in software
in host memory. REX3's job begins when the host writes primitive coordinates and
mode bits into its registers; REX3 turns those into screen pixels. (p.5)

**The Newport display pipeline** (rendering → scanout), Figure 1, p.6–8:

```
  GIO64 host ── REX3 ──(FB CNTL / DATA)── RB2 ×4 ── VRAM framebuffer
                  │                                       │ serial ports
                  │ DCB (8-bit)                           ▼
                  ├──────────► VC2 (video timing) ◄──► RO1 ×3 (reorganizer)
                  ├──────────► XMAP9 ×2 (CI lookup / RGB path) ◄──► CMAP ×2 (CI SRAM)
                  └──────────► RAMDAC (gamma + R/G/B out) ──► monitor
```

- **REX3** rasterizes and writes pixels; masters the DCB.
- **RB2** ×4 — the framebuffer "back-end" chips that sit between REX3 and the VRAM.
  To stay under 304 pins, framebuffer data is byte-serialized across 8 interleaves
  and **deserialized by the RB2s**; the **read/write formatters and the logicop
  function live in the RB2s**, not in REX3. (p.5)
- **Framebuffer** = VRAM (2 Mbit parts) in an **8-way interleave + Y-axis interleave**
  for write bandwidth. Resolution 1280×1024, up to 76 Hz refresh.
- **RO1** ×3 reorganizes the VRAM serial-port stream; **XMAP9** does color-index
  lookup (or passes RGB) via the **CMAP** SRAMs; **RAMDAC** applies gamma and drives
  RGB. **VC2** generates all display timing. (p.6)
- Plane configuration is upgradable: 8 pixel + 2 PUP + 2 CID planes, up to
  24 pixel + 8 overlay (or 4+4) + 2 PUP + 2 CID. (p.5)

**Inside REX3** (Figures 2–3, p.9–10) — three logical blocks:

1. **GIO block** — GIO64 bus slave front-end. Decodes host accesses to REX3's own
   registers vs. accesses bound for the display subsystem (sent over the DCB).
   Host interface is a FIFO, 64 wide × 32 deep (the **GFIFO**). Runs at 33 MHz.
2. **Iterator block** — generates framebuffer addresses, interpolates color,
   handles masking/patterning, and does the Bresenham line/anti-aliasing math and
   the framebuffer interleave swizzle. Runs at 33 MHz.
3. **Memory controller + pixel pipe** — **four instances** (banks A/B/C/D), each with
   a VRAM controller plus the CID-check, color-compare, dither and blend functions.
   Runs at **66 MHz**, page-mode cycle = 4 clocks (~60 ns). Each bank has its own
   4-bank-FIFO (one write + two read FIFOs). (p.6)

Two shaded pixels/clock are produced (two RGBA iterators); flat spans do 4 px/clock;
fast-clear does 32 px/clock. See Performance, p.7.

---

## Host interface

**Address window.** REX3 is a pipelined **GIO64 slave**. Base address is
`0x1F_n0_0000` where the nibble `n ∈ {0,4,8,C}` is set by the `SLOT_NUMBER[1:0]`
strap pins — i.e. `0x1F000000 / 0x1F400000 / 0x1F800000 / 0x1FC00000`. The two
high SLOT_NUMBER bits are assumed `0001_1111`, so the subsystem only lives in GIO64
slots C/D/E/F; up to four heads by populating all four. (p.12, p.20, p.84)

**Register window.** All host-visible registers are offsets from that base. Two
shadow windows exist: offsets beginning `0x1nnn` map the same registers into a
separate "protected" page (intended for kernel-only access). Unused bits read 0.
(p.20)

**The GO / non-GO write model.** This is REX3's primitive-launch mechanism:

- Writing a register at its normal offset just loads the register (graphics context).
- Writing the **same register at `offset + 0x0800`** loads it **and issues a
  primitive GO command** — i.e. the write that targets `addr|0x800` is the trigger
  that kicks off the drawing/iteration described by the current mode + coordinate
  state. So the host sets up state with plain writes, then does one `|0x800` write
  to the last coordinate register to fire the primitive. (p.20)
- Register *type* annotations in the map control routing:
  - `⊗` registers act immediately, bypassing both FIFOs (e.g. STATUS, CONFIG, resets).
  - `◊` registers are DCB-related and flow through the **BFIFO** (display-bus FIFO).
  - all others are graphics-context registers and flow through the **GFIFO**.
  - `•` registers stall at the GFIFO output until the graphics pipe is idle.

**FIFOs.** Host writes queue in the **GFIFO** (graphics, 64×32, enlarged to 32-deep/
doubled at timeout); DCB traffic queues in the **BFIFO**. The CONFIG register sets
high-water depths (`GFIFODEPTH`, `BFIFODEPTH`) and interrupt polarity
(`GFIFOABOVEINT`, `BFIFOABOVEINT`); crossing a level asserts `FIFO_INT_N` and/or
stalls the GIO bus via `GRXDLY`. A `TIMEOUT` counter (0.96–4.32 µs) raises
`FIFO_INT_N` if the host stalls too long. STATUS exposes live FIFO levels and sticky
interrupt bits. (p.27–28, p.80–81, p.84)

**Pixel / command path.** There is no separate command FIFO — primitive commands
*are* register writes through the GFIFO. Host pixel data (PIO and DMA) moves through
the **HOSTRW1/HOSTRW0** register pair (`0x0230/0x0234`); see Drawing model below.

**Reset / init.** After GIORESET, REX3 assumes a physically-32-bit GIO64 bus with
external registered transceivers present. The host must program CONFIG
(`EXTREGXCVR`, `BUSWIDTH`, `GIO32MODE`) before any register reads to match the actual
board. (p.83) Bi-endian (little/big) addressing is supported in GIO64 mode. (p.84)

**Interrupts.** `VV_INT_N` = VC2 vertical-retrace (`VERT_INT_N`) OR'd with the
Express-Video option (`VIDEO_INT_N`); `FIFO_INT_N` = GFIFO/BFIFO level/timeout.
Read **STATUS** to clear sticky interrupt bits, or **USER_STATUS** for a
non-destructive read that leaves them set. (p.27, p.84)

---

## Register-group map

Registers are offsets from the GIO base (above). Type column: `⊗` immediate/no-FIFO,
`◊` DCB/BFIFO, `•` stalls until pipe idle, `2c` two's-complement, `sm` sign-magnitude,
`#` write-only command address. Full per-bit definitions are in rex3.pdf Table 7
(p.21–22) and the control-register tables §3.1.1 (p.23–29) — summarized here by group
rather than transcribed.

| Group | Offset range | What it does | Pages |
|---|---|---|---|
| **Drawing-mode / state** | `0x0000`–`0x0024` | `DRAWMODE0` (opcode + addressing mode + iterator-setup enables), `DRAWMODE1` (planes, depth, RGB/CI, dither/blend/logicop, compare), `LSMODE`, `LSPATTERN`/`LSPATSAVE`, `ZPATTERN` (stipple/soft-Z masks), `COLORBACK`, `COLORVRAM` (fastclear color), `ALPHAREF`, `STALL0` | 21,23–27 |
| **Screen masks 0** | `0x0028`–`0x002C` | `SMASK0X/Y` — window-relative GL scissor (min/max) | 21,30 |
| **Setup / command** | `0x0030`–`0x003C` | `SETUP` (octant/Bresenham term calc, no iterate), `STEPZ`, `LSRESTORE`, `LSSAVE` — write-only `#` command addresses | 21 |
| **Vertex / coordinate iterators** | `0x0100`–`0x0158` | `XSTART/YSTART`, `XEND/YEND` (16.4 subpixel), `XSAVE`, `XYMOVE`, plus the GL-format (`XSTARTF…`) and packed-integer (`XYSTARTI`, `XYENDI`, `XSTARTENDI`) aliases | 21 |
| **Bresenham state** | `0x0118`–`0x0134` | `BRESD`, `BRESS1/S2`, `BRESOCTINC1`, `BRESRNDINC2`, `BRESE1`, `AWEIGHT0/1` (anti-alias line weight table). Full state for context switch | 21 |
| **Color / shader (DDA)** | `0x0200`–`0x022C` | `COLORRED/GRN/BLUE/ALPHA` (full shade state), `SLOPERED/GRN/BLUE/ALPHA` (DDA slopes), `WRMASK` (24-bit write mask / double-buffer select), `COLORI` (packed CI/BGR), `COLORX`, `SLOPERED1` | 22 |
| **Host pixel pipe (PIO/DMA)** | `0x0230`–`0x0234` | `HOSTRW1` (MS word), `HOSTRW0` (LS word) — framebuffer PIO/DMA data port | 22,78 |
| **DCB (device control bus)** | `0x0238`–`0x0244` | `DCBMODE` (slave addr, register-select, protocol, timing), `DCBDATA0/1` — host's window onto VC2/XMAP9/CMAP/RAMDAC | 22,29,82 |
| **Screen masks 1–4** | `0x1300`–`0x131C` | `SMASK1X/Y…SMASK4X/Y` — X11 absolute scissor rectangles | 22,30 |
| **Window / config** | `0x1320`–`0x1330` | `TOPSCAN`, `XYWIN` (window X/Y bias), `CLIPMODE` (mask enables + CID-match), `STALL1`, `CONFIG` (bus width/mode, FIFO depths, refresh) | 22,28 |
| **Status / reset** | `0x1338`–`0x1340` | `STATUS` (clears ints), `USER_STATUS` (non-destructive), `DCBRESET` (resets DCB FSM, flushes BFIFO) | 22 |

Notes on the key mode registers (full bit tables p.23–29):

- **DRAWMODE0** (p.23): `OPCODE` = NOOP/READ/DRAW/SCR2SCR; `ADRMODE` =
  SPAN/BLOCK/I_LINE/F_LINE/A_LINE; plus iterator-setup enables (`DOSETUP`,
  `COLORHOST`/`ALPHAHOST` source select, `STOPONX/Y`, `SKIPFIRST/SKIPLAST`,
  patterning/stipple/shade/clamp enables). This register selects *what kind of
  primitive* a GO issues.
- **DRAWMODE1** (p.25): `PLANES` (RGB/CI, RGBA, OLAY, PUP, CID), `DRAWDEPTH`
  (4/8/12/24 bit), double-buffer source, `HOSTDEPTH`/`RWPACKED`/`RWDOUBLE` (host
  pixel packing), `RGBMODE`, `DITHER`, `FASTCLEAR`, `BLEND` + `SFACTOR`/`DFACTOR`,
  `LOGICOP`. Sets the *pixel format and pixel-pipe behavior*.
- **CONFIG** (p.28): bus width/mode, FIFO trigger depths + interrupt sense, GIO
  timeout, VRAM refresh count, fastclear column-mask mode.
- **STATUS** (p.27): `GFXBUSY`/`BACKBUSY` (pipe-idle for context switch), FIFO
  levels, retrace/video interrupt status, sticky FIFO-int flags.
- **DCBMODE** (p.29): `DCBADDR` slave select, `DCBCRS` register select within slave,
  `DATAWIDTH`/`ENDATAPACK` byte packing, sync/async ack protocol enables, programmable
  CS setup/width/hold timing, `SWAPENDIAN`.

---

## Drawing / programming model

**Framebuffer access modes** (p.31–36). A primitive is one of: **point, line, span,
block**, plus **fastclear** and **screen-to-screen move**. Addressing mode is set by
`DRAWMODE0.ADRMODE`; opcode by `DRAWMODE0.OPCODE` (DRAW / READ / SCR2SCR).

- **Lines** (`I_LINE`/`F_LINE`/`A_LINE`, p.32–33): integer, fractional-endpoint, or
  anti-aliased Bresenham. REX3 has the Bresenham steppers in hardware. A line can be
  drawn as: individual points (`STOPONX=STOPONY=0`, host re-issues each point);
  32-pixel segments (`LENGTH32`, for use with the 32-bit stipple/Z pattern masks); or
  a full line in one command. `SKIPFIRST`/`SKIPLAST` suppress shared endpoints of
  connected vectors. Anti-aliased lines use the `AWEIGHT` coverage table.
- **Points** (p.33): an (X,Y) pair, drawn in BLOCK addressing. A DMA of many X,Y
  pairs builds an arbitrary monochrome shape (e.g. a circle).
- **Spans** (p.33–34): horizontal run with an X endpoint; X always steps
  left-to-right. Three sub-modes: host-pixel segments (Segments I), 32-pixel DDA
  segments (Segments II), or a full span in one command (used for DMA reads).
- **Blocks** (p.34–35): rectangular region drawn span-by-span; the XY DDA steps Y and
  reloads X from `XSAVE` each row. Used for polygon fill (host sets X/edges per row)
  and for linear/stride DMA.
- **Fastclear** (p.35): 4× rate area clear, flat fill only — no shade/stipple/
  dither/blend. Load `COLORVRAM` (after setting `RGBMODE`+`DRAWDEPTH`), set
  `FASTCLEAR`, draw a SPAN/BLOCK. No CID checking. 400M px/s.
- **Screen-to-screen move** (p.36): `OPCODE=SCR2SCR`, BLOCK/SPAN; `XYMOVE` gives a
  signed offset **to the destination** (note: REX1 offset to source). Host orders
  endpoints so an overlapping copy doesn't clobber itself.

**Issuing a primitive — the typical sequence:**

1. Program `DRAWMODE0` (opcode + addressing mode + setup/skip enables) and
   `DRAWMODE1` (planes, depth, RGB/CI, dither/blend/logicop).
2. Load color / slope DDA registers (or set `COLORHOST`/`ALPHAHOST` to take pixel
   values from `HOSTRW`), and any pattern/mask registers (`LSPATTERN`, `ZPATTERN`,
   screen masks via `CLIPMODE`).
3. Load coordinate iterators (`XSTART/YSTART/XEND/YEND`, or a packed alias).
4. For line/span/block: write `address=SETUP` first so REX3 computes octant +
   Bresenham terms (skipped if `DOSETUP=0`).
5. **Fire it** by issuing the GO — write the launching register at `offset|0x0800`.
   REX3 iterates and writes pixels through the RB2s into VRAM.

**Pixel pipe** (per-bank, p.70–75): pattern/stipple substitution → CID check →
color-compare / alpha-function (AFUNCTION vs `ALPHAREF`) → **blend** (`Cb = Cs·Fs +
Cd·Fd`, factors in `SFACTOR`/`DFACTOR`; blend and logicop are mutually exclusive) →
**dither** (4×4 Bayer, 1–4-bit RGB and CI) → **logicop** (16 ops, in the RB2) →
write under the 24-bit `WRMASK`. Clipping = sector clip (auto, from coordinate space)
+ up to 5 screen masks + CID masking + color compare.

**Host pixel transfer — PIO & DMA** (p.78–80). To REX3, PIO and DMA are
indistinguishable (both are GIO activity); "word" = 4 or 8 bytes per bus cycle.
Pixel data moves through `HOSTRW1/0`; packing is set by `HOSTDEPTH`, `RWPACKED`,
`RWDOUBLE` (4/8/16/32-bit fields, 1..16 px per 64-bit word). For reads,
`DRAWMODE1.PREFETCH=1` and `OPCODE=READ`; pre-fetch via a `|0x800` write, then read
`HOSTRW`. DMA supports **linear** and **stride** block modes (stride = "virtual
framebuffer" in main memory with a constant address gap per row); span DMA only.
All PIO is context-switchable; reads/writes done for *context save/restore* must NOT
use the `|0x800` GO bit. (p.78–80)

**Device Control Bus (DCB)** (p.82, p.84–85). REX3 is the DCB master; it programs the
downstream display chips. Host writes `DCBMODE` (selecting the slave via `DCBADDR`,
the slave-internal register via `DCBCRS`, the protocol and timing), then reads/writes
`DCBDATA0/1`; the transaction is replayed on the 8-bit DCB. DCB slave map (`DCBADDR`):

| `DCBADDR` | Device | | `DCBADDR` | Device |
|---|---|---|---|---|
| 0000 | VC2 | | 0101 / 0110 | XMAP0 / XMAP1 |
| 0001 | CMAP0+1 (write) | | 0111 | RAMDAC |
| 0010 / 0011 | CMAP0 / CMAP1 | | 1000 / 1001 | Video CC1 / AB1 |
| 0100 | XMAP0+1 (write) | | 1111 | reserved (null) |

Protocol is sync, async (4-edge handshake on `DCB_CS_N`/`DCB_ACK_N`), or
fully-timed (programmable CS setup/width/hold) per `DCBMODE`. Peak 1 byte/cycle
(sync) down to 1 byte / 4 cycles (async). (p.82, p.29)

**Context switching** (p.81). Two contexts: graphics and display-bus. Poll STATUS for
`GFXBUSY=0` & `GFIFOLEVEL=0` (or `BACKBUSY=0` for the DCB) before save. Save reads
every register that has a documented read format (often a subset suffices); restore
writes them back. Caveat: `SLOPERED` must be converted s2c→sign-magnitude on restore,
`COLORRED` restored with `RGBMODE=1`, and `XSAVE` restored *after* `XSTART`. Never use
the GO bit during save/restore.

---

## Henry relevance / implementation scope

**Headless Henry (today):** REX3's window (`0x1f000000`, slots C–F) is unimplemented;
any access bus-errors. Nothing here is boot-critical — IP22/Indy boots a serial
console without touching Newport. No action required for the current SoC.

**Future Henry graphics console:** implementing REX3 is essentially the *whole*
graphics-console effort, in three layers of decreasing tractability:

1. **GIO64 register face (most tractable).** A GIO64 slave decoding the
   `0x1F_n0_0000` window, the full register file (Table 7), the GFIFO/BFIFO with the
   CONFIG-programmed depths and `FIFO_INT_N`/`GRXDLY` flow control, the STATUS/
   USER_STATUS interrupt model, and the `|0x0800` GO write-trigger. This is bounded,
   well-specified register/FIFO logic — the natural first milestone (even a stub that
   accepts writes, drains the FIFO, and toggles `GFXBUSY` would stop the bus-error and
   let a driver probe).
2. **Draw pipeline (the bulk of the work).** The iterator block: Bresenham line/
   anti-alias steppers, the X/Y and R/G/B/A/CI DDAs, span/block/point/fastclear/
   scr2scr address generation, screen-mask + CID + color-compare clipping, and the
   per-bank pixel pipe (pattern → blend → dither → logicop → writemask). This is the
   genuinely large piece. A Henry implementation could collapse the 4-bank ×66 MHz
   interleave + RB2 split (a bandwidth optimization for real VRAM) into a single
   straightforward framebuffer writer — i.e. keep the *programming model* but not the
   physical 8-way interleave.
3. **Framebuffer + display chain.** A linear framebuffer (no VRAM serial-port/RO1
   reorg needed if scanout is done differently), plus *some* answer for the DCB
   sub-devices (VC2 timing, XMAP9/CMAP color lookup, RAMDAC). For a Henry console the
   pragmatic path is to **stub the DCB** (ACK writes, return plausible reads) and
   drive a modern display controller for actual scanout, rather than reimplementing
   VC2/XMAP9/CMAP/RAMDAC. The DCB programming model still has to *exist* because the
   driver pokes it during init.

Recommended scoping order: (1) register/FIFO face to clear the bus-error and satisfy a
probing driver → (2) SPAN/BLOCK flat-fill + fastclear + screen-to-screen (enough for a
console: clear, scroll, blit glyphs) → (3) lines/shading/blend only if a real GL/X
stack is targeted. Subpixel anti-aliased lines and the full DDA shader are the
least-essential, highest-effort parts.

---

## Sources

All citations are to `/home/dsheffie/code/sgi/docs/indy_docs/newport/rex3.pdf`
(SGI Newport REX3 Specification, Rev 1.0, Aug 1993):

- **p.5** — part number, general description, features.
- **p.6** — Newport architecture (Fig 1 components), REX3 architecture (3 logical
  blocks, FIFO sizes, 4-bank 66 MHz memory controllers).
- **p.7** — performance table.
- **p.8–10** — Fig 1 (subsystem), Fig 2 (top-level block), Fig 3 (internal data path).
- **p.11–13** — pin diagram and pin descriptions (GIO64, VRAM/RB2, DCB).
- **p.20** — register addressing model: base `0x1FnF0000`, `+0x0800` = GO, register
  type flags (`⊗`/`◊`/`•`).
- **p.21–22** — Table 7, full host-visible register map.
- **p.23–29** — §3.1.1 control-register bit definitions (DRAWMODE0/1, LSMODE,
  CLIPMODE, STATUS, CONFIG, DCBMODE).
- **p.30–31** — coordinate system, clipping/masking, iterator overview.
- **p.32–36** — framebuffer access modes (lines, points, spans, blocks, fastclear,
  scr2scr).
- **p.70–75** — framebuffer data values, patterning/stipple, dither, color rounding,
  logicop, blend.
- **p.76–77** — framebuffer pixel formats (Tables 22–23).
- **p.78–80** — framebuffer PIO and DMA, HOSTRW packing, PIO/DMA case table.
- **p.80–81** — FIFO management, context switching.
- **p.82–83** — Display Control Bus, DCB slave map, chip reset/init.
- **p.84–85** — System Interface: GIO64 bus interface, DCB interface.
- **p.86** — VRAM interface (memory-controller state machines, 66 MHz timing).
- (Chapter 5, p.108+ — gate-level architectural/FSM detail; implementation-internal,
  intentionally not summarized here.)
