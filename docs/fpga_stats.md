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
