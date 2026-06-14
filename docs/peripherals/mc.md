---
title: MC — Memory Controller
status: draft (MAME-validated)
source: SGI IP22 MC spec (mc.pdf); MAME golden reference
---

# MC — Memory Controller (Henry block spec)

> Henry's main-memory + system-control block lives at phys base `0x1fa00000` (kseg1 `0xbfa00000`). The MC owns
> CPU/system control (CPUCTRL0/1), the SYSID the kernel probes, the refresh & RPSS free-running counters, the
> SIMM-geometry registers (MEMCFG0/1), DRAM timing words (MEMACC), the watchdog, error-capture registers, the
> GIO64 arbiter, locks/semaphores, and the graphics/GIO DMA engine. **#1 gotcha: every MC register is on an
> 8-byte stride and big-endian IRIX reads the +4/+c alias, not the table offset** — see the next section before
> trusting any address. Legend: ✅ confirmed in MAME, ⚠️ correction vs the SGI doc / vs earlier MAME notes.

## Role in Henry

The MC is the system's spine: the R4000-class core (r9999) talks to DRAM through it, and the boot PROM / ARCS
shim / IRIX kernel poke its control registers to size memory, calibrate clocks (via the RPSS and refresh
counters), set the endian mode, and arm the watchdog. For a headless Henry boot, the MC must answer a small set
of register reads/writes correctly and **route real DRAM**; the DMA engine, GIO64 arbiter, EISA lock, and
semaphores can be inert storage. Interrupts the MC could raise (parity, watchdog, PROM-write, DMA-done) are all
maskable/disabled at reset and are not needed for first boot.

## Address base & the big-endian alias

**The MC sits on the low 32 bits (`sysad[31:0]`) of the 64-bit sysad doubleword. Every register therefore answers
at TWO byte addresses 4 apart, and which one the CPU uses depends on endian mode** (mc.pdf p.25):

- **Big-endian CPU (Henry/IRIX default): use the odd-word address — table offset `+4` (ends in `4` or `c`).**
- Little-endian CPU: use the even-word address — the table offset itself (ends in `0` or `8`).

So the "table offset" column below is the canonical/LE address; the "BE alias" column (= offset `+4`) is **what
IRIX actually reads**. Concretely:

| what IRIX touches | is the BE alias of | table reg |
|----|----|----|
| `0xbfa00004` | `0xbfa00000` (+4) | **CPUCTRL0** ⚠️ (not a separate "bus-sync" reg — kernel's repeated uncached read = write-buffer flush / clock calibration of CPUCTRL0) |
| `0xbfa000c4` | `0xbfa000c0` (+4) | **MEMCFG0** |
| `0xbfa000cc` | `0xbfa000c8` (+4) | **MEMCFG1** |

Implementation: decode `pa[?:3]` (8-byte granule) for the register select and **ignore `pa[2]`** (the +4/+0
alias bit) — both halves of the doubleword map to the same 32-bit register. Drive/return data on the low 32
sysad bits in either case.

Containing memory-map context (mc.pdf p.22): MC registers occupy `0x1fa00000–0x1faffff` (1 MB). Henry's RAM
windows: **Low Local Memory `0x08000000–0x17ffffff` (256 MB)** and **High System Memory `0x20000000–0x2fffffff`
(256 MB, kseg-mapped only)** ⇒ up to **30-bit PA** ⚠️ (not 29 — earlier 29-bit note was a small-RAM artifact).
The **bottom 512 KB `0x0–0x7ffff` ALIASES low RAM** so exception vectors `0x0`/`0x80` hit `0x08000000`/`0x08000080`.

## Register map

Offsets are table offsets (add `+4` for the BE alias IRIX uses). Full chip table is mc.pdf p.24–25.

| table off | BE alias | name | R/W | reset | fields / function |
|----|----|----|----|----|----|
| `0x00` | `0x04` | **CPUCTRL0** | R/W | see §CPUCTRL0 | refresh/parity/endian/watchdog/sysinit |
| `0x08` | `0x0c` | CPUCTRL1 | R/W | `0x0000000C` | MC fifo HWM[3:0]=0xC, GIO timeout, HPC/EXP endian |
| `0x10` | `0x14` | DOGC(r)/DOGR(w) | R/W | 0 | 20-bit watchdog: read counter / write clears it |
| `0x18` | `0x1c` | **SYSID** | R | rev-dep | [3:0] CHIP_REV (0=RevA,1=RevB), [4] EISA-present |
| `0x28` | `0x2c` | RPSS_DIVIDER | R/W | DIV=4,INC=1 | RPSS counter divide[7:0] / increment[15:8] |
| `0x30` | `0x34` | EEROM | R/W | 0 | serial config EEROM bit-bang (CS[1],SCK[2],SO[3],SI[4]) |
| `0x40` | `0x44` | CTRLD | R/W | `0x0C30` | refresh counter preload (CPU cycles in 62.5 µs) |
| `0x48` | `0x4c` | REF_CTR | R | counts | 16-bit refresh counter — **must advance** |
| `0x80` | `0x84` | GIO64_ARB | R/W | dev-dep | GIO64 arbiter sizing/RT/master/pipe bits |
| `0x88` | `0x8c` | CPU_TIME | R/W | `0x100` | GIO64 cycles in CPU arb time period |
| `0x98` | `0x9c` | LB_TIME | R/W | `0x200` | GIO64 cycles in long-burst arb time period |
| `0xc0` | `0xc4` | **MEMCFG0** | R/W | VLD=0 | banks 0&2 ⚠️ (see §MEMCFG) |
| `0xc8` | `0xcc` | **MEMCFG1** | R/W | VLD=0 | banks 1&3 ⚠️ |
| `0xd0` | `0xd4` | CPU_MEMACC | R/W | timing | CPU DRAM timing word (opaque; store/return) |
| `0xd8` | `0xdc` | GIO_MEMACC | R/W | timing | GIO64 DRAM timing word |
| `0xe0` | `0xe4` | CPU_ERROR_ADDR | R | 0 | CPU error address |
| `0xe8` | `0xec` | CPU_ERROR_STAT (r)/CLR (w) | R/W | 0 | CPU error status; write clears |
| `0xf0` | `0xf4` | GIO_ERROR_ADDR | R | 0 | GIO error address |
| `0xf8` | `0xfc` | GIO_ERROR_STAT (r)/CLR (w) | R/W | 0 | GIO error status; write clears |
| `0x100` | `0x104` | SYS_SEMAPHORE | R/W | 0 | system semaphore (R/W storage) |
| `0x108` | `0x10c` | LOCK_MEMORY | R/W | unlocked | lock GIO out of memory |
| `0x110` | `0x114` | EISA_LOCK | R/W | unlocked | lock EISA bus |
| `0x150`/`0x158` | +4 | DMA_GIO_MASK / DMA_GIO_SUB | R/W | 0 | GIO64 addr translate mask / substitution |
| `0x160`/`0x168` | +4 | DMA_CAUSE / DMA_CTL | R/W | 0 | DMA interrupt cause / control |
| `0x180`–`0x1b8` | +4 | DMA_TLB_{HI,LO}_{0..3} | R/W | 0 | 4-entry DMA µTLB |
| `0x01000` | `0x01004` | **RPSS_CTR** | R | counts | free-running 32-bit **100 ns** counter (separate 4 KB page) |
| `0x02000`+ | +4 | DMA engine (DMA_MEMADR…DMA_RUN) | R/W | 0 | graphics/GIO virtual DMA (see VDMA doc) |
| `0x10000`+`n*0x1000` | +4 | SEMAPHORE_0..15 | R/W | 0 | 16 hardware test-and-set semaphores (4 KB-spaced) |

## MEMCFG bank encoding

Each MEMCFG register packs **two banks** in its 32 bits — a high half and a low half, each with 4 fields
(BASE, MSIZE, VLD, BNK). ⚠️ **Bank pairing: MEMCFG0 = banks {0,2}, MEMCFG1 = banks {1,3}** (MAME-validated;
the SGI doc p.33 text says MEMCFG0={0,1}/MEMCFG1={2,3}, but Henry follows the MAME pairing). Field bit layout
(mc.pdf p.33):

| bits | field | meaning |
|----|----|----|
| `[7:0]` | BASE (low-half bank) | base address, compared against **phys `[29:22]`** (i.e. value `<<22`); `[31:30]` always 0 |
| `[12:8]` | MSIZE (low-half bank) | SIMM size code (table below) |
| `[13]` | VLD (low-half bank) | 1 = SIMM slot populated (reset 0) |
| `[14]` | BNK (low-half bank) | 0 = one subbank, 1 = two subbanks |
| `[15]` | — | reserved |
| `[23:16]` | BASE (high-half bank) | base, phys `[29:22]` |
| `[28:24]` | MSIZE (high-half bank) | size code |
| `[29]` | VLD (high-half bank) | valid (reset 0) |
| `[30]` | BNK (high-half bank) | subbanks |
| `[31]` | — | reserved |

**SIMM size table** (MSIZE code → SIMM type → bank bytes, ×4 SIMMs/bank):

| MSIZE | SIMM | subbanks | bank size |
|----|----|----|----|
| `00000` | 256K×36 | 1 | 1 MB |
| `00001` | 512K×36 | 2 | 2 MB |
| `00011` | 1M×36 | 1 | 4 MB |
| `00111` | 2M×36 | 2 | 8 MB |
| `01111` | 4M×36 | 1 | 16 MB |
| `11111` | 8M×36 | 2 | 32 MB |

Rules: SIMMs install in groups of 4 (one bank); all four must be same size; base must be aligned to bank size;
configure largest SIMMs at lowest base (size-descending) or you get holes/overlap. If two banks decode the same
address ⇒ bus-error interrupt and the access does not complete.

**Worked decode of MEMCFG0 = `0x23200000`** ✅ (Henry's live MAME value):
- Bits `[31:16]` = `0x2320` → high-half bank (bank 0): BASE0 = `0x20`, MSIZE0 = `0b00011`, VLD0 = 1, BNK0 = 0.
- Bits `[15:0]` = `0x0000` → low-half bank (bank 2): VLD2 = 0 (absent).
- BASE0 `0x20` → base phys = `0x20 << 22 = 0x08000000` ✅ (start of Low Local Memory).
- MSIZE0 `0b00011` = 1M×36 SIMM ⇒ **16 MB bank** (4 SIMMs). ⚠️ (earlier note "size=base" was wrong; base and
  size are independent fields — this is a 16 MB bank based at `0x08000000`.)

## Behavior / semantics

- **Refresh / CTRLD / REF_CTR:** CTRLD (reset `0x0C30`) is the preload for a down-counter clocked at the CPU rate
  (20 ns @ 50 MHz); on reaching 0 it reloads from CTRLD and issues a refresh burst. REF_CTR returns the live
  16-bit count. **REF_CTR must advance** between reads — the kernel busy-loops on it for clock calibration.
- **Watchdog (CPUCTRL0.DOG / DOGC / DOGR):** 20-bit counter counting refresh bursts (~64 µs each ⇒ rollover
  ~67 s). Enabled by CPUCTRL0.DOG; rollover to 0 resets the machine. Writing DOGR (any data) clears it; software
  must pet it at least every ~60 s. Off at reset.
- **RPSS_CTR (`0x1000`, own 4 KB page):** free-running 32-bit counter that ticks **every 100 ns** (RPSS_DIVIDER
  DIV/INC scale CPU clocks → 100 ns; for 50 MHz: DIV=4 (÷5), INC=1). Used as a fine-grained timestamp/calibration
  source; must be monotonic.
- **Endian bit (CPUCTRL0.LITTLE, bit18):** 0 = big-endian, 1 = little. Normally loaded from the EEROM at reset;
  the BIG/LITTLE MC pin must match the R4000's mode or the machine won't run. Henry is **big-endian** ⇒ LITTLE=0.
- **Error registers (`0xe0`–`0xf8`):** CPU/GIO error address + status capture on parity/bus errors; status reg is
  read to inspect, **written (any value) to clear**. Henry returns 0 / clears cleanly (no parity enabled at reset).
- **Locks / semaphores:** LOCK_MEMORY, EISA_LOCK reset unlocked; the 16 SEMAPHORE_n and SYS_SEMAPHORE are R/W
  storage for Henry (no real multi-master arbitration needed on a uniprocessor headless build).

## Minimum for a Henry IRIX boot

Must-implement subset (everything else can be inert storage that reads back what was written):

1. **CPUCTRL0** (`0x00`/+4) — R/W; honor LITTLE=0 (BE); reset value with REFS=2, RFE=1; the `0xbfa00004`
   uncached reads must return the stored CPUCTRL0. → verify: kernel's clock-calibration read loop doesn't hang.
2. **SYSID** (`0x18`/+4) — R; return CHIP_REV in `[3:0]`, **EISA bit `[4]` = 0** (Indy has no EISA). → verify:
   IRIX MC-identification probe passes.
3. **CTRLD + REF_CTR** (`0x40`,`0x48`) — REF_CTR must advance; CTRLD R/W storage. → verify: refresh-calibration
   loop terminates.
4. **RPSS_CTR** (`0x1000`) + RPSS_DIVIDER — monotonic 100 ns counter. → verify: timestamp deltas are positive.
5. **MEMCFG0 / MEMCFG1** (`0xc0`,`0xc8`/+4) — decode to Henry's actual RAM geometry; back real DRAM in the
   decoded window. → verify: ARCS memory descriptors + kernel sizing see the right amount of RAM.
6. **CPU_MEMACC / GIO_MEMACC** (`0xd0`,`0xd8`) — store/return opaque timing words. → verify: writeback then
   readback matches.
7. **Error regs** (`0xe0`–`0xf8`) — read 0, write-to-clear. → verify: no spurious bus-error handling.

## Golden vectors (from MAME)

Concrete block test vectors (use as DV checks):

| address (BE) | reg | value | decode |
|----|----|----|----|
| `0xbfa000c4` | MEMCFG0 | `0x23200000` ✅ | bank0: base `0x08000000`, 16 MB, valid; bank2 absent |
| read of `0xd4` | CPU_MEMACC | `0x11453433` ✅ | opaque DRAM timing word — store & return verbatim |
| `0xbfa0001c` | SYSID | `[3:0]`=CHIP_REV (RevA=0/RevB=1), `[4]`=0 | EISA absent ⇒ Indy |
| `0xbfa00004` | CPUCTRL0 alias ⚠️ | (stored value) | NOT a bus-sync reg; BE alias of CPUCTRL0@`0x00` |
| `0xbfa00044` | CTRLD | `0x0C30` (reset) | refresh preload |
| `0x1fa01000` | RPSS_CTR | monotonically increasing | +1 per 100 ns |

Sanity: `BASE 0x20 << 22 == 0x08000000`; MSIZE `0b00011` ⇒ 16 MB; phys mask uses bits `[29:22]` (30-bit PA).

## Open / not-yet-needed

These can be **stubbed as R/W storage** (write returns on read) for an initial headless boot and fleshed out
later:

- **DMA engine** (`0x02000`+, DMA_MEM/SIZE/STRIDE/GIO/MODE/COUNT/RUN + DMA_TLB 0–3 + DMA_CAUSE/CTL): the
  graphics/GIO virtual-DMA blitter (FastForward). DMA_RUN polled-busy can just return "not running" (0).
- **GIO64 arbiter** (GIO64_ARB, CPU_TIME, LB_TIME): no real GIO masters on headless Henry ⇒ arbitration never
  runs; treat as R/W storage (PROM writes timing, nobody arbitrates).
- **Semaphores / locks** (SEMAPHORE_0..15, SYS_SEMAPHORE, LOCK_MEMORY, EISA_LOCK): R/W storage on a uniprocessor.
- **EEROM** (`0x30`): the endian bit is fixed BE in Henry; the bit-bang interface can swallow writes / return a
  stable SI.
- **Parity / watchdog / PROM-write interrupts**: all disabled at reset; leave unimplemented until needed.

## Sources

- SGI IP22 **MC Chip Specification** (`mc.pdf`): §4 Physical Address Space (p.22–23); §5 MC Internal Registers
  table + the 8-byte-stride / +4(BE) /+0(LE) alias text (p.24–25); §5.1 CPUCTRL0 (p.26–27); §5.2 CPUCTRL1, §5.3
  Watchdog DOGC/DOGR (p.28); §5.4 SYSID, §5.5 RPSS Divider, §5.6 EEROM (p.29–30); §5.7 CTRLD, §5.8 REF_CTR, §5.9
  GIO64_ARB (p.30–31); §5.10 CPU_TIME, §5.11 LB_TIME, §5.12 MEMCFG0/1 + SIMM size table (p.32–33); §5.13
  CPU_MEMACC/GIO_MEMACC (p.33).
- r9999 working docs: `/home/dsheffie/code/r9999/IP22_CHIP_REGISTERS.md` — the MC § and the "CONTRADICTIONS /
  CORRECTIONS vs MAME" items (BE +4/+c alias; banks {0,2}/{1,3}; MEMCFG decode of `0x23200000`; 30-bit PA;
  `0xbfa00004` = CPUCTRL0 alias).
