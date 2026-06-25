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
