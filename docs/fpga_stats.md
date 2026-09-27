# FPGA design stats (Vivado synth/impl)

Parsed from the Vivado post-route reports by **`fpga_stats.sh`**. Regenerate after
a synth (`rebuild_henry.tcl` writes `~/timing_after.rpt` + `~/util_after.rpt`):

```sh
./fpga_stats.sh >> docs/fpga_stats.md   # appends a dated, commit-stamped block
```

**Target:** Ultra96-v2 (Zynq UltraScale+ ZU3EG), `clk_pl_0` @ **100 MHz** (10 ns).
The WNS path has long been the **icache -> ITLB -> `pa_reg`** chain (the 48-entry
fully-associative TLB CAM), and it is **route-dominated** (~63% route) -- so area
reductions that shrink the TLB array tend to help WNS more than logic-level
counting suggests. Newest block first.

## 2026-07-19 -- r9999 2edef07 (submodule-on-main: 16 KB L1I+L1D, 128 KB L2, find_lowest_set_bit, programmable debug watchpoint)

First synth after the `r9999` submodule was repointed at a **clean `origin/main`** (2edef07):
**16 KB L1I + 16 KB L1D** (was 4 KB each; VIPT tag-widened so alias-safe above the 4 KB page),
**128 KB write-back L2**, the `find_first_set` -> `find_lowest_set_bit` priority-encoder fix, and
the driver-**programmable** debug breakpoint/store-watchpoint/fault-trap interface
(`ENABLE_DEBUG_WATCHPOINT`, injected at build by `gen_mipscore.sh` via `SV2V_DEFINES`). Built with
the watchpoint **ON**.

| metric | value |
|--------|-------|
| WNS @ 100 MHz | **+0.096 ns** (all met, 0 failing endpoints; impl_11) |
| Worst path | icache -> 48-way ITLB CAM -> `pa` (route-dominated, unchanged) |
| CLB LUTs (post-route) | 52094 (73.83%) |
| LUT as Memory (LUTRAM) | 1813 (6.30%) |
| CLB Registers (FF) | 35665 (25.27%) |
| Block RAM | 60.5 (28.01%) |
| DSP | 43 (11.94%) |

> The 4x L1 bump (4 KB -> 16 KB each) is the big structural delta vs the 2026-07-03 build below:
> **Block RAM 25 -> 60.5** (the larger tag/data/predecode arrays), the point of the tag-widening
> work that makes >4 KB VIPT L1 alias-safe. **CLB LUTs are *lower* than the last logged build**
> (62320 -> 52094) thanks to the area-reduction work landed since (banked ROB, the
> `find_lowest_set_bit` rewrite, clustered FP register file). **WNS +0.096 ns** holds on the same
> route-bound ITLB-CAM path -- the micro-TLB in front of the JTLB remains the structural fix for
> real margin. (The per-hierarchy LUT breakdown below is from the 2026-07-03 netlist; the
> `find_first_set` row there is the pre-fix encoder, now `find_lowest_set_bit`.)

## 2026-07-03 -- 1fdc585 (mem-pipe CACHE hit-ops) -- WNS + full LUT breakdown by hierarchy

| metric | value |
|--------|-------|
| WNS @ 100 MHz | **+0.147 ns** (all met, 0 failing endpoints; impl_12 strategy) |
| Worst path | `cpu/cpu/e/r_int_result_reg[0]` -> `cpu/dcache/dtlb/pa_reg[28]` |
| Data path delay | 9.501 ns  (logic 2.874 ns / **30.3%**, route 6.627 ns / **69.7%**) |
| CLB LUTs (post-route) | 62320 (88.32%) |
| LUT as Logic | 60469 (85.70%) |
| LUT as Memory (LUTRAM) | 1851 (6.43%) |
| CLB Registers (FF) | 35910 (25.45%) |
| Block RAM | 25 |
| DSP | 43 |

> The worst path shifted this build from the icache->ITLB chain to the **dcache** side
> (`e/r_int_result` -> `dtlb/pa_reg` -- the AGU result reaching the D-side 48-way CAM), still
> route-dominated (**70%**). The mem-pipe CACHE hit-ops (D Hit-WB/Inval now translate through the
> dtlb like loads -- fixes IRIX `vfs_mountroot` EWRONGFS) added ~2.9K synth LUTs but closed at
> +0.147 ns.

### LUT breakdown by hierarchy

From `report_utilization -hierarchical` on the **synthesized** netlist (`synth_1.dcp`). These are
synth **Total LUTs** (pre-route, includes SRLs) = **63,480**; post-route packing lands them at the
62,320 CLB LUTs above. Regenerate with:

```tcl
open_checkpoint <run>/synth_1/ultra96v2_oob_wrapper.dcp
report_utilization -hierarchical -hierarchical_depth 20 -file util_hier.rpt
```

**Top level -- 63,480 LUTs = 90.0% of the 70,560-LUT device.** The r9999 CPU (core + all caches)
is **93.7%** of the design; the SoC/AXI/PS glue is the remaining ~6%.

| block | module | Total LUTs | Logic | LUTRAM | FFs | % design |
|-------|--------|-----------:|------:|-------:|----:|---------:|
| OOO core | `core` | 42,647 | 40,996 | 1,464 | 21,255 | **67.2%** |
| I-cache | `l1i` | 10,091 | 10,083 | 8 | 6,973 | 15.9% |
| D-cache | `l1d` | 5,131 | 5,051 | 80 | 1,360 | 8.1% |
| L2 cache | `l2` | 1,596 | 1,596 | 0 | 517 | 2.5% |
| AXI shim | `axi_is_the_worst` | 1,430 | 1,445 | 0 | 2,536 | 2.3% |
| IP22 devices | hpc3·mc·ioc·scsi | 1,292 | 1,208 | 84 | 2,051 | 2.0% |
| Zynq PS + interconnect | Xilinx IP | 1,247 | 1,166 | 40 | 999 | 2.0% |
| SoC glue | `henry_soc` | 46 | 22 | 8 | 152 | 0.1% |

IP22 devices pooled: hpc3 223 · mc 274 · ioc 176 · scsi (shim 245 + beat_fifo 150 + dma 224 = 619).

**Inside the OOO core -- 42,647 LUTs** (grouped compute / storage / control):

| unit | module | Total LUTs | % core | group |
|------|--------|-----------:|-------:|-------|
| exec datapath · CP0 · int scheduler | `exec` (own) | 15,362 | 36.0% | compute |
| core control · ROB · rename · retire | `core` (own) | 11,654 | 27.3% | control |
| integer register file | `rf4r2w` | 4,986 | 11.7% | storage |
| select encoders (×5) | `find_first_set` | 4,756 | 11.2% | control |
| FP register file | `fp_regfile` | 3,032 | 7.1% | storage |
| FPU (add 687 · mul 511 · f2i 138 · ctl) | `fpu` | 1,575 | 3.7% | compute |
| integer divider | `divider` | 732 | 1.7% | compute |
| integer multiplier | `mul` | 480 | 1.1% | compute |

**Area targets (ranked):**
1. **A single `find_first_set` = 4,180 LUTs** (of the 4,756 in the ×5 group) -- an oversized priority
   select (scheduler oldest-ready / ROB). The clearest *synth-level* win: a re-architected priority
   mux or different inference could reclaim a chunk with zero uarch change.
2. **Register files = 8,018 LUTs = 12.6% of the whole design** (int `rf4r2w` 4,986 + FP `fp_regfile`
   3,032), all distributed-RAM ports. The FP RF exists only for IRIX's N32 FPU -- a lever for a
   no-FP variant. (The clustered `fp_regfile` already landed the big FP-RF area win; the int
   `rf4r2w` is the next candidate for the same banked/registered-read treatment.)
3. **Micro-ITLB CAM = 3,989 LUTs** (`l1i/itlb`) -- why the I-side (10.1K) is fatter than the D-side
   (5.1K). The "always-miss v1" CAM is latency-only (uses the real 48-entry JTLB for translation) and
   never earned its area; finishing or reverting it is pure area.
4. `exec` matrix scheduler + banked ROB -- both on the standing area-reduction plan.

## 2026-06-24 -- SCC ioc.sv control-write fix (FP-complete core; Explore P&R + post-route phys_opt)

| metric | value |
|--------|-------|
| WNS @ 100 MHz | **+0.235 ns** (all met, 0 failing endpoints) |
| Worst path | `cpu/icache/pd_data/r_ram_reg_bram_0` -> `cpu/icache/itlb/pa_reg[35]` |
| Data path delay | 9.479 ns  (logic 3.408 ns / **36.0%**, route 6.071 ns / **64.0%**) |
| Logic levels | 28  (CARRY8=2 LUT6=14 LUT5=7 LUT4=1 LUT3=1 LUT2=1 MUXF7=1 MUXF8=1) |
| CLB LUTs | 59122 (83.79%) |
| LUT as Logic | 57348 (81.28%) |
| LUT as Memory (LUTRAM) | 1774 (6.16%) |
| CLB Registers (FF) | 33789 (23.94%) |
| Block RAM | 23 |
| DSP | 43 |

**Path shape** (predecode BRAM -> look-ahead PC -> TLB CAM hit-compare -> ITLB `pa_reg`):

```
 RAMB18E2 DOUTADOUT (icache/pd_data)  +0.964  -> r_jump_out / r_cache_pc / fetch-queue / PHT LUTs
 -> r_cache_pc[51]_i_{3,2,1}          (next-PC select)
 -> r_la_pc[35]_i_{7,6,3,2,1}         (look-ahead PC = mipsseg(n_cache_pc), combinational)
 -> net dtlb/w_la_pc[19]  fo=50, route 0.841 ns   <-- one VPN bit to all 48 CAM entries
 -> dtlb hit_i_479 -> CARRY8 hit chain (48-way FA match) -> pa_reg PFN mux -> itlb/pa_reg[35]/D
```

**Why this stays the worst path:** the look-ahead PC feeding the CAM is the **combinational**
wire `w_la_pc` (`l1i.sv:475/499`), computed *and* matched against the 48-way CAM in one cycle.
The high-fanout net (`fo=50`) is one VPN bit reaching all 48 entries -- inherent to a fully-
associative CAM. Vivado can't auto-fix it: register **duplication** only targets *flops*, and
`w_la_pc` is a LUT cone (the flop `r_la_pc` feeds the *other*, next-cycle path); forced LUT
replication can't help because an FA CAM's loads are irreducibly spread. The structural fixes
are to **register `w_la_pc` before the TLB** (pipeline fetch->translate; makes it a replicable
flop *and* cuts the path, at +1 fetch cycle) or the **micro-TLB** (small clustered cache in
front of each JTLB CAM). See [SCC implementation](peripherals/scc.md) for the IOC change.

> **Not apples-to-apples with the pre-FP blocks below:** this is the **FP-complete core** (COP1
> FPU: LUT-as-logic ~50K -> 57K, DSP 34 -> 43 for the FP multiplier) plus the SCC `ioc.sv`
> control-write fix (timing-neutral -- a mux in the IOC, far from the TLB). The first
> default-strategy P&R of this netlist came out at **WNS -0.812** -- the marginal CAM path
> losing the placement lottery on a tiny netlist perturbation -- and re-rolling with **Explore
> place+route + post-route phys_opt** recovered **+0.235 ns**. The design is at the timing margin.

## 2026-06-20 -- aadb09f (TLB PFN narrowed to PA_WIDTH-12; + BEV-base fix + VA-range AdEL)

| metric | value |
|--------|-------|
| WNS @ 100 MHz | **+0.254 ns** (all constraints met) -- **+0.189 ns vs the 9bf1224 baseline** |
| Worst path | `cpu/icache/tag_array/r_ram_reg` -> `cpu/icache/itlb/pa_reg[35]` |
| Data path delay | 9.299 ns  (logic 3.534 ns / **38.0%**, route 5.765 ns / **62.0%**) |
| Logic levels | 30  (CARRY8=3 LUT2=1 LUT4=5 LUT5=4 LUT6=15 MUXF7=1 MUXF8=1) |
| CLB LUTs | 50786 (71.98%)  (+472 vs baseline -- BEV/VA-range/AdEL logic) |
| LUT as Memory (LUTRAM) | 1154 (4.01%) |
| CLB Registers (FF) | 36105 (25.58%)  (**-402 vs baseline** -- the narrowed TLB array) |
| Block RAM | 23 |
| DSP | 34 |

Still the route-dominated icache->ITLB->`pa_reg` path, but the smaller `r_tlb` array
(PFN 28->24b, -402 FF) cut the data path 9.701->9.299 ns and bought **+0.189 ns WNS** --
area-for-timing on a route-bound path, as hypothesized. Next levers: micro-TLB in
front of the JTLB, or narrowing other per-entry fields (dead `pagemask`, redundant
`entry`).

## 2026-06-19 -- 9bf1224 baseline (C-bit cacheability + user/sup/kernel AdEL + SCC Rx wrapper)

| metric | value |
|--------|-------|
| WNS @ 100 MHz | **+0.065 ns** (all constraints met) |
| Worst path | `cpu/icache/pd_data/r_ram_reg_bram_0` -> `cpu/icache/itlb/pa_reg[21]` |
| Data path delay | 9.701 ns  (logic 3.556 ns / **36.7%**, route 6.145 ns / **63.3%**) |
| Logic levels | 31  (CARRY8=2 LUT2=5 LUT3=2 LUT4=4 LUT5=7 LUT6=9 MUXF7=1 MUXF8=1) |
| CLB LUTs | 50314 (71.31%) |
| LUT as Memory (LUTRAM) | 1162 (4.03%) |
| CLB Registers (FF) | 36507 (25.87%) |
| Block RAM | 23 |
| DSP | 34 |
