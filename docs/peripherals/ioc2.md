---
title: IOC2 — I/O Controller (serial console)
status: draft (MAME-validated; henry RTL status audited 2026-10-04 against main @209e6f6)
source: SGI IP22 IOC spec (ioc.pdf); MAME golden reference; henry rtl/ioc.sv, rtl/int3.sv, rtl/henry_soc.sv
---

# IOC2 — I/O Controller (Henry block spec)

> Intro: IOC2 @ phys base 0x1FBD9800 — serial (Z8530 SCC), INT3 interrupt controller, 8254 timer, kbd/mouse,
> parallel, boot-ID/power regs. THE serial console lives here and is the #1 Henry bring-up target. Legend ✅ = MAME-validated / must-have; ⚠️ = stub or not-yet-needed.
>
> The IOC2 is a single VTI ASIC ("Guinness" variant for Indy) holding six macrocells: VTI 85CX30 serial DUART,
> SGI PI1 parallel, Intel 8042 kbd/mouse, Intel 8254 timer, SGI INT3 interrupt mux, and miscellaneous glue
> (power/ID/reset). It hangs off the HPC3 P-bus (PBUS_CS_N<6>); registers are 64 word-spaced (×4) slots at base
> 0x1FBD9800. All addresses below are absolute physical (k1seg uncached: OR 0xA0000000).
>
> **henry status:** `henry_soc.sv` carves the 256-byte window `0x1FBD9800–0x1FBD98FF` out of HPC3
> (`henry_soc.sv:256`). It serves the window with two modules whose read data is ORed together:
>
> - **`ioc.sv`**: the SCC, the 8254 counters 0 and 2, and SYSID.
> - **`int3.sv`**: the INT3 registers.
>
> Everything else in the window reads 0 and swallows writes. That includes the front panel, the read/write
> registers, GC select, DMA select, reset, kbd/mouse and parallel. Much of the "Henry must return…" text
> below is the MAME/PROM view; henry boots through its own ARCS firmware, not the SGI PROM. The
> [henry implementation summary](#henry-implementation-summary) at the end says exactly what is built.

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
The 85CX30 is a Zilog Z85230-class **dual-channel** ESCC. **The console is the first port, at `0x1FBD9830`.**
The macrocell uses Zilog **indirect addressing**: the IOC2 decodes two address lines into 4 byte addresses,
where **addr bit1 = channel** and **addr bit0 = data/command** (0 = command/register, 1 = data). ✅ Confirmed
against MAME `map(0x0c,0x0f) -> z80scc ab_dc_r/w`.

⚠️ **Channel naming (corrected).** In MAME's `z80scc_device::ab_dc_r/w`, `ab = BIT(offset,1)` and
`channel = ab ? chanA : chanB`. The **first** port (`0x…30/0x…34`) is therefore Zilog **channel B**, and the
second (`0x…38/0x…3C`) is channel A. `ioc.sv` agrees: it indexes the console as ch0 and labels it chanB (RR3
`CHBRxIP`). Linux enumerates the console as ttyS0. An earlier version of this page called the console
"channel A"; that was wrong. [SCC implementation](scc.md) uses the same naming.

| Addr (phys) | IOC word | Z8530 access | henry `ioc.sv` behavior |
|-------------|----------|--------------|-------------------------|
| `0x1FBD9830` | 0x0c | console (chan B) **command/RR** | read → RR[ptr] (RR0 = `0x44`, see below; RR1; RR3). write → WR0 pointer/command or WR[ptr]. ✅ |
| `0x1FBD9834` | 0x0d | console (chan B) **data** | **write[7:0] → SoC console FIFO** (→ host). read → pops the SCC Rx FIFO. ✅ THIS is `du_putchar`'s store. |
| `0x1FBD9838` | 0x0e | 2nd port (chan A) command/RR | same pointer machine, own WR1/Tx state. |
| `0x1FBD983C` | 0x0f | 2nd port (chan A) data | a write is *also* sent to the console FIFO; a read returns 0. ⚠️ |

The kernel's byte accesses land on byte lane +3 of each word (`0x…33/0x…37/0x…3B/0x…3F`). `ioc.sv` classifies
any masked byte in the 16-byte line: the channel is byte index bit 3, and data vs control is bit 2.

> **Beyond polled output:** this table is the *minimum to print*. For the register pointer machine,
> the TX datapath (shared console FIFO + the 512-cycle shift timer), and the **Tx-buffer-empty
> interrupt** path through INT3 → IP2 that an interrupt-driven driver (Linux `ip22zilog`) needs, see
> [SCC implementation & Tx interrupt](scc.md).

Minimal TX recipe (what the first bring-up shipped; henry has since grown past it):
1. **Write `0x1FBD9834`** → take `data[7:0]`, append to the console output sink. That's the printed character.
2. **Read `0x1FBD9830`** → return RR0 with **bit2 (Tx Buffer Empty) = 1**, so the driver's "wait for Tx empty"
   poll (`while(!(RR0&4));`) never stalls.
3. **Write `0x1FBD9830`** → may be swallowed for polled output. The WR loads (baud, mode, IE) only matter for
   interrupt-driven drivers.

**What henry's `ioc.sv` returns today:**

- **RR0.** Returns `0x44` (Tx-Buffer-Empty | All-Sent, `ioc.sv:31`) with two live bits:
  - **bit2 clears** while that channel is "shifting" (512 cycles after a data write) or while the SoC console
    FIFO is full. That FIFO is 8 deep (`henry_soc.sv`), and this is how backpressure rate-limits a polling
    driver.
  - **bit0 (Rx Char Available)** is set while the Rx FIFO is non-empty.
- **RR1.** Returns `0x01` (All Sent) when idle, with no parity, overrun or framing errors.
- **RR3.** Returns the gated Tx/Rx interrupt-pending bits.
- **WR0/WR1.** The pointer machine and WR1 (Tx and Rx interrupt enables) are modelled.
- **Not modelled.** Baud and mode registers are swallowed.

Full detail, including the Tx interrupt: [scc.md](scc.md).

Note: IRIX talks to this register **directly**, not through ARCS — so emulating these addresses is mandatory,
not optional.

## INT3 interrupt controller
Base `0x1FBD9880` (registers `0x1FBD9880`–`0x1FBD98AC`, ioc.pdf §2.5 + §4.5). INT3 multiplexes system interrupts
onto **5 CPU interrupt outputs** CPU_INT_N<4:0>, wired to CP0 Cause IP2..IP6. INT3 does **no internal latching**
except the two 8254 timer interrupts; it expects already-latched, level-triggered, **active-high** status (a `1`
= active interrupt regardless of mask/polarity). Each register is an 8-bit register on the **low byte lane**
(`D[7:0]`): the §4.5 addresses below are the 4-byte-aligned *slots*, but the kernel `readb`/`writeb` actually hits
the byte at **slot+3** (the struct is `u8 _pad[3]; volatile u8 reg;` per register — e.g. `istat0`'s byte is at
`0x9883`), the **same byte lane as the external 8254**, so `int3.sv` decodes `mask[3/7/11/15]`. Masks reset to 0
(all masked).

### Interrupt funnel (signal flow)
The whole block is a funnel: device/source lines → (optional mappable cascade) → per-level AND-mask + OR-reduce →
one of five CPU IP pins → CP0. **Green** = live in henry today: the SCC Rx|Tx → MAP_INT0 → IP2 path, plus the
Local0 SCSI0/ENET lines. **Blue** = implemented + tested (Timer0 → IP4), though dormant in a real boot.
**Grey** = tied 0 / not modelled in henry.

Structured like the RISC-V PLIC spec's Figure 3 (sources → gateways → core → target):

```mermaid
flowchart LR
    %% ---------- sources ----------
    subgraph SRC["sources"]
      SER["b5 Serial DUART<br/>(SCC Rx-avail OR Tx-int)"]
      OMAP["b7:6, b4, b3:0<br/>other mappables"]
      DV0["Local0 device lines<br/>SCSI0 b1 + ENET b3 live<br/>(PP/GFX/FIFO/SCSI1/MCDMA = 0)"]
      DV1["Local1 device lines<br/>video/panel/AC-fail"]
      T0["8254 counter0"]
      T1["8254 counter1"]
      BER["bus err HPC/MC/EISA"]
    end

    %% ---------- gateways: the mappable cascade ----------
    subgraph GW["INT3 mappable cascade (gateways)"]
      ANDM0{{"AND cmeimask0"}}
      ORM0{{"OR"}}
      MI0["MAP_INT0"]
      ANDM1{{"AND cmeimask1"}}
      ORM1{{"OR"}}
      MI1["MAP_INT1"]
      ANDM0 --> ORM0 --> MI0
      ANDM1 --> ORM1 --> MI1
    end

    %% ---------- core: the 5 priority levels ----------
    subgraph CORE["INT3 core (5 levels)"]
      AND0{{"AND imask0"}}
      ORL0{{"OR"}}
      IP2(["IP2"])
      AND1{{"AND imask1"}}
      ORL1{{"OR"}}
      IP3(["IP3"])
      LAT0["latch · clr tclear0"]
      IP4(["IP4"])
      LAT1["latch · clr tclear1"]
      IP5(["IP5"])
      IP6(["IP6 (unmaskable)"])
      AND0 --> ORL0 --> IP2
      AND1 --> ORL1 --> IP3
      LAT0 --> IP4
      LAT1 --> IP5
    end

    %% ---------- target: the CPU ----------
    subgraph CPU["R4000 CP0 (target)"]
      IPR["Cause.IP 6:2"]
      ANDIM{{"AND Status.IM<br/>and IE, ~EXL, ~ERL"}}
      TAKE["take interrupt"]
      IPR --> ANDIM --> TAKE
    end

    %% ---------- cross-stage wiring ----------
    SER --> ANDM0
    SER --> ANDM1
    OMAP -.-> ANDM0
    OMAP -.-> ANDM1
    MI0 -->|"istat0 b7"| AND0
    DV0 --> AND0
    MI1 -->|"istat1 b3"| AND1
    DV1 -.-> AND1
    T0 --> LAT0
    T1 -.-> LAT1
    BER -.-> IP6
    IP2 --> IPR
    IP3 --> IPR
    IP4 --> IPR
    IP5 --> IPR
    IP6 --> IPR

    classDef live fill:#d4f4d4,stroke:#28a428,stroke-width:2px;
    classDef impl fill:#d4e4ff,stroke:#3060c0;
    classDef stub fill:#f2f2f2,stroke:#bbb,color:#888;
    class SER,ANDM0,ORM0,MI0,DV0,AND0,ORL0,IP2 live
    class T0,LAT0,IP4 impl
    class OMAP,DV1,ANDM1,ORM1,MI1,AND1,ORL1,IP3,T1,LAT1,IP5,BER,IP6 stub
```

The PLIC analogy is exact: the **mappable cascade = the PLIC gateways** (a source passes through a routing mask),
the **per-level `AND imaskN` + OR = the PLIC core's per-source enable+gather**, and **`Status.IM` at the CPU = the
PLIC priority threshold** (the final gate before the target sees it).

Reading the green path: SCC RX asserts `map_src[5]` → (`AND cmeimask0`, OR) → **MAP_INT0** → lands in `istat0[7]` →
(`AND imask0`, OR) → **IP2** → `Cause.IP[2]` → taken once `Status.IM[2]` is set. Note the **two** INT3 masks in
series (`cmeimask0` then `imask0`) plus the CPU's `Status.IM[2]`. In henry, `map_src[5]` =
`scc_rx_avail | scc_tx_int`, both from `ioc.sv` (`henry_soc.sv:1021`).

✅ **Mappable cascade (map_src[5] = SCC serial) → IP2 validated against live IRIX (2026-06-20, interp_mips ISS).**
The first confirmed user of this path is the **SCC *Tx*-buffer-empty interrupt** (not RX): interrupt-driven
`/dev/console` output (the tty driver draining its write FIFO) needs the SCC INT line, whereas the early
kernel/PROM console is polled. The chain works exactly as drawn: SCC asserts its INT (Z8530: a data write
empties the Tx buffer, and with `WR1.TxINT_ENAB` + `WR9.MIE` set it latches Tx-IP; the ISR reads `RR3`
chip-wide int-pending and acks with `RES_Tx_P`) → `map_src[5]` → `cmeimask0` → `istat0[7]` (LIO2) → `imask0` →
IP2. Register byte lanes in the IOC2 window (`base+off*4+3`): map status (vmeistat) `0x59893`, map mask0
(cmeimask0) `0x59897`, map mask1 `0x5989b`, map polarity `0x5989f`. The same cascade with `cmeimask1` →
`istat1[3]` (LIO3) → IP3 is the local1 path.

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

✅ **SCSI0 → IP2 validated against live IRIX (2026-06-20, interp_mips ISS).** The `istat0` **b1 = SCSI0**
path is real and load-bearing for disk boot: the WD33C93 raises **INTRQ** on Select-and-Transfer completion;
that level drives `istat0[1]` → (`AND imask0`, OR) → **IP2** → `Cause.IP[2]`. With this wired, IRIX (which sits
in its idle loop after issuing the probe command) takes IP2, services the SCSI completion, and walks the bus.
INTRQ is **level-sensitive** and clears when the kernel reads the WD33C93 SCSI Status (reg 0x17) — so `istat0[1]`
must track the live INTRQ line, not latch. (Same byte at `0x9883`; mask `imask0[1]` at `0x9887`, which the
kernel writes during SCSI init.) This is the **second confirmed IP2 source** after the SCC-RX mappable path.
In henry the line is `scsi_shim.sv`'s `r_intrq`. It is a level signal, and reading reg 0x17 clears it.

### Where the mappable inputs come from (and what is NOT in the IOC2 spec)
This is the part that confuses people: **which physical signal drives each mappable input is fixed wiring, and for
the 6 "general" mappables it is NOT specified by the IOC2 spec at all.** The IOC2 I/O list defines them only as
package pins:

> `MAP_INT_N<7:6,3:0>` — Input — *"Mappable interrupts for general use. Polarity selectable, default is active low."*
> `CPU_INT_N<4:0>` — Output — the 5 CPU interrupt outputs (= IP2..IP6).

So the 8 mappable inputs split into two kinds:

| Mappable bit | Source | In the IOC2 spec? |
|---|---|---|
| **b5** Serial DUART | **internal** IOC2 macrocell (the on-chip Z8530 SCC) | yes — reserved by §4.5 |
| **b4** Keyboard/Mouse | **internal** IOC2 macrocell (the on-chip 8042) | yes — reserved by §4.5 |
| **b7, b6, b3, b2, b1, b0** | **external** pins `MAP_INT_N<7:6,3:0>` — "general use" | **NO source assigned** |

The general-use bits are just polarity-selectable input *pins*. What (if anything) a real Indy soldered to them —
a GIO-slot interrupt, an expansion device — is a **board/system-level decision documented in the IP22 system spec
/ schematics and the GIO bus spec, not in this IOC2 document.** There is no prose anywhere in `ioc.pdf` that says
e.g. "GIO slot X → MAP_INT_N<0>"; the chip only promises "here are 6 general interrupt input pins."

**Consequences for Henry** (the `int3.sv` `map_src[7:0]` port):
- `map_src[5]` (serial) — *internal* on real silicon ⇒ in Henry it is driven **from `ioc.sv`** (SCC Rx-avail OR
  the gated Tx interrupt), which faithfully mirrors the chip. Live.
- `map_src[4]` (kbd/mouse) — internal 8042 ⇒ not modeled, tied 0.
- `map_src[7:6, 3:0]` — external GIO/expansion pins ⇒ Henry has **no GIO**, and the spec assigns them no source,
  so they are correctly tied 0. There is nothing to "look up" for these — they are unassigned by design.

In short: `int3.sv` only ever *consumes* `map_src`; the source wiring lives in `henry_soc.sv`, and for the general
mappables there is no canonical source to wire because the IOC2 spec leaves them to the system designer.

### Henry relevance — what actually fires
Of the 27 sources, these are driven in henry (`henry_soc.sv:1020-1023`):
- **Serial DUART** (Map Status b5) → MAP_INT0 → **IP2**. **Live.** It is driven by the SCC Rx-FIFO non-empty
  OR the gated SCC Tx interrupt. This is the interactive console on IRIX and Linux.
- **SCSI0** (`istat0[1]`) → **IP2**. **Live.** It is driven by the WD33C93 INTRQ from `scsi_shim.sv`, ORed
  with `hpc3.sv`'s HPC3 XIE latch.
- **ENET** (`istat0[3]`) → **IP2**. **Live.** It is driven by the ENET RX/TX channel IRQ from `enet_shim.sv`.
- **Timer0** (IP4). **Implemented + tested.** `ioc.sv` 8254 counter0 is a periodic down-counter whose terminal
  count drives `timer0_irq` → INT3 latch → IP4 (see below). Note IP22 Linux/IRIX don't actually use it (they
  drive the system tick from CP0 Count/Compare on **IP7**, the 8254 IRQ being buggy on IP22), but it's the
  cleanest testable real INT3 source. **Timer1** (IP5) is tied 0 (counter1 not modelled).
- **Tied 0:** everything else. That is the bus errors (IP6), all of Local1 (so IP3 never fires), SCSI1,
  graphics, parallel, MC-DMA, FIFO-full, kbd/mouse, and the general mappables.

### Implementation — `rtl/int3.sv`
INT3 is a standalone module **`rtl/int3.sv`**, instantiated in `henry_soc.sv` sharing the IOC2 access window (its
registers sit at lines `0x80`/`0x90`/`0xa0`; `ioc.sv` reads 0 there, so `w_rd_ioc = w_rd_iocdev | w_rd_int3`).
Its 5 outputs drive `core_l1d_l1i`'s `ip2..ip6` pins (this replaced the old 1-bit `extern_irq`). Aggregation:
`ip2 = |(istat0 & imask0)`, `ip3 = |(istat1 & imask1)`, `ip6 = |buserr` (unmaskable), `ip4/ip5` = the two latched
timer IRQs; `map_int0 = |(vmeistat & cmeimask0)` feeds `istat0[7]`. The §4.5 RW registers (`imask0`, `imask1`,
`cmeimask0`, `cmeimask1`, `cmepol`) and the timer latches (tclear-cleared) are modeled.

- **Polarity.** `cmepol` is stored but **not applied**: the map status is the raw active-high source.
- **Byte lanes.** Each register is decoded on its byte lane: line `0x80` bytes 3/7/11/15 =
  istat0/imask0/istat1/imask1; line `0x90` = vmeistat/cmeimask0/cmeimask1/cmepol; line `0xa0` byte 3 = tclear
  (write) and byte 7 = errstat.
- **Live sources.** See the list above: IP2 (SCC, SCSI0, ENET) and IP4 (Timer0) can fire.

Source-port mapping:
- `local0_src[6:0]` = istat0 b6..b0 (Graphics/Parallel/MC-DMA/ENET/SCSI1/SCSI0/FIFO); b7 (MAP_INT0) computed.
- `local1_src[7:0]` = istat1 (b3 = MAP_INT1 computed, that input bit ignored).
- `map_src[7:0]` = the 8 mappable inputs (**`[5]` = SCC Rx-avail | Tx-int, live**; the rest tied 0).
- `local0_src` as wired: `{3'd0, enet, 1'b0, scsi0, 1'b0}` (ENET b3, SCSI0 b1).
- `buserr[2:0]` = {HPC, MC, EISA}, tied 0. `timer0_irq` ← `ioc.sv` counter0 (live). `timer1_irq` tied 0.

**Test:** `tests/pit/` (a bare-metal MIPS program run on `henry_tb`) programs counter0 periodic, enables `IM[4]`,
takes 5 IP4 interrupts 20 PIT ticks apart, acking each via `tclear` → checksum `0x10` (IP4). With synthesis
`PIT_DIV`=100, 20 ticks is ~2000 core cycles (the programmed 20 µs at 1 MHz). The `henry_tb` Verilator build
uses `PIT_DIV`=2 (since 12bf79a), so the same 20 ticks is ~40 cycles there. Validates the full 8254 → INT3 latch/clear → IP4 → CPU path.

**SCC Rx (done).** Host bytes reach the 8-deep SCC Rx FIFO in `ioc.sv`:

- **On the FPGA** the ARM writes AXI register `0x3B`, with bit8 = push and the byte in [7:0]. It checks
  `scc_rx_full` at read `0x3A` bit8 before pushing.
- **In simulation** `henry_tb` pushes the bytes.

The FIFO drives RR0 bit0 and `map_src[5]` → MAP_INT0 → IP2. A read of the console DATA byte pops it. The
FIFO is shared by both channels' Rx-available status.

## 8254 timer (Intel 82C54 PIT)
Standard Intel **82C54** CHMOS Programmable Interval Timer — three independent 16-bit down-counters. On IP22 it's
clocked at **exactly 1 MHz** (1 µs/tick — `SGINT_TIMER_CLOCK`, *not* the PC's 1.193 MHz). Counter0 terminal count
→ INT3 Timer0 → **IP4**, Counter1 → Timer1 → **IP5**, Counter2 = calibration only (`dosample` measures CP0 Count
against a known Counter2 down-count). *(Source: Intel 82C54 datasheet, Intel order #23124406.)*

### Registers & byte addressing
The four ports are 4-byte-aligned slots in the IOC2 window, but the 82C54 is an 8-bit part wired to the **low byte
lane**, so each is accessed as a **byte at slot+3** (this is why `ioc.sv` matches on `mask[3/7/11/15]`):

| Port | Slot | Byte addr (kseg1) | henry mask bit |
|------|------|-------------------|----------------|
| Counter 0 | `0x98B0` | `0xBFBD98B3` | `mask[3]` |
| Counter 1 | `0x98B4` | `0xBFBD98B7` | `mask[7]` |
| Counter 2 | `0x98B8` | `0xBFBD98BB` | `mask[11]` |
| Control Word | `0x98BC` | `0xBFBD98BF` | `mask[15]` |

(The IOC2's *internal* registers — SYSID, INT3 — sit on byte lane 0; the 8254, an external 8-bit chip, is on lane 3.)

### Control Word format (write to the Control Word port)
| Bits | Field | Values |
|------|-------|--------|
| D7:D6 | **SC** — Select Counter | `00`=C0, `01`=C1, `10`=C2, `11`=Read-Back command |
| D5:D4 | **RW** — Read/Write | `00`=Counter-Latch command, `01`=LSB only, `10`=MSB only, **`11`=LSB then MSB** |
| D3:D1 | **M** — Mode | `000`=0, `001`=1, `x10`=**2**, `x11`=**3**, `100`=4, `101`=5 |
| D0 | **BCD** | `0`=binary 16-bit, `1`=BCD (4 decades) |

So "program Counter0, periodic, 16-bit, lo+hi" is `0x34` (Mode 2) or `0x36` (Mode 3).

### Modes (Intel datasheet)
| Mode | Name | Behavior |
|------|------|----------|
| 0 | Interrupt on Terminal Count | one-shot: OUT low until count expires, then high |
| 1 | Hardware Retriggerable One-Shot | GATE-triggered one-shot |
| **2** | **Rate Generator** | divide-by-N, **periodic**; *"typically used to generate a Real Time Clock interrupt"* — OUT pulses low for 1 CLK when the count reaches 1, reloads, repeats every N CLKs |
| **3** | **Square Wave** | like Mode 2 but 50% duty (OUT high first half, low second); period N; "typically used for Baud rate generation" |
| 4 | Software Triggered Strobe | one-shot strobe on terminal count |
| 5 | Hardware Triggered Strobe | GATE-triggered strobe |

**Programming protocol:** write the Control Word, then the initial count to the counter port (for `RW=11`, **LSB
first, then MSB** — the counter loads and starts on the MSB write). To *read* a live count, first issue a **Counter
Latch Command** (Control Word with `RW=00` + the target's SC bits), which snapshots the count so it can be read
LSB-then-MSB without disturbing counting (this is what `dosample` does on Counter2).

### What henry models
`ioc.sv` implements:
- **Counter0** as a periodic down-counter at the 1 MHz PIT rate: the 2-byte (LSB→MSB) load starts it; at terminal
  count (→1) it emits a 1-cycle `timer0_irq` pulse and reloads — i.e. **Mode 2 / Mode 3 edge behavior** (we model
  the interrupt edge, not the OUT duty cycle). Drives INT3 Timer0 → IP4. **Tested**: `tests/pit`.
- **Counter2** as the calibration down-counter (Counter-Latch + LSB/MSB read) for `dosample`.
- **PIT rate.** The PIT rate is the core clock ÷ `PIT_DIV`: **100** in synthesis (1 MHz at 100 MHz), but
  **2** under Verilator (`ioc.sv:55-63`). The small sim divider shrinks IRIX's `us_delay` busy-waits, so
  simulated time-of-day/calibration is deliberately not 1 MHz.
- ⚠️ **Control-word quirk.** The control-word decode is simplified. Any control word whose RW≠00 arms the
  2-byte *counter2* load sequence, whatever its SC field says. Any RW=00 word latches counter2. A
  counter0-select (SC=00) word also stops counter0 and arms its 2-byte reload.

Not modeled (not needed): Modes 0/1/4/5, BCD counting, the GATE inputs, the Read-Back **status** command, the OUT
duty cycle, Counter1 (a trivial mirror of Counter0), and "count of 1 is illegal in Mode 2." The kernel programs
Counter0 in a periodic mode and only needs the terminal-count interrupt edge, which is what we emit.

⚠️ IP22 Linux/IRIX drive the real system tick from **CP0 Count/Compare (IP7)**, not this 8254 IRQ — so Counter0→IP4
is chip-faithful but dormant during a real boot (see the INT3 section).

## Boot-identification & power regs
PROM/IRIX probe these during early init; Henry must return plausible values or init stalls/branches wrong. Most
are simple constant-return or accept-and-store.

In henry only **System ID** is modelled. It reads `0x26` (stored `0x26000000`, the BE load sees `0x26`; this
needs a full-word read; `ioc.sv:30`). Every other register in this table **reads 0 and swallows writes**. IRIX and
Linux boot with that, because henry's ARCS firmware replaces the PROM that would otherwise care.

| Reg | Addr | MAME/PROM value | Notes |
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
Original bring-up order (all done; henry now boots IRIX and Linux to an interactive console):
1. **Polled serial TX:** decode `0x1FBD9830`/`0x34`; RR0 bit2 = 1; write 0x34 → emit byte. This alone produces
   the boot console.
2. **Boot-ID constants:** only System ID `0x9858`→`0x26` turned out to be needed. Read Reg, Front Panel etc.
   read 0 in henry.
3. **Accept-and-ignore the rest:** unmodelled IOC2 registers read 0. INT3 is fully modelled (`int3.sv`), not
   plain storage.
4. **Interrupts:** INT3 serial mappable (b5, Rx + Tx) → IP2, SCSI0/ENET → IP2, and Timer0 → IP4.

## Golden vectors (from MAME)
- **SCC TX stream** captured via `scc_dc_w` hook (`SCCW off=1 data=XX c`): `off=1` (= addr 0x34, Port1 data) bytes
  are the console chars. Full IRIX serial boot reconstructed at `~/code/mame/irix_serial_console.txt` (~972 bytes
  through the SCC-write hook; the `du_putchar` entry-breakpoint undercounts because TX is buffered).
- **RR0 read** (addr 0x30) golden value = `0x04` (Tx Buffer Empty) — the value that keeps the poll loop moving.
  henry returns `0x44` (Tx-Buffer-Empty | All-Sent) with live bit2/bit0. Only bit2 matters to the poll.
- **System ID** (0x9858) golden for Guinness/Indy = **`0x26`** (`ioc2_guinness_device::get_system_id()`).
- **Front Panel** (0x9850) power-on reset golden = **`0xE1`**; "power on" written value the PROM accepts = `0x03`.
- **Address decode** golden: MAME `map(0x0c,0x0f)` = SCC (word 0x0c–0x0f = byte 0x30–0x3C); `map(0x14)` Front
  Panel, `map(0x16)` System ID (word indices; ×4 → 0x50, 0x58 absolute).

## Open / not-yet-needed
- ⚠️ **Kbd/mouse (8042)** `0x9840/0x9844` — headless Henry has no console keyboard; stub (return 0).
- ⚠️ **Parallel port (PI1)** `0x9800–0x982C` — no printer; stub.
- ⚠️ **Second serial port (chan A)** `0x9838/0x983C`. It has its own pointer machine, WR1 and Tx-shift state,
  but no separate Rx or TX sink: its data writes also go to the console FIFO, and its data reads return 0.
- **Interrupt-driven serial / Rx**: done (see above).
- **8254 counter1**: not modelled. The system tick is CP0 Count/Compare (IP7).
- ⚠️ **Power/volume state machine, ISDN glue, EISA** — pure storage stubs; never exercised headless.

## Sources
- `~/code/sgi/docs/indy_docs/ip22/ioc.pdf` — VTI IOC2 spec (Vic Alessi, 1993): §2.1 85CX30 DUART, §2.5 INT3,
  §4.0 register map (p.13), §4.5 INT3 reg bits (p.14–16), §4.6 misc/ID/power regs (p.16–18).
- Intel **82C54** CHMOS Programmable Interval Timer datasheet (Intel order #23124406) — control-word format, the
  six counter modes (Mode 2 Rate Generator, Mode 3 Square Wave), and the LSB/MSB write + Counter-Latch read protocol.
- `~/code/r9999/IP22_CHIP_REGISTERS.md` — IOC2 section (absolute base 0x1FBD9800 correction; SCC console recipe).
- `~/code/r9999/IRIX_KERNEL_GAPS.md` — console section (measured: IRIX boot console = Z8530 direct, arcs_write=0).
- `~/code/mame/src/mame/sgi/ioc2.cpp` / `ioc2.h` — golden reference (`scc_dc_w` TX hook, `get_system_id()=0x26`,
  Front Panel reset = 0xE1, `map(0x0c,0x0f)` SCC decode).
- `~/code/mame/irix_serial_console.txt` — captured golden console stream.

## henry implementation summary

| Block | henry RTL | Status |
|-------|-----------|--------|
| SCC console port (`0x30/0x34`) | `ioc.sv` | pointer machine, RR0/RR1/RR3, WR1 Tx/Rx int enables, TX → SoC console FIFO, 8-deep Rx FIFO |
| SCC second port (`0x38/0x3C`) | `ioc.sv` | control/Tx-int state only; data writes also go to the console FIFO |
| INT3 (`0x80–0xa7`) | `int3.sv` | all §4.5 registers; `cmepol` stored but ignored |
| 8254 counter0 → IP4 | `ioc.sv` | periodic; tested by `tests/pit` |
| 8254 counter2 | `ioc.sv` | calibration latch/read |
| 8254 counter1 | — | not modelled |
| SYSID (`0x58`) | `ioc.sv` | `0x26` |
| Front panel, Read/Write, GC, DMA-sel, Reset, kbd/mouse, parallel | — | read 0, writes ignored |

