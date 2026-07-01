<!--
  scsi_disk_theory_of_operation.md
  Theory of operation for the IP22 SCSI disk path (WD33C93A + HPC3 SCSI DMA +
  disk backend), traced EXACTLY from the validated interp_mips model:
      interp_mips/sgi_scsi.cc / sgi_scsi.hh   (fused WD33C93A + single disk target)
      interp_mips/sgi_hpc.cc  / sgi_hpc.hh    (HPC3 SCSI DMA channel + IOC2/INT2)
  That model boots IRIX 6.5 to a mounted root device (validated against a live
  IRIX/MAME boot trace).  This is the spec the henry RTL port follows, ending with
  the ARM-host-serviced hybrid the FPGA will actually use.
-->

# IP22 SCSI Disk Path — Theory of Operation (WD33C93A + HPC3 SCSI DMA + disk)

## 0. The three actors

```
   IRIX/Linux sgiwd93 driver (guest CPU, PIO + descriptor build)
        |  PIO byte ops to WD33C93 (SASR/SCMD)        |  32-bit MMIO to HPC3 DMA regs
        v                                             v
   +----------------------+   DRQ/byte port   +---------------------------+
   |  WD33C93A controller | <---------------> |  HPC3 SCSI DMA channel    | <--> DRAM
   |  (+ fused 1 disk     |  dma_r()/dma_w()  |  (descriptor-walk master) |
   |   target)            |                   +---------------------------+
   +----------------------+
        |  INTRQ -> IOC2 local0 bit1 (SCSI0) -> CPU IP2
```

- **Guest driver** programs the WD33C93 (Own ID / Control / a CDB / Select-And-Transfer) AND builds an HPC3 DMA descriptor chain in DRAM, arms the DMA channel, then waits for the completion interrupt. A **CDB (Command Descriptor Block)** is the SCSI command itself — a 6/10/12-byte packet of { opcode, LBA, transfer length, control }; e.g. a 10-byte `READ(10)` = opcode `0x28`, a 4-byte big-endian LBA at bytes 2–5, and a 2-byte block count at bytes 7–8.
- **WD33C93A** decodes the SCSI command, runs a *data phase* (PH_DATA_IN/OUT), and raises **INTRQ** at completion. In interp_mips it is *fused* with a single disk target — there is no SCSI bus / arbitration / REQ-ACK; one `Select-And-Transfer` decodes the CDB and runs the whole transaction.
- **HPC3 SCSI DMA channel** is the *memory master*: it walks a `{BP,BC,DP}` descriptor chain and moves each byte between DRAM and the WD33C93 byte port on every DRQ. The WD33C93 is NOT the bus master (`dma_mode = CTRL_BURST`, demand DMA).

All addresses are within the **HPC3 #0 window, base PA `0x1fb80000`**; offsets below are `pa - 0x1fb80000`.

---

## 0.1 The basics — how a disk read / write works in IRIX

Start here. The device detail in §1+ only makes sense once you have the OS-level story. Nothing here is IP22-specific magic — it's the standard "filesystem → buffer cache → SCSI driver → controller + DMA → interrupt" flow, with the IP22 twist that the **controller (WD33C93) and the DMA engine (HPC3) are two separate chips** the driver programs in tandem.

### A disk READ
1. **Filesystem miss.** An xfs/efs read needs a block that isn't in the buffer cache, so the kernel allocates a `buf` (with a **physical** data buffer in DRAM) and calls the disk's strategy routine. This becomes one SCSI command: **`READ(10)` { LBA, block-count }** to a target id / LUN, delivering into that physical buffer.
2. **The IP22 WD33C93 driver** (IRIX `wd95` / Linux `sgiwd93` — they drive the identical hardware identically) does, via PIO to SASR/SCMD:
   - *(once, at init)* Own ID = host id **7** + FS clock (20 MHz); Control = DMA mode **`CTRL_BURST`** (demand DMA — the WD33C93 raises DRQ, the HPC3 masters memory).
   - select the target: write **Dest ID** (reg 0x15) and **Target/LUN** (reg 0x0f).
   - **stream the 10-byte CDB** into reg 0x03+ (SCMD auto-increments SASR, so it's one burst).
   - program the 24-bit **Transfer Count** (regs 0x12–0x14) = bytes to move.
3. **The driver programs the HPC3 DMA channel** (separate 32-bit MMIO regs): build a `{BP=buffer-phys, BC=count|flags(XIE/EOX), DP=next}` **descriptor chain in DRAM**, write **nbdp** (0x10004) = chain head, write **ctrl** (0x11004) = **ACTIVE** (DIR=0 for read).
4. **Kick it:** write the WD33C93 **Command** reg (0x18) = **Select-And-Transfer (0x08)**.
5. **Hardware runs autonomously:** WD33C93 enters the data-in phase and asserts DRQ; the HPC3 DMA walks the descriptor chain and copies the bytes into `BP`; at the end the WD33C93 raises **INTRQ** (→ IOC2 local0 SCSI0 → CPU **IP2**).
6. **Driver ISR:** read **SCSI Status** (reg 0x17 — this *clears* INTRQ), read **target status** (reg 0x0f: 0x00 GOOD / 0x02 CHECK CONDITION), check the **Transfer Count residual** (0 = full transfer). On GOOD + zero residual it marks the `buf` done (`b_done`); the data is already in DRAM at `BP`, so the filesystem just returns it.

### A disk WRITE
Identical, except: the CDB is **`WRITE(10)`**, the DMA `ctrl` has **DIR=1** (mem→device), so the HPC3 DMA pumps the guest's buffer `BP` **out** to the controller, which lands it on the medium. Completion handshake (INTRQ → read status → check 0x0f / residual) is the same.

### Why two chips + DMA (the thing the RTL must preserve)
The driver's correctness checks at step 6 — **reg 0x0f = target status** and **Transfer Count = 0** — are exactly what the hybrid RTL must reproduce (see §5, §10): IRIX reads 0x0f to distinguish GOOD from CHECK, and a non-zero residual reads as a *short transfer* (`b_error` → `ENOEXEC`, root mount fails). Everything else below is how the WD33C93 + HPC3 actually produce that sequence.

---

## 1. Register interfaces

### 1.1 WD33C93A — two byte ports, indirect register file
The chip exposes only **two** byte ports (byte lane +3 of a 4-byte stride):

| Port | HPC3 offset | abs PA | function |
|------|-------------|--------|----------|
| SASR | `+3` | `0x1fbc0003` (IRIX) / `0x1fbc4003` (Linux) | indirect **register-select pointer** |
| SCMD | `+7` | `0x1fbc0007` (IRIX) / `0x1fbc4007` (Linux) | **data port** for the selected register (auto-increments SASR) |

Decode (sgi_hpc.cc): the WD33C93 is decoded across the **whole HD0 device region `0x40000..0x47fff`** (HD1 `0x48000..0x4ffff`); `port = ((offs-0x40000) >> 2) & 1` (0=SASR, 1=SCMD) — the `0x4000` bit is a *don't-care*, so the chip is **aliased across the 32 KB region**. **Byte accesses are NOT byte-swapped** (unlike the 32-bit DMA regs). The two guests pick different points in that region: **IRIX uses `0x40003/0x40007`, Linux uses `0x44003/0x44007`** — the latter is the SGI spec's `hd0.cs` sub-window (hpc3.pdf: `hd0.cs = 0x1fbc4000..0x1fbc43ff`, inside HD0 region `0x1fbc0000..0x1fbc7fff`); both decode identically. **RTL gotcha:** match the *whole region*. Decoding only the exact line `0x40000` (as the first henry shim did) works for IRIX but misses Linux; decoding a `0x44000`-*based* region instead breaks IRIX. (Older notes calling `0x44003` "wrong, a MAME log artifact" conflated the `0x44000`-based-decode bug with the perfectly valid `hd0.cs` address Linux uses.)

Indirect register file `regs[0x00..0x1f]` (the ones that matter):

| idx | name | role |
|-----|------|------|
| 0x00 | Own ID | host SCSI ID (7) + FS clock divisor |
| 0x01 | Control | DMA mode select (`CTRL_BURST`) |
| 0x03 | **CDB[0]** | first CDB byte = SCSI opcode (CDB occupies 0x03..) |
| 0x0f | **Target/LUN** | guest writes target LUN here; **at completion the WD33C93 OVERWRITES it with the target STATUS byte** (GOOD/CHECK) |
| 0x10 | **Command Phase** | progress code; `0x60` = command complete, `0x46` = xfer-count exhausted |
| 0x12..0x14 | **Transfer Count** (24-bit) | counts down as bytes move; **0 at completion** |
| 0x15 | Dest ID | target SCSI id |
| 0x16 | Source ID | |
| 0x17 | **SCSI Status** | completion code; **reading it clears INTRQ** |
| 0x18 | **Command** | writing here EXECUTES a WD33C93 command |
| 0x19 | Data | PIO data port (DMA uses dma_r/dma_w instead) |
| 0x1f | Aux Status | read via the **SASR port** |

**Aux Status bits** (returned by a *read of the SASR port*): `INT=0x80` (INTRQ pending), `LCI=0x40`, `BSY=0x20`, `CIP=0x10` (command in progress), `DBR=0x01` (data buffer ready = DRQ).

**PIO semantics** (sgi_scsi.cc `pio_w`/`pio_r`):
- write SASR → `sasr = v & 0x1f`.
- write SCMD → if `sasr==0x18` (Command): store + **execute** `exec_command(v & 0x7f)`; else `regs[sasr]=v` then `sasr=(sasr+1)&0x1f` (**auto-increment**, so the driver streams the CDB in one burst).
- read SASR → live **Aux Status** (`INT` if intrq, `DBR` if drq).
- read SCMD → `regs[sasr]`, then auto-increment; **reading reg 0x17 (SCSI Status) clears INTRQ** (`intrq=false`, Aux `~INT`).

**WD33C93 commands** (low 7 bits of reg 0x18): `RESET=0x00`, **`SEL_ATN_XFER=0x08`**, **`SEL_XFER=0x09`** (the workhorse — Select-And-Transfer), `XFER_INFO=0x20` (data phase already armed).

### 1.2 HPC3 SCSI DMA channel registers (32-bit, byte-swapped on the bus)
Two channels: HD0 at `0x10000..0x11fff`, HD1 selected by `offs & 0x2000`. **The BE store/load path byte-swaps these 32-bit registers** (`__builtin_bswap32` on read and write).

| offset | reg | access | meaning |
|--------|-----|--------|---------|
| `0x10000` | **cbp** | RO | current buffer pointer (live BP, advances during XFER) |
| `0x10004` | **nbdp** | RW | next-descriptor pointer (chain head / walk cursor) |
| `0x11000` | **bc** | RW | byte-count word: `count[13:0]` + flags |
| `0x11004` | **ctrl** | RW | channel control (arm/flush/dir); **read returns ctrl and clears the per-channel IRQ bit** (sets bit0 if `intstat` had `0x100<<ch`) |
| `0x11010` | dmacfg | RW | DMA config |
| `0x11014` | piocfg | RW | PIO config |

**`ctrl` bits**: `ACTIVE=0x10` (arm), `DIR=0x04` (1 = mem→device = WRITE), `FLUSH=0x08` (abort/stop), `AMASK=0x20` (write-protect ACTIVE), `CRESET=0x40` (reset the WD33C93), `IRQ=0x01` (read-only, set if the channel IRQ fired).

---

## 2. The HPC3 DMA descriptor & chain

A descriptor is **3 big-endian words at `nbdp`** (`rd_be32`, guest BE byte order in DRAM):

```
  desc+0 : BP   buffer pointer  (physical DRAM address of the data buffer)
  desc+4 : BC   byte-count word = flags | count
  desc+8 : DP   next-descriptor pointer (physical)
```

`count = BC & 0x3fff` (14-bit, ≤16 KB per descriptor). Flags in `BC`:
- `EOX = 0x80000000` — End Of Xfer (last descriptor; deactivate after).
- `XIE = 0x20000000` — interrupt-enable for this descriptor's completion.

The chain is **pure-physical, walked via `DP`** until a descriptor with `EOX` set. (Scatter-gather: one SCSI command's data can span several buffers.)

---

## 3. HPC3 DMA descriptor-walk FSM (`scsi_run_dma`)

State per channel: `CH_IDLE / CH_FETCH / CH_XFER / CH_DESC_DONE`. Pumped while `active && progress` (runs to a stall point each time it is poked):

1. **Arm** — a `ctrl` write with `ACTIVE` set and `!was_active`: latch `to_device = ctrl & DIR`, set `state = CH_FETCH`, then run the FSM. (`FLUSH` → deactivate+IDLE; `CRESET` → reset the WD33C93.)
2. **CH_FETCH** — `scsi_fetch_chain`: load `{cbp,bc,nbdp}` from the descriptor at `nbdp`, `count = bc & 0x3fff`. → `CH_XFER`.
3. **CH_XFER** — byte pump:
   ```
   while (count != 0 && scsi->drq_pending()) {
       p = DRAM[cbp];
       if (to_device) scsi->dma_w(*p);   // mem -> device (WRITE)
       else           *p = scsi->dma_r(); // device -> mem (READ)
       cbp++; count--;
   }
   if (count == 0) -> CH_DESC_DONE;
   // else: DRQ dropped mid-descriptor -> return, wait for the next DRQ
   ```
   The pump is gated by **DRQ** (the device's data-available/needed flag), so it naturally stalls when the device side isn't ready.
4. **CH_DESC_DONE** —
   - `XIE` → `intstat |= (0x100 << ch)` (this is the per-channel HPC3 IRQ, surfaced in `ctrl` bit0 / cleared on `ctrl` read).
   - `EOX` → if the device still has an **undrained residual** (`scsi->residual()>0`), call `scsi->pause_transfer()` (chunked transfer, §6); then `active=false`, `ctrl &= ~ACTIVE`, `state=CH_IDLE`.
   - else → `state = CH_FETCH` (advance to the next descriptor).

The FSM is also poked from the WD33C93 path: a **Command-register write that asserts DRQ** calls `scsi_run_dma(0)` if channel 0 is armed (so the data phase drains immediately).

---

## 4. WD33C93 command flow — Select-And-Transfer

Writing reg 0x18 with `0x08`/`0x09` calls `select_and_transfer()`:

1. Set Aux `CIP|BSY`. (Unless this is a **resume**, §6.)
2. `op = regs[0x03]` (CDB[0]); `lun = regs[0x0f] & 7` (captured before completion overwrites 0x0f).
3. `tgt_status = 0x00` (GOOD) unless set to CHECK below.
4. **LUN gate**: only LUN 0 exists. For `lun!=0` and `op!=REQUEST SENSE`, set sense = ILLEGAL REQUEST / ASC 0x25 (LUN NOT SUPPORTED), `tgt_status=0x02` (CHECK), `finish()` with no data. (REQUEST SENSE itself must still succeed so the probe can read the sense.)
5. **CDB decode** (the implemented command set, sufficient for IRIX root mount + probe):

| op | command | action |
|----|---------|--------|
| 0x00 | TEST UNIT READY | `finish()` (no data) |
| 0x1b | START STOP UNIT | `finish()` |
| 0x12 | INQUIRY | data-in 36 B: direct-access disk, SCSI-2, "SGI / interp_mips disk / 1.0"; honor `cdb[4]` alloc len |
| 0x03 | REQUEST SENSE | data-in fixed-format sense (`alloc=cdb[4]`) |
| 0x25 | READ CAPACITY(10) | data-in 8 B: last-LBA (BE) + block size 512 (BE) |
| 0x1a | MODE SENSE(6) | data-in 4 B header (`alloc=cdb[4]`) |
| 0x15 | MODE SELECT(6) | data-out `cdb[4]` bytes (consume + succeed) |
| 0x28 | **READ(10)** | `lba = cdb[2..5]` BE, `len = cdb[7..8]` BE blocks; read `len*512` from disk into `buf`; → PH_DATA_IN |
| 0x2a | **WRITE(10)** | same LBA/len; `wr_lba=lba`; → PH_DATA_OUT (drained to COW on finish) |
| else | — | `finish()` success/no-data (lenient) |

---

## 5. Data-phase FSM & completion

`phase ∈ {PH_IDLE, PH_DATA_IN, PH_DATA_OUT}`, with `buf` + cursor `pos`, and `drq`.

- **begin_data_in(p,n)**: `buf=p[0..n)`, `pos=0`; `n==0` → `finish()`; else `PH_DATA_IN`, `drq=true`.
- **begin_data_out(n)**: `buf=zeros(n)`; `n==0` → `finish()`; else `PH_DATA_OUT`, `drq=true`.
- **dma_r()** (device→mem, READ): return `buf[pos++]`; when `pos==buf.size()` → `finish()`.
- **dma_w(v)** (mem→device, WRITE): `buf[pos++]=v`; when full → `finish()`.
- **residual()** = `buf.size()-pos` while in a data phase (used by the DMA EOX check).

**finish()** → drain WRITE side-effects (if `PH_DATA_OUT && CDB==WRITE(10)`, `block_write` each 512 B block to the COW overlay), `phase=PH_IDLE`, `drq=false`, then **complete(0x16)**.

**complete(scsi_status)** — the IRIX-critical completion contract:
```
regs[0x17] = scsi_status;       // SCSI Status = ST_SELECT_TRANSFER_SUCCESS (0x16)
regs[0x0f] = tgt_status;        // Target/LUN <- target STATUS byte (GOOD 0x00 / CHECK 0x02)
regs[0x10] = 0x60;              // Command Phase = command complete
regs[0x12]=regs[0x13]=regs[0x14]=0;   // Transfer Count counted down to 0 (ZERO residual)
Aux &= ~(CIP|BSY); Aux |= INT;  // command done, INTRQ asserted
intrq = true; irq_poke;
```
Two of these are hard-won and **must be reproduced** or IRIX mis-reads the result:
- **reg 0x0f = target status** — IRIX reads 0x0f to tell GOOD from CHECK CONDITION; if left as the programmed LUN it mistakes lun≥2 for CHECK and loops INQUIRY/REQUEST-SENSE.
- **transfer count = 0** — a non-zero leftover reads as a *short transfer*; `sgiwd93` sets `b_error`, and `xfs_read_file`/chunkread bails (`b_error → ENOEXEC`).

---

## 6. Chunked transfers (pause / resume)

IRIX often programs the WD33C93 transfer count (and the DMA chain) for **fewer bytes than the SCSI command's full length**, then resumes for the rest. The model handles this:

- **Pause** (`pause_transfer`, called from CH_DESC_DONE/EOX when `residual()>0`): `drq=false`, `SCSI Status = 0x48` (data-out) / `0x49` (data-in), `Command Phase = 0x46` (count exhausted), `xfer count = 0`, Aux `INT`, `intrq`. `buf`+`pos` are **preserved**.
- **Resume**: IRIX reprograms the DMA channel for the remaining bytes and re-issues `SEL_ATN_XFER`. `select_and_transfer()` detects an in-flight data phase with `0 < pos < buf.size()` → re-asserts `CIP|BSY`, `drq=true`, and returns **without re-decoding the CDB**; the HPC3 DMA pump after the command write moves the rest from `pos`.

**Observed (one boot, §11):** 49 pause/resume events; IRIX caps a chain at **≈252 KB (504 blocks)**, so any SCSI transfer > 252 KB splits at 504-block boundaries — the **effective maximum single DMA is ≈ 252 KB**. This path is rare (49 of 7,654 commands) but mandatory for the > 128 KB tail.

---

## 7. Interrupt path

- WD33C93 **INTRQ** → IOC2 **local0 bit `0x02` (SCSI0)**, computed *live* from `scsi->intrq_pending()` (level-sensitive). `local0 & local0_mask` ≠ 0 → CPU **IP2**. Cleared when IRIX **reads SCSI Status (reg 0x17)**.
- HPC3 per-descriptor **XIE** → `intstat |= 0x100<<ch`, surfaced as `ctrl` bit0 and cleared on a `ctrl` read.
- (The SCC serial INT reaches IP2 via the mappable cascade `vmeistat bit5 → (cmeimask0) → local0 LIO2 bit7`; separate path, same local0 register.)

---

## 8. Disk backend

- Raw image opened read-only; `nblocks = size/512`.
- `block_read(lba)`: **COW overlay wins**; else `pread(fd, 512, lba*512)`; out-of-range → zero-fill.
- `block_write(lba)`: writes go **only** to an in-memory overlay (`unordered_map<lba, 512B>`) — the backing image is never modified.
- Optional **delta sidecar** (`IMDELTA1` magic + `{lba, 512B}` records) persists the overlay across runs.

---

## 9. End-to-end: one disk READ

```
1. driver: WD33C93 PIO -> Own ID/Control, stream CDB (READ(10) lba,len) into regs[0x03..],
           set Dest ID, write Command=SEL_ATN_XFER(0x08).
2. driver: build {BP=buf, BC=count, DP=...|EOX} descriptor(s) in DRAM,
           write nbdp, write ctrl=ACTIVE (DIR=0 for read).
3. WD33C93 select_and_transfer: decode READ(10) -> read len*512 from disk into buf -> PH_DATA_IN, DRQ=1.
4. HPC3 DMA armed: CH_FETCH {BP,BC,DP} -> CH_XFER: pump buf -> DRAM[BP] byte/byte while DRQ & count.
5. buf drained -> finish() -> complete(0x16): status, reg0x0f=GOOD, count=0, INTRQ.
   DMA: count==0 -> CH_DESC_DONE -> EOX -> deactivate (XIE -> channel IRQ).
6. IP2 -> driver reads SCSI Status (clears INTRQ), reads reg0x0f (GOOD), count==0 (full xfer).
   Data is in DRAM[BP]. Done.
```
WRITE(10) is the mirror: PH_DATA_OUT, DMA pumps DRAM→device, `finish()` drains `buf`→COW.

---

## 10. Henry RTL port — on-chip DMA engine + host disk back-end (as built)

The FPGA has **no SCSI bus and no disk image in RTL**, and IRIX's/Linux's driver can't be modified. The shipped design keeps **everything in §1–§7 identical** (so the stock driver is satisfied). The disk *media* lives off-chip in the host (the Zynq PS on the FPGA; `henry_tb` in sim), but — unlike the earlier host-serviced bridge — **the on-chip DMA engine, not the host, moves data into MIPS memory.** The invariant: **only the DMA engine ever touches MIPS-visible DRAM; the host touches only AXI slave registers.** That makes the transfer coherent by construction (below). Shared contract, sim + FPGA: `sim/scsi_service.h` (disk backend + `scsi_service_run` request decode) and `sim/henry_scsi.h` (`scsi_req_t`/`scsi_rsp_t` mailbox layout), reused by `driver/scsi_arm.h` on the board.

- **WD33C93 = control shim in RTL (`rtl/scsi_shim.sv`).** Register file + SASR/SCMD PIO semantics (§1.1, byte 3 = SASR / byte 7 = SCMD across the whole HD0 region) + the §5 completion contract (reg 0x0f, count→0, Command Phase 0x60, INTRQ → IOC2 local0 bit1 → IP2). It moves **zero** data bytes. On a `Select-And-Transfer` it snapshots `{cdb, dest, lun, xfer_len, nbdp, DIR}` into a mailbox, bumps the **doorbell** (`scsi_req_seq`), and pulses `dma_go` to start the engine. RESET (`COMMAND=0x00`) posts SCSI Status 0 + INTRQ for the driver's reset poll.
- **HPC3 SCSI DMA channel = the `scsi_dma` engine (`rtl/scsi_dma.sv`, `ENABLE_SCSI_DMA` on, arbiter master 1).** On `dma_go` it walks the guest's `{BP,BC,DP}` descriptor chain **in DRAM via M00** and moves the data itself: READ = drain the beat FIFO → `mem[BP]`; WRITE = `mem[BP]` → beat FIFO. It masks the partial final beat and follows the chain (scatter-gather). It is **the only agent that touches MIPS memory.**
- **Beat conduit (`rtl/scsi_beat_fifo.sv` + S00 slave regs).** The engine's disk side is a 16-byte-beat FIFO the host fills/drains over the ordered S00 AXI-lite leg. A per-cycle disk-beat handshake can't cross AXI-lite, so the engine **stalls** when the FIFO is empty and resumes as the host trickles beats in (the "very slowly" path). READ conduit: host writes each beat to regs `0x20-0x23` (push on the `0x23` write), polling `0x25` = FIFO-full for flow control. (WRITE-direction capture is validated in sim; the FPGA slave-reg wiring for it is a follow-up — v1 on silicon is reads-only.)
- **Host (PS / `henry_tb`) = the disk, never the DMA.** It polls the doorbell, reads the request over the mailbox, does the disk I/O **into its own buffer** (`pread` / COW overlay), and **streams the bytes as beats into the FIFO** — it never reads the descriptor and never writes DRAM. It posts the SCSI status (`scsi_rsp_*`) and echoes the doorbell. Disk-less safe: no image → `ST_SELECTION_TIMEOUT` so a disk-less guest (Linux from initramfs) completes its scan.

**Completion:** the shim holds `PH_BUSY` and completes on the engine's `dma_done` — so INTRQ can't fire until the last beat has landed in DRAM. **Or**, when the host has posted its rsp yet the engine is still blocked for a beat that won't come (`dma_rd_stalled`: short / no-data / unknown-opcode / selection-timeout), the shim cancels the engine and completes with a residual (real SCSI short-transfer). No RTL completion timeout is needed.

**AXI mailbox** (`ip_hdl/axi_is_the_worst_v1_0_S00_AXI.v`; PS word offsets): reads `0x30` req_seq(doorbell) · `0x31-0x33` CDB · `0x34` nbdp · `0x35` `{to_device,lun,dest}`; writes `0x0D` rsp_seq(echo LAST) · `0x0F` residual · `0x10` `{tgt_status,scsi_status}` · `0x11` `sel_delay`. **Beat conduit:** write `0x20-0x23` = the 16-byte read beat (push on `0x23`), read `0x25` = FIFO-full. Debug: read `0x38` = shim state (`#resets/#SASR-rd/#SCMD-wr/#SASR-wr` saturating counters + phase/CIP/BSY/INTRQ/SASR), read `0x3F` = RTL build revision (`0xYYYYMMDD`, bump per synth).

**Ordering / coherence (by construction):** the engine writes `mem[BP]` over **M00 — the same port the CPU reads from, serialized by the `mem_arbiter`** — so the guest can't read a stale buffer, and completion is gated on `dma_done` (after the write). The host never writes shared DRAM, so the PS↔PL non-coherence / cross-path-ordering hazards of the host-serviced bridge are gone. The guest's own pre-DMA `dma_cache_inv` remains its responsibility (orthogonal; see "Cache coherence" in `hpc3.md`).

Net: the on-chip DMA engine does the DRAM I/O over M00; the host supplies disk bytes over the ordered slave-reg conduit and never touches MIPS memory; the WD33C93 + HPC3 register/completion behavior is byte-for-byte faithful so IRIX **and** Linux boot unmodified. Validated in Verilator: engine unit test, directed `scsi_read`/`scsi_write` round-trips, and a live IRIX boot to the banner (30 clean transfers incl. a 256 KB read, zero hangs).

**Sizing (from the §11 boot profile):** small-transfer dominated — median **4 KB**, 90%+ ≤ 32 KB — so the doorbell round-trip must make the 4 KB case cheap. The tail runs to ~256–512 KB, chunked by the HPC3 descriptor chain at **≈252 KB** (§2, §6). The engine walks the real chain, so multi-descriptor scatter-gather falls out for free. Absent-target IDs (2–7) draw a selection-timeout, LUN≠0 CHECK-CONDITIONs (§11) — both from `scsi_service_run`.

---

## 11. Boot workload profile (empirical)

Measured over one IRIX 6.5.22 boot — PROM power-on → root mount → rc-scripts → `root` login → `csh` prompt (`IRIS 1#`) — captured with `SCSIDBG=1` against the interp_mips model on the clean image. This is the workload the RTL shim must satisfy and be sized for. Reproduction recipe + regeneration scripts: `interp_mips/IRIX_SCSI_PROFILE.md`.

**Command mix — 7,654 commands + 18 selection-timeouts:**

| count | op | command | share |
|------:|:--:|---------|------:|
| 5,486 | 0x28 | READ(10)          | 71.7% |
| 2,108 | 0x2a | WRITE(10)         | 27.5% |
|    26 | 0x12 | INQUIRY           |       |
|    13 | 0x00 | TEST UNIT READY   |       |
|    12 | 0x25 | READ CAPACITY(10) |       |
|     7 | 0x03 | REQUEST SENSE     |       |
|     2 | 0x1a | MODE SENSE(6)     |       |

~99.2% is filesystem I/O; ~60 commands are discovery/control. **Every opcode seen is already in the §4 decode table** — the implemented command set is complete for an unmodified boot to a shell (no 6-byte READ/WRITE, no MODE SELECT or START/STOP observed on this image, though §4 handles them).

**Target / LUN:**
- All real I/O is **target 1, LUN 0** — 7,640 commands.
- IRIX's LUN scan probes t1 LUN 1–7 (INQUIRY + REQUEST SENSE, 2 each); each gets one CHECK CONDITION (LUN-not-supported) and stops — validates the §4 LUN gate.
- Absent **targets 2–7** draw **3 selection-timeouts each** (18 total); target 0 unprobed, target 7 = host-adapter ID. → the shim must answer a selection-timeout for absent IDs.

**Transfer sizes** (`cdb[7:8]` blocks × 512):

| | READ(10) | WRITE(10) |
|--|--|--|
| transfers | 5,486 | 2,108 |
| total bytes | 73.3 MB | 27.7 MB |
| median | 8 blk / 4 KB | 8 blk / 4 KB |
| mean | ~14 KB | ~14 KB |
| max | 1024 blk / 256 KB | 800 blk / 400 KB |
| dominant | 56% @ 4 KB, 36% @ 8–32 KB | 70% @ 4 KB, 17% @ 8–32 KB |

4 KB = the XFS filesystem block/page; 32 KB = XFS readahead / log clustering. Small-transfer dominated (median 4 KB, 90%+ ≤ 32 KB) with a hundred-KB tail. READ:WRITE byte ratio ≈ 73 MB : 28 MB (writes are rc-script churn on `/var`, logs, `/tmp`, and the XFS journal).

**Chunked DMA (§6):** 49 pause/resume events. A single HPC3 descriptor chain is capped, so SCSI transfers larger than the cap split at descriptor boundaries. Observed chunk granularity at pause: **252 KB (504 blk = 0x3F000) ×43** and 504 KB ×6 → **effective max single DMA ≈ 252 KB**. Transfers that got chunked: 256 KB ×28, 512 KB ×10, 400 KB ×7 (+ a few odd sizes). Open question (worth confirming): whether the 252 KB cap is the HPC3 descriptor-count limit or an XFS max-contiguous-I/O setting.

> Scope: one boot of the clean 6.5.22 image (warm — kernel reconfigure already done), root/no-password login through the `tset` handshake to the `csh` prompt. Writes go to a COW overlay; the base image stays read-only.

---

## Sources
- `interp_mips/sgi_scsi.cc` / `sgi_scsi.hh` — fused WD33C93A + disk target (the §1.1, §4, §5, §6, §8 behavior).
- `interp_mips/sgi_hpc.cc` / `sgi_hpc.hh` — HPC3 SCSI DMA channel + IOC2/INT2 (§1.2, §2, §3, §7).
- Validated against a live IRIX 6.5 boot (MAME `wd33c9x.cpp`/`hpc3.cpp` as the oracle).
- `interp_mips/IRIX_SCSI_PROFILE.md` — the §11 boot workload profile (command mix, target/LUN, transfer-size distribution, chunked-DMA cap) + reproduction/regeneration scripts.
- Companion: `hpc3.md` (HPC3 block spec), `ioc2.md` (INT2/local0 → IP mux). RTL plan: the henry DRAM arbiter (`henry_soc.sv`).
