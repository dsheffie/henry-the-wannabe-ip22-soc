---
title: IOC2 — I/O Controller (serial console)
status: draft (MAME-validated)
source: SGI IP22 IOC spec (ioc.pdf); MAME golden reference
---

# IOC2 — I/O Controller (Henry block spec)

> Intro: IOC2 @ phys base 0x1FBD9800 — serial (Z8530 SCC), INT3 interrupt controller, 8254 timer, kbd/mouse,
> parallel, boot-ID/power regs. THE serial console lives here and is the #1 Henry bring-up target. Legend ✅ = MAME-validated / must-have; ⚠️ = stub or not-yet-needed.
>
> The IOC2 is a single VTI ASIC ("Guinness" variant for Indy) holding six macrocells: VTI 85CX30 serial DUART,
> SGI PI1 parallel, Intel 8042 kbd/mouse, Intel 8254 timer, SGI INT3 interrupt mux, and miscellaneous glue
> (power/ID/reset). It hangs off the HPC3 P-bus (PBUS_CS_N<6>); registers are 64 word-spaced (×4) slots at base
> 0x1FBD9800. All addresses below are absolute physical (k1seg uncached: OR 0xA0000000).

## Role in Henry  (and why it's the first peripheral to implement)
Henry is a headless, PROM-less r9999 SoC whose entire observable output during IRIX bring-up is the **serial
console**. MEASURED (2026-06-13, IRIX 6.5 boot, `console=d`): the IRIX kernel does **NOT** route the console
through ARCS — `arcs_write`=0, `romvec[Write]`=0 over a full boot. Both the PROM diagnostic phase
("Running power-on diagnostics…") and the kernel phase ("IRIX Release 6.5 IP22…") write the **Z8530 SCC
directly** via the `du_*` serial driver (`du_putchar`/`ducons_write`). The "free output via the ARCS Write
hook" path therefore does **not** work — Henry must emulate a minimal Z8530 at the IOC2 SCC address or it boots
blind. That makes IOC2 the first peripheral: get ~10 lines of polled TX working and Henry can print, after
which every other bring-up step is observable. Ground truth for the stream was captured with a C++ hook on the
SCC TX register (`scc_dc_w` in MAME `src/mame/sgi/ioc2.cpp`).

## Serial console (Z8530 SCC) — THE priority
The 85CX30 is a Zilog Z85230-class **dual-channel** ESCC. **Indy console = Port 1, channel A.** The macrocell
uses Zilog **indirect addressing**: the IOC2 decodes two address lines into 4 byte addresses, where
**addr bit1 = channel** (0 = Port1/chan A, 1 = Port2/chan B) and **addr bit0 = data/command** (0 = command/
register, 1 = data). ✅ Confirmed against MAME `map(0x0c,0x0f) -> z80scc ab_dc_r/w`.

| Addr (phys) | IOC word | Z8530 access | r9999 behavior |
|-------------|----------|--------------|----------------|
| `0x1FBD9830` | 0x0c | Port1 (chan A) **command/RR0** | **read → return `0x04`** (RR0 bit2 Tx Buffer Empty). write → swallow (WR pointer/select). ✅ |
| `0x1FBD9834` | 0x0d | Port1 (chan A) **data** | **write[7:0] → emit byte to console sink (stdout).** read → 0 (no Rx). ✅ THIS is `du_putchar`'s store. |
| `0x1FBD9838` | 0x0e | Port2 (chan B) command/RR0 | return `0x04`, swallow writes (2nd serial port — not console). ⚠️ |
| `0x1FBD983C` | 0x0f | Port2 (chan B) data | swallow / 0. ⚠️ |

Minimal TX recipe (the whole console for Henry):
1. **Write `0x1FBD9834`** → take `data[7:0]`, append to the console output sink. That's the printed character.
2. **Read `0x1FBD9830`** → always return **`0x04`** so the driver's "wait for Tx empty" poll (`while(!(RR0&4));`)
   never stalls. (Real RR0: bit2 = Tx Buffer Empty, bit0 = Rx Char Available, bit3 = DCD, …; Henry only needs
   bit2 = 1, rest 0.)
3. **Write `0x1FBD9830`** → **swallow.** These are WR-pointer selects and WR-register loads (baud, mode, IE).
   Henry models no internal SCC register file; a stateless drain ignores them. Baud (DMA_SEL `0x9868[5:4]`,
   default 00 = 10 MHz internal) is irrelevant to a stdout drain.

Note: IRIX talks to this register **directly**, not through ARCS — so emulating these 4 addresses is mandatory,
not optional. ~10 lines of logic (decode 2 addrs, mux a constant, forward a byte) buys the entire boot log.

## INT3 interrupt controller
Base `0x1FBD9880` (registers `0x1FBD9880`–`0x1FBD98AC`, ioc.pdf §2.5 + §4.5). INT3 multiplexes system interrupts
onto **5 CPU interrupt outputs** CPU_INT_N<4:0>, wired to CP0 Cause IP2..IP6. INT3 does **no internal latching**
except the two 8254 timer interrupts; it expects already-latched, level-triggered, **active-high** status (a `1`
= active interrupt regardless of mask/polarity). Each register is a **byte at a 4-byte-aligned address** (kernel
does `readb`/`writeb`); masks reset to 0 (all masked).

### 5 output levels → CPU IP pins
Across the 5 levels there are **27 distinct physical interrupt sources**.

| INT3 Level | CPU pin | Sources | Maskable | Latched |
|-----------|---------|---------|----------|---------|
| Level 0 — Local0 | **IP2** | 8 (incl. MAP_INT0) | yes (`imask0`) | no (level) |
| Level 1 — Local1 | **IP3** | 8 (incl. MAP_INT1) | yes (`imask1`) | no (level) |
| Level 2 — Timer0 | **IP4** | 1 (8254 cnt0)      | no | **yes** (clr `tclear[0]`) |
| Level 3 — Timer1 | **IP5** | 1 (8254 cnt1)      | no | **yes** (clr `tclear[1]`) |
| Level 4 — Bus Error | **IP6** | 3                | no INT3 mask¹ | no |

¹ Bus errors have no mask *inside* INT3, but IP6 is still gated at the CPU like any line (`Status.IM[6]`/`IE`/`EXL`) — it is **not** a true NMI.

### Register / source enumeration (§4.5)
| Reg | Addr | Bits (b7…b0) |
|-----|------|--------------|
| Local0 Status (`istat0`) | `0x9880` (R) | b7 **MAP_INT0**, b6 Graphics, b5 Parallel, b4 MC-DMA-done, b3 ENET, b2 SCSI1, b1 SCSI0, b0 FIFO-full |
| Local0 Mask (`imask0`) | `0x9884` (RW) | same bit order; `1`=enable, default 0 (masked) after reset |
| Local1 Status (`istat1`) | `0x9888` (R) | b7 Vretrace, b6 Vsync, b5 AC-Fail, b4 HPC-DMA-done, b3 **MAP_INT1**, b2 GP_LOCAL1<2> (active-low, new in INT3), b1 Panel (pwr/vol buttons), b0 GP_LOCAL1<0> (active-low, new in INT3) |
| Local1 Mask (`imask1`) | `0x988C` (RW) | same order, default 0 |
| Map Status (`vmeistat`) | `0x9890` (R) | 8 mappable ints; b5 = **Serial DUART**, b4 = Kbd/Mouse, b<7:6>/b<3:0> general. Status unaffected by mask/pol |
| Map Mask0 (`cmeimask0`) | `0x9894` (RW) | routes mappables → **MAP_INT0** (Local0 b7); b5 reserved=serial, b4 reserved=kbd |
| Map Mask1 (`cmeimask1`) | `0x9898` (RW) | routes mappables → **MAP_INT1** (Local1 b3) |
| Map Pol (`cmepol`) | `0x989C` (RW) | polarity; `1`=active-high, `0`=active-low (default). **Serial(b5)/Kbd(b4) are active-low → leave 0** |
| Timer Clear (`tclear`) | `0x98A0` (W) | b1 clears Timer1 int, b0 clears Timer0 int |
| Error Status (`errstat`) | `0x98A4` (R) | b2 HPC-bus-err, b1 MC-bus-err, b0 EISA-err — 3 bus errors → IP6, **no INT3 mask** (the controller can't gate them; still maskable at the CPU via `Status.IM[6]`) |

### The mappable cascade
There are **8 mappable, polarity-selectable inputs** (Map Status `0x9890`). Each is gated by **two** independent
masks: `Map Mask0` (`0x9894`) ORs the selected mappables into **MAP_INT0** → Local0 b7 → IP2, and `Map Mask1`
(`0x9898`) ORs them into **MAP_INT1** → Local1 b3 → IP3. Polarity per bit is set by `Map Pol` (default active-low),
but a hard `1` is always active regardless of polarity. The **SCC serial interrupt is mappable bit 5** → routed
via Map Mask0 to MAP_INT0 → istat0 b7 (the kernel's "LIO2") → **IP2**; this is the path for keyboard/console RX.

### Henry relevance — what actually fires
Of the 27 sources, only a handful have a real device model or plausible assertion in Henry:
- **Serial DUART** (Map Status b5) → MAP_INT0 → **IP2** — console/keyboard RX. **The one live source to wire next**
  (we have the SCC in `ioc.sv`).
- **Timer0/Timer1** (IP4/IP5) — our 8254 is **calibration-only (no IRQ)**; Linux/IRIX drive the system tick from
  CP0 Count/Compare on **IP7**, so these stay 0.
- **SCSI0/1** (IP2) — relevant only once there's a root disk; no SCSI model yet.
- **Bus errors** (IP6) — could be asserted from a bad-address fault if ever desired; not modeled.
- Everything else (graphics, parallel, ENET, panel, vsync/retrace, AC-fail, GP, ISDN) — no device, stays 0.

### Implementation — `rtl/int3.sv` (skeleton, 2026-06-18)
INT3 is a standalone module **`rtl/int3.sv`**, instantiated in `henry_soc.sv` sharing the IOC2 access window (its
registers sit at lines `0x80`/`0x90`/`0xa0`; `ioc.sv` reads 0 there, so `w_rd_ioc = w_rd_iocdev | w_rd_int3`).
Its 5 outputs drive `core_l1d_l1i`'s `ip2..ip6` pins (this replaced the old 1-bit `extern_irq`). Aggregation:
`ip2 = |(istat0 & imask0)`, `ip3 = |(istat1 & imask1)`, `ip6 = |buserr` (unmaskable), `ip4/ip5` = the two latched
timer IRQs; `map_int0 = |(vmeistat & cmeimask0)` feeds `istat0[7]`. The §4.5 RW registers (`imask0`, `imask1`,
`cmeimask0`, `cmeimask1`, `cmepol`) and the timer latches (tclear-cleared) are modeled; the device **sources are
input ports tied to 0** for now (skeleton) → `ip2..ip6 = 0`, inert.

Source-port mapping:
- `local0_src[6:0]` = istat0 b6..b0 (Graphics/Parallel/MC-DMA/ENET/SCSI1/SCSI0/FIFO); b7 (MAP_INT0) computed.
- `local1_src[7:0]` = istat1 (b3 = MAP_INT1 computed, that input bit ignored).
- `map_src[7:0]` = the 8 mappable inputs (**`[5]` = serial RX** is the one to wire).
- `buserr[2:0]` = {HPC, MC, EISA}; `timer0_irq`/`timer1_irq` = the 8254 latched IRQs.

**Next:** wire the SCC serial RX — host stdin → SCC Rx FIFO in `ioc.sv` (RR0 bit0 Rx-Char-Available) → drive
`map_src[5]` → MAP_INT0 → IP2, enabling interrupt-driven console input at the IRIX/Linux prompt. (Not needed for
the polled-TX boot console; IRIX's du driver polls RR0 for TX.)

## 8254 timer
Standard Intel 82C54 PIT, 3 counters, fed by a divide-by-20 state machine off CLK_20MHz → **1 MHz / 1 µs tick**.
Counter2 output clocks Counter0 and Counter1; Counter0 terminal count → Timer0 int (INT3 IP4, the system tick),
Counter1 TC → Timer1 int (IP5). Registers at base `0x1FBD98B0`:

| Reg | Addr |
|-----|------|
| Counter 0 | `0x98B0` |
| Counter 1 | `0x98B4` |
| Counter 2 | `0x98B8` |
| Control Word | `0x98BC` |

⚠️ Not on the critical console path. IRIX needs a working tick eventually (scheduler/`clock`), but the polled
serial boot reaches its first console output before the timer matters. Implement as a real 82C54 (mode-3 square
wave on C0) when chasing past early boot.

## Boot-identification & power regs
PROM/IRIX probe these during early init; Henry must return plausible values or init stalls/branches wrong. Most
are simple constant-return or accept-and-store.

| Reg | Addr | r9999 must return / accept | Notes |
|-----|------|---------------------------|-------|
| System ID | `0x9858` | **`0x26`** (Guinness) | b<7:5>=001 chip rev (≠0 = real IOC, not discrete), b<4:1>=board rev (0x3), **b0=0 = Sapphire/Guinness** (1 would = Full House). ✅ MAME `get_system_id()=0x26`. |
| Read Reg | `0x9860` | power/PTC-good bits high, e.g. **`0xF0`** | b7 ENET-link, b6 ENET-pwr, b5 SCSI1-pwr (FH only), b4 SCSI0-pwr. High = power good; return upper bits set so PROM sees healthy rails. |
| Front Panel | `0x9850` | reset value **`0xE1`** | b0 Power-State (1=on), b1 power-button-int (W1C), b4/b6 vol-down/up int (W1C), b5/b7 vol-down/up hold. PROM clears the power-button int by writing 1 to b1. Accept `0x03` to mean "power on." ✅ MAME init = VOL_UP_HOLD\|VOL_DOWN_HOLD\|POWER_STATE = 0xE1. |
| GC Select | `0x9848` | RW storage (=0xFF ok) | configures GEN_CNTL<7:0> dir; b=1 output. Accept writes. |
| General Control | `0x984C` | RW storage | GEN_CNTL<7:0> data lines, last-minute control. Accept. |
| DMA Select | `0x9868` | **0** (default) | b<5:4> serial clk sel (00=10 MHz), b2 parallel-DMA, b<1:0> ISDN-DMA. Accept; 0 is fine. |
| Reset | `0x9870` | RW, self-clearing | b0 parallel rst, b1 kbd/mouse rst, b<5:4> LED, b3 ISDN rst. Accept and read back 0. |
| Write | `0x9878` | RW storage | margin (b7/b6), UART PC-mode (b5/b4), ENET select bits. Accept; defaults (0) are fine for console. |

Henry rule of thumb: every "Not Used" slot and every unmodeled control reg → **accept writes (swallow), return 0
on read** (except the four constants above). That keeps PROM/IRIX init walking forward.

## Minimum for a Henry IRIX boot
Implement, in order:
1. **Polled serial TX (~10 lines, do this first):** decode `0x1FBD9830`/`0x34`; read 0x30 → `0x04`; write 0x34 →
   emit byte; swallow 0x30 writes. This alone produces the entire boot console.
2. **Boot-ID constants:** System ID `0x9858`→`0x26`; Read `0x9860`→`0xF0`; Front Panel `0x9850`→`0xE1` (W1C on
   b1/b4/b6).
3. **Accept-and-ignore the rest:** GC/General/DMA-Sel/Reset/Write regs and all INT3 regs as plain R/W storage;
   reads of unmodeled/Not-Used → 0.
4. (Later, post-first-output) 8254 Timer0 → IP4 tick; INT3 serial mappable int (b5) for interrupt-driven console.

Everything past step 1 is "don't stall init"; step 1 is the actual deliverable.

## Golden vectors (from MAME)
- **SCC TX stream** captured via `scc_dc_w` hook (`SCCW off=1 data=XX c`): `off=1` (= addr 0x34, Port1 data) bytes
  are the console chars. Full IRIX serial boot reconstructed at `~/code/mame/irix_serial_console.txt` (~972 bytes
  through the SCC-write hook; the `du_putchar` entry-breakpoint undercounts because TX is buffered).
- **RR0 read** (addr 0x30) golden value = `0x04` (Tx Buffer Empty) — the value that keeps the poll loop moving.
- **System ID** (0x9858) golden for Guinness/Indy = **`0x26`** (`ioc2_guinness_device::get_system_id()`).
- **Front Panel** (0x9850) power-on reset golden = **`0xE1`**; "power on" written value the PROM accepts = `0x03`.
- **Address decode** golden: MAME `map(0x0c,0x0f)` = SCC (word 0x0c–0x0f = byte 0x30–0x3C); `map(0x14)` Front
  Panel, `map(0x16)` System ID (word indices; ×4 → 0x50, 0x58 absolute).

## Open / not-yet-needed
- ⚠️ **Kbd/mouse (8042)** `0x9840/0x9844` — headless Henry has no console keyboard; stub (return 0).
- ⚠️ **Parallel port (PI1)** `0x9800–0x982C` — no printer; stub.
- ⚠️ **Port2 serial (chan B)** `0x9838/0x983C` — second UART, not the console; stub `0x04`/0.
- ⚠️ **Interrupt-driven serial / Rx** — IRIX boot console is polled-TX; Rx and the INT3 serial mappable int
  (Map Status b5) only needed for an interactive console (input echo, getty).
- ⚠️ **8254 real timing** — needed for scheduler tick eventually, not for first boot output.
- ⚠️ **Power/volume state machine, ISDN glue, EISA** — pure storage stubs; never exercised headless.

## Sources
- `~/code/sgi/docs/indy_docs/ip22/ioc.pdf` — VTI IOC2 spec (Vic Alessi, 1993): §2.1 85CX30 DUART, §2.5 INT3,
  §4.0 register map (p.13), §4.5 INT3 reg bits (p.14–16), §4.6 misc/ID/power regs (p.16–18).
- `~/code/r9999/IP22_CHIP_REGISTERS.md` — IOC2 section (absolute base 0x1FBD9800 correction; SCC console recipe).
- `~/code/r9999/IRIX_KERNEL_GAPS.md` — console section (measured: IRIX boot console = Z8530 direct, arcs_write=0).
- `~/code/mame/src/mame/sgi/ioc2.cpp` / `ioc2.h` — golden reference (`scc_dc_w` TX hook, `get_system_id()=0x26`,
  Front Panel reset = 0xE1, `map(0x0c,0x0f)` SCC decode).
- `~/code/mame/irix_serial_console.txt` — captured golden console stream.
