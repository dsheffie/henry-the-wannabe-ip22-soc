# r9999 microarchitecture

*The CPU at the center of Henry. `r9999` is an **out-of-order, superscalar MIPS** core — its name is a wink at the **R10000** (`9999 = 10000 − 1`), and its shape is deliberately R10000-flavored: register renaming, a reorder buffer, out-of-order issue, separate integer/FP register files. But it targets the **R4600 ISA** (so IRIX/Indy runs the right path), it's **2-wide** instead of 4, and it's tuned to **fit and close timing on an FPGA**.*

This page is the r9999 answer to the **R10000 block diagram (Fig. 1-5)** from the MIPS R10000 User's Manual — written in the spirit of [maizure.org's reverse-engineering writeups](https://www.maizure.org/projects/evolution_x86_context_switch_linux/). Every number below is from the RTL in the [`r9999`](https://github.com/dsheffie/r9999) submodule (canonical, non-`FORMAL` config); `machine.vh` is the parameter header.

## Block diagram

```mermaid
flowchart TD
    SYS["<b>System interface</b><br/>→ Henry SoC / MC · AXI on FPGA<br/>physical address = 36-bit"]
    L2["<b>L2 cache</b><br/>16 KB · direct-mapped · 16 B line<br/>on-die · L1I + L1D arbitrate"]
    SYS --- L2

    subgraph FE["Front end — 2-wide fetch"]
        BP["<b>Branch predictor</b> — gshare<br/>PHT 64K × 2-bit · GHist 64-bit<br/>BTB 128 · return stack 4"]
        L1I["<b>L1 I-cache</b><br/>4 KB · direct-mapped · 16 B line"]
        FQ["Fetch queue · 8 entries"]
        BP --> L1I --> FQ
    end

    subgraph REN["Decode / rename — 2-wide"]
        DEC["<b>decode_mips</b><br/>2 uops / cycle"]
        DQ["Decode queue · 4"]
        MAP["<b>Rename maps</b><br/>INT-RAT · FP-RAT · HILO-RAT<br/>+ free lists"]
        DEC --> DQ --> MAP
    end

    subgraph OOO["Out-of-order issue"]
        ROB["<b>Reorder buffer</b> · 32 entries<br/>even/odd banked · retire 2 / cycle"]
        ISCH["<b>Integer scheduler</b> · 8 entries<br/>age-matrix oldest-ready · 1 ALU / cycle"]
        MQS["<b>Memory queues</b><br/>UQ 8 · Mem-UQ 4 · store-data 4 · MQ 4"]
    end

    subgraph PRF["Physical register files"]
        IPRF["<b>INT PRF</b> (clustered) · 2 banks × 64<br/>rf4r2w 4R/2W · 1 write port per bank<br/>non-mem bank + mem (load) bank"]
        FPRF["<b>FP PRF</b> (clustered) · 2 banks × 64<br/>non-mem (move) + mem (load) banks"]
        HILO["<b>HILO PRF</b> · 4 × 128-bit"]
    end

    subgraph EXU["Execution units"]
        ALU["<b>Integer ALU</b><br/>1-cycle"]
        MUL["<b>Multiplier</b><br/>3-cycle → HILO"]
        DIV["<b>Divider</b><br/>~65-cycle → HILO"]
        LSU["<b>Load / Store</b><br/>AGU integrated"]
    end

    ITLB["<b>I-TLB</b><br/>48-entry FA CAM"]
    DTLB["<b>D-TLB</b><br/>48-entry FA CAM"]
    TSH["TLB shadow RAM · 48<br/>tlbr index reads · tlbwi/tlbwr broadcast to both CAMs"]
    L1D["<b>L1 D-cache</b><br/>4 KB · direct-mapped · 16 B line"]

    FQ --> DEC
    MAP --> ROB
    MAP --> ISCH
    MAP --> MQS
    ISCH --> ALU
    ISCH --> MUL
    ISCH --> DIV
    MQS --> LSU
    IPRF -.->|read| ALU
    IPRF -.->|read| LSU
    FPRF -.->|read| LSU
    HILO -.-> MUL
    HILO -.-> DIV
    ALU --> ROB
    LSU --> L1D
    LSU --> DTLB
    L1I --> ITLB
    L1I --> L2
    L1D --> L2
    TSH -.->|sync| ITLB
    TSH -.->|sync| DTLB
```

## Walking the pipeline

**Front end (2-wide).** Each cycle the **gshare** predictor indexes a **64K × 2-bit** pattern-history table by folding a **64-bit global history** against the PC, with a **128-entry BTB** and a **4-entry return stack**; speculative *and* architectural copies of the history/RAS are kept so a misprediction restarts cleanly. The **L1 I-cache** (4 KB, direct-mapped, 16 B lines) delivers up to **two instructions/cycle** into an **8-entry fetch queue**. *(`l1i.sv`, `compute_pht_idx`, `machine.vh`)*

**Decode / rename (2-wide).** `decode_mips` cracks up to two instructions into uops; a **4-entry decode queue** buffers them for the allocator, which renames through three maps — **integer**, **FP**, and **HILO** RATs with free lists — onto the physical register files. *(`decode_mips.sv`, `core.sv`)*

**Out-of-order issue.** Renamed uops allocate into a **32-entry reorder buffer** (split even/odd so two consecutive entries write different banks → 2 allocate and 2 retire per cycle). Integer ALU ops wait in an **8-entry scheduler** that picks the **oldest ready** entry via an age matrix; memory ops flow through dedicated queues (**UQ 8**, **Mem-UQ 4**, **store-data 4**, **MQ 4**). Issue is **1 ALU op + 1 memory op per cycle**. *(`core.sv`, `exec.sv`, `fair_sched.sv`)*

**Misprediction / exception recovery — no RAT checkpoints.** r9999 keeps two rename maps per register class: the speculative **allocation RAT** and a **retirement RAT** that follows the committed architectural map. On a branch mispredict or exception it does **not** roll back to a per-branch snapshot. Instead the machine **drains** (state `DRAIN`): younger uops are squashed and it waits for the offending op to reach the head of the 32-entry ROB — at which point the *retirement* RAT already holds the correct map. It then copies **retirement RAT → allocation RAT** in a single cycle (state `RAT`: `r_alloc_rat <= r_retire_rat`, and likewise for FP/HILO) and restarts fetch. No checkpoint storage, no finite-checkpoint allocation stall, and the *same* path handles both mispredictions and exceptions. *(`core.sv` — `DRAIN → RAT → ACTIVE` state machine, `t_rat_copy`)*

!!! note "Why skipping RAT checkpoints is fine"
    This was a **design judgment**, not a derived result. Per-branch **RAT checkpointing** — snapshot the logical→physical map, restore it in one cycle, and reclaim the physical registers allocated since — is fundamentally a **PRF-machine technique** (the R10000 is the classic example). Intel's **"data-in-ROB" P6 and Nehalem** can't use it: with no physical register file, speculative values live in ROB entries, so recovery instead falls out of rolling the ROB tail back and restoring the map from the retirement (committed) state. r9999 *is* PRF-based — so the R10000-style checkpoint scheme was on the table — but it deliberately borrows the **data-in-ROB-style restore-from-retirement** recovery (drain to commit, copy retirement RAT → allocation RAT), a ballpark call from P6/Nehalem experience that the modest drain latency is fine.

    **Henry Wong's thesis** gives the matching quantitative corroboration — *A Superscalar Out-of-Order x86 Soft Processor for FPGA*, U. Toronto 2017, in the repo as `Wong_Henry_T_201711_PhD_thesis.pdf` (Ch. 7, Register Renaming). Two advantages over checkpoints: **one mechanism covers both branch mispredictions and exceptions**, and there's **no cap on outstanding branches** (checkpoints are finite — the R10000 stalls when it runs out). The drawback — recovery isn't instantaneous; the bad branch must commit first — he measures at only **~2.3 % of cycles (≈ 4 clocks per pipeline flush)**, and that's an *upper bound* (the core is usually still retiring useful older work). It stays small because branches **resolve in program order** (mispredicts detected near commit) and a **long front end** delays corrected-path instructions until after the drain.

**Register files (clustered).** The integer PRF is a **clustered (banked) register file** (`rf4r2w`, 4 read / 2 write): it's split into **two single-write-port banks** selected by the high bit of the physical-register number — a **non-memory bank** written by ALU/move results (write port 0) and a **memory bank** written by load results (write port 1). That's the whole reason the physical-register count is large: **2 banks × 64 = 128**, not a deep rename window. It's the FPGA-friendly way to get two write ports per cycle out of plain single-write-port block RAMs (a Henry-Wong-style clustered RF) instead of paying for a true multi-write-port file. The **FP PRF** is banked the same way (non-memory = `mtc1`/moves, memory = FP loads), and a small **4 × 128-bit HILO PRF** holds multiply/divide results. The effective rename window is still bounded by the **32-entry ROB**. *(`rf4r2w.sv` — "Clustered (banked) register file"; `exec.sv`)*

**Execution units.** One **integer ALU** (1-cycle), a **3-cycle pipelined multiplier** and an **iterative ~65-cycle divider** (both writing the HILO PRF), and a **load/store unit** with address generation folded in (no separate AGU stage) feeding the L1 D-cache. **There is no FP arithmetic yet** — the FP path implements `mfc1/mtc1`-style moves and FP loads/stores only; the core still reports an R4000-family FPU id (`FIR`) so software probes succeed. *(`exec.sv`, `mul.sv`, `divider.sv`)*

**Memory & translation.** L1 D-cache is 4 KB direct-mapped (16 B lines); L1I and L1D arbitrate for a shared **on-die 16 KB direct-mapped L2**, which fronts the **system interface** out to the Henry SoC / memory controller (AXI on the FPGA), with **36-bit physical addresses**. Translation presents the R4x00 **48-entry fully-associative TLB** (dual-page even/odd, 4 KB pages, 8-bit ASID, global bit) — but it is **not** a single shared joint TLB. r9999 **duplicates the CAM per L1 cache** — an **I-TLB** in `l1i` and a **D-TLB** (`dtlb`) in `l1d` — so instruction fetch and load/store translate **in parallel** without contending for one structure, and keeps them coherent by **broadcasting every `tlbwi`/`tlbwr` to both CAMs** (`core_l1d_l1i.sv`). Because a content-addressed CAM can't be read by index, a separate **48-entry RAM shadow** (`r_shadow_tlb` in `exec.sv`) holds the entries so the index-addressed instructions — `tlbr` in particular — can read them back. No micro-TLB. *(`l1i.sv`, `l1d.sv`, `tlb.sv`, `exec.sv`, `core_l1d_l1i.sv`)*

## r9999 vs. the R10000 it's named after

| | **R10000** (1996) | **r9999** |
|---|---|---|
| ISA | MIPS IV (R10000) | MIPS III/IV, **presents as R4600** (`PRId 0x2020`) |
| Fetch / decode / issue / retire | 4-wide | **2-wide** |
| Branch prediction | 512-entry 2-bit BHT | **gshare**: 64K×2b PHT, 64-bit GHist, 128 BTB, 4 RAS |
| Physical registers | 64 int + 64 FP (true multiport RF) | **128 int + 128 FP** (clustered: 2 banks × 64) + 4 HILO |
| In-flight window | 32 (active list) | **32 (ROB)** |
| Mispredict / exception recovery | per-branch **RAT checkpoints** (finite → caps outstanding branches) | **copy committed RAT after drain** — no checkpoints; one path for mispredict + exception |
| Issue queues | 3 × 16 (address / integer / FP) | 8-entry integer scheduler + memory queues; **no FP queue** |
| Functional units | 2 ALU + addr-calc + FP add + FP mul | **1 ALU + mul + div + load/store**; no FP arithmetic |
| L1 I / D | 32 KB 2-way each | **4 KB direct-mapped each** |
| L2 | off-chip, 512 KB–16 MB, dedicated controller | **on-die 16 KB direct-mapped** |
| TLB | 64-entry, single shared | **48-entry FA CAM, duplicated per L1** (I-TLB + D-TLB) + RAM shadow; R4x00-style software model |
| Register width / FPU | 64-bit · full pipelined FPU | 64-bit · **no FPU yet** (moves + ld/st only) |

## Why it diverges from the R10000

- **It's an R4x00 *ISA* target, not an R10000.** IRIX's `/unix` branches on `PRId.IMP` in `start`; r9999 presents **R4600** so the kernel takes the Indy per-CPU path (see [MAME_QUESTIONS Q5](https://github.com/dsheffie/r9999)). The **48-entry TLB** mirrors the R4x00 (not the R10000's 64), which is also what IRIX's `wirepda`/refill code expects.
- **It's built for an FPGA.** 2-wide instead of 4, **direct-mapped** caches, and a modest on-die L2 keep LUT/BRAM/timing in budget on the Ultra96-v2 (Zynq UltraScale+). Conversely the **gshare PHT is much larger** than the R10000's BHT — block RAM is cheap on FPGA, so prediction accuracy is bought with BRAM rather than logic.
- **The big physical-register counts are a clustered RF, not a deep window.** 128 INT / 128 FP physical registers = **2 banks × 64**. Each register file is split into two single-write-port banks (non-memory results vs memory/load results), selected by the preg-number MSB, so the core gets two write ports per cycle from cheap single-write-port FPGA RAMs instead of a true multi-write-port file. The architectural rename window is still gated by the **32-entry ROB** — the count is an implementation artifact of the banking, not extra in-flight capacity.
- **No RAT checkpoints — even though it's a PRF machine.** RAT checkpointing is a PRF-machine technique, so the R10000-style scheme was available to r9999 — but it instead drains to the ROB head and restores the map from the retirement RAT, the data-in-ROB-style (P6/Nehalem) recovery chosen from experience and corroborated by Wong (Ch. 7). See the rename-recovery note above.
- **No hardware FPU yet.** The FP register file and the move / load-store path are in place; FP arithmetic is future work, and the core reports an R4000-family FPU id so software probes succeed.

!!! note "Known FPGA bottleneck"
The **fully-associative 48-entry TLB CAMs** — one per L1 cache, so every fetch *and* every load/store does a 48-way parallel CAM match — are the current critical path on the Ultra96-v2 build (negative WNS at 100 MHz). The 48-entry size is fixed by the architecture; the fix is a hardware **micro-TLB** in front of each CAM — a small fast L1 translation cache that removes the big CAM from the common-case path.

---

## Branch delay slots and the control FSM

The single biggest ISA difference between r9999 (MIPS) and its sibling RISC-V soft core `rv64core` isn't register width or opcodes — it's one architectural rule: **in MIPS the instruction after a branch (the *delay slot*) always enters the pipeline, and on a taken branch it executes *before* control reaches the target.** RISC-V has no such rule. That one rule is why r9999's primary control FSM (`core.sv`) carries a cluster of states `rv64core` simply doesn't have:

| Concern | r9999 states | rv64core |
|---|---|---|
| The delay slot itself | **`DELAY_SLOT`** | — |
| Precise exceptions with EPC + BD bit | **`ARCH_FAULT` → `WRITE_EPC` → `EXCEPTION_DRAIN`** | folded inline into `ACTIVE` → `DRAIN` |
| A fault *inside* a delay slot | **`SERIALIZE_IN_FAULTED_DELAY_SLOT`, `WAIT_FOR_SERIALIZE_IN_FAULTED_DELAY_SLOT`** | — |

`rv64core` spends its "extra" states on RISC-V concerns instead — `WAIT_FOR_CSR_WRITE`, `WAIT_FOR_MMU`, and a legacy syscall-emulation monitor path — none of which touch control flow. Every corner case below is a place where r9999's FSM must do something the RISC-V machine never thinks about.

**1. The branch and its delay slot are one atomic unit.** When a branch reaches the ROB head needing a redirect, r9999 doesn't just restart — it captures the branch's metadata (`n_has_delay_slot`, `n_take_br`, `n_restart_pc`) and enters `DRAIN`, and `head_of_rob_ptr_valid` is held true in `DRAIN` *only while `!r_ds_done`* so the delay slot can still retire. The pair commit together (`retire`/`retire_two`); you can never retire the branch and squash its slot. `rv64core`'s branch path is one line — `n_restart_pc = t_rob_head.target_pc` — retire, redirect, done.

**2. Misprediction recovery must preserve the slot.** r9999 recovers `ACTIVE → DRAIN → RAT → ACTIVE` (the no-checkpoint recovery described above): it drains younger work *but lets the delay slot through*, then copies the retirement RAT back. The squash boundary is "after the delay slot," not "after the branch." In `rv64core` the boundary is simply "after the branch" — there's nothing in between.

**3. Branch-likely nullification.** MIPS `beql`/`bnel`/… *nullify* their delay slot when the branch is **not** taken. r9999 marks these `has_nullifying_delay_slot`, and `DRAIN` encodes the rule directly: if `r_take_br` the slot retires (`t_retire`); if not, `t_retire` stays 0 and the slot is dropped — `n_ds_done` is set either way. RISC-V has no branch-likely, so `rv64core` has no nullify concept at all.

**4. A fault in the delay slot blames the branch.** The famous one. In `ARCH_FAULT` → `WRITE_EPC`, r9999 computes `n_epc = in_delay_slot ? (pc − 4) : pc` and sets `n_exc_in_delay = in_delay_slot` — **EPC points at the branch, and `Cause.BD` is set.** On `eret` the kernel re-executes the branch, which re-executes the slot. `rv64core` writes `n_epc = t_mrob_head.pc` — always the faulting instruction's own PC, no BD bit, no `−4`. (This BD/EPC handling, and gating EPC on `Status.EXL` for nested refills, is exactly the bug class from `MAME_QUESTIONS` Q5 / round-7.)

**5. A branch *in* a delay slot — architecturally UNPREDICTABLE — is given a defined answer.** When the head instruction is itself in a delay slot, r9999 restarts to `r_last_branch_target` rather than its own `target_pc`: `n_restart_pc = in_delay_slot ? r_last_branch_target : t_rob_head.target_pc`. The *outer* branch wins; the inner branch's target is discarded. Tellingly, this exact ternary appears in **three** states — `ACTIVE`, `WAIT_FOR_SERIALIZE_AND_RESTART`, and `CACHE_FLUSH` — every place a redirect is produced. `grep` for `in_delay_slot`/`last_branch_target` in `rv64core/core.sv` returns nothing.

**6. The exception boundary can't fall between the pair.** You may not take an interrupt or fault *between* a branch and its delay slot. r9999 enforces this at allocation: with a fault pending, the alloc condition is gated by `r_pending_fault ? r_in_delay_slot : 1'b1` — only the delay slot may still be allocated, nothing past it — so the machine resolves the pair before redirecting to a vector. `n_in_delay_slot` is threaded through rename from the just-allocated branch's `has_delay_slot`. `rv64core`'s alloc has no such guard.

**7. When the slot faults but the branch must commit first.** If a delay slot faults while its branch is a serializing/oldest-first op, r9999 can't just take the fault — it routes through `SERIALIZE_IN_FAULTED_DELAY_SLOT` / `WAIT_FOR_SERIALIZE_IN_FAULTED_DELAY_SLOT`, which allocate and wait for the *branch* (`rob_next_head`) to complete, then decide the fault against the correct instruction. Two whole states exist solely for this ordering puzzle; `rv64core`, with no pair to order, has zero.

**The tax.** r9999 needs a 3-state exception sequence (`ARCH_FAULT` → `WRITE_EPC` → `EXCEPTION_DRAIN`) where `rv64core` writes `epc`/`cause` inline and falls straight into `DRAIN`, plus four extra delay-slot states besides — all to honor one ISA rule. This is, literally, the control-complexity tax of branch delay slots that RISC-V was designed to avoid: a win for a scalar 5-stage R2000 pipeline, but on an out-of-order machine the delay slot turns every redirect, every exception, and every squash into a "…and the delay slot" special case.

## The TLB — translation datapath

r9999's MMU is a software-managed MIPS TLB: a **48-entry fully-associative JTLB**, instantiated **twice** — one copy in `l1i.sv` (the ITLB, fetch translation) and one in `l1d.sv` (the DTLB, load/store translation). Both are kept identical: every `TLBWR`/`TLBWI` broadcasts the written entry on `tlb_entry_out`/`tlb_entry_out_valid` (assembled in `exec.sv` from the CP0 staging regs) to **both** caches' `tlb_entry_in` ports, so one software write lands in both CAMs. There is no micro-TLB — each is the full 48-way CAM, which is the design's worst timing path (the fully-associative match → priority encode → PFN mux dominates WNS).

**Dual-page entries.** Each entry is a MIPS even/odd *pair*: one `VPN2` (page number, low bit dropped) plus two physical halves — `pfn0/v0/d0/c0/g0` (even) and `pfn1/v1/d1/c1/g1` (odd); `va[12]` selects the half on a hit. Pages are **4 KB only** — `PageMask` is stored (and must read back what was written; it is **not** RAZ/WI) but is **not used in the match**. Variable-page-size matching is a deferred gap, safe because a vanilla IRIX/Linux boot writes 100% `PageMask=0`.

### Two-stage lookup (and why conflating the stages bites)

A MIPS TLB lookup is **two independent stages**:

1. **Match** — does any slot's `(VPN2, R, ASID/Global)` equal the VA's? In `tlb.sv`:
   ```
   w_hit8k[i]         = (r_tlb[i].vpn[26:0] == va[39:13]) & (r_tlb[i].r == va[63:62]);
   w_addr_space_match = (r_tlb[i].asid == asid) | (r_tlb[i].g0 & r_tlb[i].g1);
   w_hits[i]          = w_addr_space_match[i] & w_hit8k[i] & r_tlb_written[i];
   ```
   The compare is the **full** `VPN2 = va[39:13]` (27 bits) **plus region `R = va[63:62]`**, matching the Sail spec (`mips_tlb.sail tlbEntryMatch`) — not a 19-bit `va[31:13]` shortcut. **No match ⇒ TLB Refill.**
2. **Validity** — only *after* a match: the selected half's `V` (`va[12] ? v1 : v0`). `V=0 ⇒ TLB-Invalid`; a store with `D=0 ⇒ TLB-Modified`; else `PA = {pfn, va[11:0]}`.

The point that bites: **Refill ("no slot for this page") and Invalid ("slot exists but page not present") are different exceptions with different handlers.** Refill = "go look it up"; Invalid = "I have a slot marked not-present, go fault it in."

### The `r_tlb_written` slot bit (= Sail `entry.valid`)

A slot is matchable **once software has written it** (`TLBWR`/`TLBWI`), tracked by a per-slot `r_tlb_written` bit (set on write, cleared at reset) — **not** by `(v0|v1)`. This is load-bearing because **demand paging installs both-pages-invalid entries**: the refill handler, finding a not-yet-present PTE, does `tlbwr` with `v0=v1=0` (real VPN, zero PFN). That entry **must still match** so the retry takes **TLB-Invalid → `do_page_fault`**, which allocates the page; the next refill then installs `V=1`. The canonical first-touch of a user page:

```
fetch 0x120000230 → no slot     → Refill → tlbwr v0=v1=0 (PTE absent)
retry             → slot matches → V=0    → TLB-Invalid → do_page_fault (allocate)
retry             → Refill       → tlbwr V=1 (real PFN) → fetch hits → process runs
```

An earlier match used `& (v0|v1)` instead of `& r_tlb_written` — a cheap "is this slot real?" guard against power-on garbage VPNs. It worked for valid entries but **excluded the demand-paging `v0=v1=0` entry**, so the Invalid stage never fired: the retry re-refilled forever, `do_page_fault` was never reached, and the first user page was never allocated — an **infinite-refill livelock** that blocked Linux/IRIX from running `/init`. (Found by tracing `interp_mips` — which *does* map the page — and an RTL `[tlbinstall]` probe that showed `v0=0 v1=0` installs at the right `vpn=0x90000` that never matched.)

The fix splits the two meanings exactly as Sail does: `entry.valid` (`mips_tlb.sail:71`, set on every TLB write at `mips_insts.sail:1749`) gates the **match**, while per-page `v0/v1` drive the **Invalid** exception. `r_tlb_written` *is* `entry.valid`. It is a model/implementation bit, **not** an architectural register field — the R4400 manual has only `V0/V1`. Real hardware avoids needing it by requiring software to `tlb_init` all 48 slots to non-matching values at boot; r9999 carries the bit instead, so correctness can't be defeated by a forgotten init in firmware or a bare-metal test. **Timing-free:** a single flop bit replaces the `(v0|v1)` OR, so the critical CAM term stays a plain 3-input AND.

### CP0 state the refill handler reads (all must be full-width)

The IP22 kernel's runtime-generated XTLB refill handler is a **3-level page-table walk** reading three CP0 sources — a 32-bit truncation in any of them silently corrupts the walk:

| CP0 reg | r9999 contents | the handler uses it for |
|---|---|---|
| `BadVAddr` (8) | full 64-bit faulting VA (`dmfc0` returns `r_badvaddr`, not sign-extended) | PGD index (`BadVAddr>>27`) + PMD index (`BadVAddr>>18`) |
| `Context` (4) | `{PTEBase[31:23], BadVPN2=va[31:13], 0000}` (19-bit VPN2) | 32-bit-addressing PTE pointer |
| `XContext` (20) | `{XPTEBase[30:0], R[1:0], BadVPN2=va[39:13], 0000}` (27-bit VPN2) | 64-bit-addressing PTE index |

On any TLB fault, `save_to_tlb_regs` (asserted for **both** i-side fetch and d-side load/store misses, `core.sv`) auto-loads `EntryHi.VPN2 = core_badvaddr[39:13]`, `EntryHi.R = core_badvaddr[63:62]`, and `BadVPN2` — all full. The handler does **not** rewrite `EntryHi`; it relies on this auto-load, then only `dmtc0`s `EntryLo0/1` (the walked PTEs) before `tlbwr`. So the installed VPN comes entirely from the hardware auto-load.

### Vector selection

`core.sv` picks the refill vector by the **addressing mode of the faulting access**: the **XTLB** vector (`ebase+0x080`) when 64-bit addressing is active for that mode (`in_64b_kernel_mode | in_64b_supervisor_mode | in_64b_user_mode`), else the 32-bit **TLB** vector (`ebase+0x000`); both only when `EXL=0`. A nested miss (`EXL=1`) and TLB-Invalid/Modified fall to the general vector (`ebase+0x180`). n64 user processes run `UX=1`, so a user miss vectors to XTLB refill — which is why the handler reads `XContext`.

### Segment decode (`mipsseg.sv`)

Ahead of the CAM, `mipsseg` classifies the VA: **xkphys** (`va[63:62]=10`, needs `w_in_64b_mode`) → unmapped `PA=va[58:0]`; **xkuseg/xsseg/xkseg** (64-bit mode) → TLB-mapped; **32-bit compat** (sign-extended `va[63:32]=ffffffff`, or `!w_in_64b_mode`) → `kuseg/kseg0/kseg1/kseg2` by `va[31:29]`. `w_in_64b_mode = in_kernel_mode | (in_user_mode & UX) | (in_supervisor_mode & SX)` — kernel is always 64-bit-capable (independent of KX, which gates only addressing/XTLB selection). A mapped non-compat VA outside `SEGBITS` raises AdEL/AdES.

> **Doc note:** the older "match only the low-19-bit `VPN2` / ignore region" workaround (commit `e451d50`, described in [Cache, coherence & TLB](coherence-cache-tlb.md)) was **superseded** by the full Sail-conformant `va[39:13]+R` compare now in `tlb.sv`; the high-VA `wirepda` case it patched is handled correctly because `EntryHi` stores the full `VPN2`/`R` from the GPR (per Sail `MTC0`).

**Open TLB gaps:** variable page size (`PageMask` in the match), i-side out-of-range PA/VA AdEL, and TLB-`C` cacheability for mapped pages (currently hardcoded in `mipsseg`).

---

*All structural facts above are from the r9999 RTL (`*.sv`) and `machine.vh`, canonical (non-`FORMAL`) configuration. The [IRIX boot flow](irix-boot-flow.md) page covers what this core *runs*; this page covers what it *is*.*
