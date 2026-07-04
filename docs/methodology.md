---
title: Methodology — MAME as the golden oracle
status: stable
---

# Methodology — MAME as Henry's golden oracle

Every fact in this spec was derived by driving **real IRIX 6.5.22 booting on the SGI Indy in MAME**, not from
datasheets alone. MAME is Henry's **golden reference model**: it runs the actual PROM + kernel, so it tells us
what IRIX *actually* requires (vs. what's merely architecturally possible), and the values it produces are the
**block-level test vectors** Henry's RTL is checked against. This page is the reproducible recipe.

## The headless harness

- **Run the local instrumentable build:** `~/code/mame/mame` (the system `/usr/games/mame` is *not* the
  checkout). Launch from the IRIX image dir so relative paths + nvram resolve.
- **Headless requires SDL dummy drivers** — without them SDL tries DRM/KMS and dies:
  ```sh
  SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy ~/code/mame/mame indy_4610 \
    -gio64_gfx xl24 -hard1 irix65.chd -rompath indy_4610/ -nodrc \
    -video none -sound none -nothrottle -seconds_to_run N -autoboot_script probe.lua
  ```
  `-nodrc` = the interpreter (instrumentable). The Indy core is `r4600be(:maincpu)` (the legacy `mips3.cpp`),
  which is fine — IRIX's CPU usage is the same at the level we care about.
- **Drive it with Lua (`-autoboot_script`), not the in-tree debugger** — the debugger is unusable headless
  (segfaults / no output). Lua `io.write`/`print` go to stdout; CPU state is `cpu.state["NAME"].value`
  (PC, all GPRs, CP0 EntryHi/Lo/Index/Wired/Count/Compare/Cause, FCR31, FPRs…); MMU-translated memory reads
  are `cpu.spaces["program"]:readv_u32/u8(addr)` (the non-`v` variants read raw and return junk for kseg).

## Exact single-instruction breakpoints (the workhorse)

Lua + the debugger *core* (`-debug -debugger none`) gives precise PC traps without a display:

```lua
local dbg = manager.machine.debugger
cpu.debug:bpset(0x88005960, "1", "")     -- 3 args required; fewer SEGFAULTS the binding
-- in register_periodic: if dbg.execution_state == "stop" then read state; dbg.execution_state = "running"
```

Caveats learned the hard way: `execution_state` reads `"stop"` (not `"stopped"`); the periodic still fires
while paused; poll-resume adds **~16 ms wall per hit**, so never breakpoint high-frequency sites. **Register
reads at a *watchpoint* (mid-instruction) are stale** — use single-step + read PC, or read CP0 (those are
reliable). This is how the wirepda/wired-TLB question was answered.

## C++ instrumentation (for high-volume counts + device capture)

For things Lua can't do at speed — opcode/cache histograms, device-traffic capture — patch the MAME source
and rebuild incrementally (`cd ~/code/mame && make -j$(nproc)`; ~1–2 min relink). Pattern = a file-static
counter/buffer + a hook at the handler + an `fprintf(stderr,…)` dump. Hooks used this session (uncommitted in
the MAME tree):

| File | Hook | Yields |
|---|---|---|
| `src/devices/cpu/mips/mips3.cpp` | counter on `case 0x2f /*CACHE*/` + `case 0x11 /*COP1*/`, dumped in `device_stop()` | the **cache-op histogram** (5.2M ops/boot) and the COP1 histogram |
| `src/mame/sgi/ioc2.cpp` | `scc_dc_w` wrapper on the SCC `ab_dc` write | **serial-console capture** (the `du_putchar` → Z8530 TX stream) |

The serial capture is what proved the console path; `null_modem` + `-bitb` captured **0 bytes** (baud/port
ambiguity), so the C++ SCC hook is the reliable headless serial sink. Getting serial at all also needs
`console=d` in the PROM nvram (`setenv -f console d`, a one-time GUI step).

## How a Henry block gets validated

1. **Spec** the block from the SGI doc (cross-checked, ✅/⚠️-tagged against MAME).
2. **Capture golden vectors** from MAME — the values IRIX reads/writes during boot. Examples already captured:
   `MEMCFG0 = 0x23200000` (→ 16 MB bank @ `0x08000000`); the SPB bytes at phys `0x1000` (sig "ARCS", the
   35-entry romvec addresses); the wired PDA TLB entry (`EntryHi=0xFFFFA000 → 0x0838E000`, global, slot 0,
   Wired=8); the SCC TX byte stream; the FR=1 transitions; the per-boot cache-op histogram.
3. **Implement** the block in `rtl/` against the spec.
4. **Co-simulate / diff** against MAME booting the same IRIX image: same instruction stream, same device
   register reads/writes, same console output. Divergence localizes the bug (this is exactly how the wirepda
   "real HW takes no miss → r9999 faults spuriously" conclusion was reached).

## Boot bring-up order (what to make work, in order)

1. **CPU + RAM + the ARCS shim** → reach `/unix` `start` (a0=8) without the early UTLB-miss panic (needs
   `eaddr` set). See [Firmware](firmware-arcs.md), [Boot & console](boot-and-console.md).
2. **MC MEMCFG** → `szmem` sizes RAM correctly. See [MC](peripherals/mc.md).
3. **IOC2 minimal SCC** → "IRIX is alive" on the serial console. See [IOC2](peripherals/ioc2.md).
4. **Cache ops honored** (not NOP'd) → code coherence + DMA correctness. See
   [Cache, coherence & TLB](coherence-cache-tlb.md).
5. **HPC3 SCSI + WD33C93** → read the root disk. See [HPC3](peripherals/hpc3.md).
6. GIO64 bus-errors empty slots → IRIX skips graphics cleanly. See [GIO64](peripherals/gio64.md).

## Chasing a bug on silicon — HW watchpoint + the ISS diff

MAME-as-oracle only helps when the bug reproduces in MAME. When it only shows up **on the FPGA** — a
sim/synth timing hazard, or (as here) IRIX wedging somewhere MAME never reaches — you have to catch state
*on the running part*. The workflow that cracked the IRIX `bad istack` panic:

**1. Freeze the pipeline at the offending instruction (core.sv).** Reuse the single-step gate: a
breakpoint/watchpoint that latches a "hit" flop and folds it into `w_step_ok`, so the core **stops retiring
without a reset** — the register file and DRAM stay coherent at the moment of interest.

```verilog
// PC breakpoint: freeze after retiring BP_PC.  VALUE watchpoint: freeze after a
// retiring insn writes a target value into a target reg (here $29/sp).
wire w_wp_match = bp_enable &
  ((retire_reg_valid     & (retire_reg_ptr==5'd29) & ((retire_reg_data[31:0]&WP_MASK)==WP_VAL)) |
   (retire_reg_two_valid & (retire_reg_two_ptr==5'd29) & ((retire_reg_two_data[31:0]&WP_MASK)==WP_VAL)));
wire w_step_ok = (r_single_step | r_bp_hit | r_wp_hit) ? t_step_edge : 1'b1;  // no step edge -> frozen
```

- **Timing trap:** compare the *flopped* retire outputs (`retire_reg_data/ptr/valid`), **not** the
  combinational ROB head — the ROB-head read is already the near-critical retire path, and a 32-bit masked
  compare hung off it cost **WNS −3.6 ns**. Registering it (flop→logic→flop) closes timing at the price of
  the freeze landing ~1–2 instructions late (disassemble the window). Adding a probe *moves the critical
  path* — classic bring-up.

**2. Read the state out (driver, over AXI-Lite).** With the core frozen (not reset) the debug reads are
coherent: `read32(7)`=last PC, `read32(0xb)`=CP0 EPC, `read32(0x26)&31`=Cause, and the GPRs via
`write32(14,i); read32(0xe)` (a shadow register file rebuilt from the retire stream).
- **Gotcha that cost a synth:** the henry AXI wrapper dropped `retire_reg_valid` end-to-end (henry_soc
  connected it empty; the wrapper tied `w_reg_val*=1'b0` and never fed the S00_AXI `r_arch_regs` shadow), so
  every GPR read returned 0. Wire `retire_reg_valid`/`_two_valid` out of henry_soc → into the shadow.

**3. Read guest DRAM (`devmem`).** The driver mmaps guest RAM at host phys `0x5ff00000`, so
`host = 0x5ff00000 + guest_pa` (the PROM at guest `0x1fc00000` is specially relocated to `+0x10C00000`).
The guest is **big-endian**, so byte-swap `devmem`'s output. **Caveat:** only *flushed* memory is DRAM-visible
— a freshly written-back-cached word (e.g. a just-updated scheduler global) reads stale `0`. An old global
(the wired int-stack ptr at `0xFFFFA020`) reads correctly; a hot one (the idle-sp global `0xFFFFA164`) doesn't.

**4. Diff against the ISS (`interp_mips`) — the silicon's oracle.** interp_mips boots the *identical*
kernel+disk fast and correctly, so it tells you what a value *should* be. This is what turns "sp is
`0x8834afb8`" into "corrupted" vs "legitimate." Trace the same PC in the ISS (a temp hook in `interpret.cc`,
or `--gdb`), read the same global via its `va_translate`, and compare.
- `PRID=<val>` env override (added at `interpret.cc` PRId init) sweeps R4400↔R4600 without a rebuild.
- `PCTRACEOUT=<file>` dumps one PC per retired instruction. **ALWAYS bound it with `-m <icnt>`, never a
  wall-clock `timeout`** — a 50 s run traced 1.4 **billion** PCs → 12.8 GB/file → filled the disk and OOM'd
  the box. The divergence you want is usually in the first few million instructions anyway.

**Worked example — the `bad istack` chase.** The watchpoint (freeze when sp is written `0x8834a___`) fired
at `resumeidle+0x2c: lw sp,-24156(zero)` → sp=`0x8834afb8`, which *looked* like sp corruption into the PDA
region. But reading that idle-sp global (`mem[0xFFFFA164]`) in the **ISS** returned the **same** `0x8834afb8`
— so it's the *legitimate* idle-thread stack pointer, not corruption. Reframe: the FPGA can't mount root
(SCSI), gets **stuck in the idle thread**, the timer fires during idle (sp above the int-stack boundary), and
`VEC_int`'s int-stack-only exit rejects it → panic. The ISS never hits it because with a working disk it
mounts root and stays *busy*. **The value of the tooling wasn't finding a corruption — it was *definitively
ruling one out*,** redirecting the hunt from the CPU to the SCSI/root-mount path. (Full trail:
`~/.../memory/project_irix_boot.md`.)

**Reading FPGA timing/util after a probe:** the routed reports live in `…/<proj>.runs/impl_N/`
(`*_timing_summary_routed.rpt` WNS, `*_utilization_placed.rpt`). Grep the *fresh* one — the
`utilization_synth.rpt` is easy to misread if a prior run's copy is stale. Two knobs that bought timing
margin for the probe on a 94%-LUT-full die: **ALU matrix scheduler 8→4** (`LG_INT_SCHED_ENTRIES 3→2` — not
an area win since the FPU dominates the LUTs, but the O(N²) wakeup/select was *on the critical path*, so it
was a real WNS win) and **L2 1024→8 lines** (a BRAM knob, no LUT/correctness impact — caches are
non-inclusive so shrinking is safe).

## Related work

**Project CYAN** ([wiki.unix-haters.org](https://wiki.unix-haters.org/doku.php?id=sgimips:cyan))
is a from-scratch FPGA SoC of the SGI **Indigo IP20**, the board generation just
*before* Henry's Indy IP22. It's a sibling effort and the inspiration for this one, and it cross-checks
Henry from an independent direction.

- **haterMIPS** — CYAN's clean-room **R4000SC** core (8-stage R4000 pipeline, 48-entry TLB, 8 KB L1s +
  1 MB secondary cache, MIPS III + FPU; PRId `0x430`; verified vs Sail, cheritest, and the SGI PROM). It
  **independently corroborates** Henry's cache model: incoherent L1 + software `CACHE` flush for SMC, no
  snoop (see [Cache, coherence & TLB](coherence-cache-tlb.md)). Confirms `PageMask`-invalid → Machine
  Check `ExcCode=24` and the Wired/Random interaction too.
- **CYAN Express/Elan study** — the best open register-level reconstruction of the **GR2** graphics
  programming model (FIFO token interface, HQ2 registers, the `0xDEADBEEF` board probe, RE2/RE3 register
  map, from NetBSD `grtworeg.h` + MAME `sgi_re2`). Henry's [Express / XZ](graphics/express-xz.md) page
  borrows it for the Indy **GR4** equivalent.

**Different theses, deliberately.** CYAN aims for an **exact** SGI replica (precise R4000 microarchitecture).
Henry keeps only the **software-visible contract** IRIX/PROM probe (48-entry TLB, MIPS III, CP0, PRId,
`CACHE` semantics, phys-addr width) and is free to **modernize the microarchitecture** behind it (e.g. a
micro-TLB in front of the 48-entry JTLB to close timing — not something a faithful R4000 would have). Two
independent implementations triangulating the same under-documented machine is exactly why mining CYAN is
useful here: where CYAN and MAME agree, Henry's spec is on solid ground.

## Source material

- MAME (the oracle): `~/code/mame` (v0.287), Indy `indy_4610` + the IRIX 6.5.22 CHD.
- SGI chip docs: `~/code/sgi/docs/arcs_spec.pdf`, `~/code/sgi/docs/indy_docs/ip22/{mc,ioc,hpc3,gio64,vdma,dmux1}.pdf`.
- The symbolized IRIX kernel: `~/code/chd-dumper/extracted/unix` (ELF, with symbols).
- The r9999 working notes (in the submodule): `IRIX_CPU_REQUIREMENTS.md`, `IRIX_KERNEL_GAPS.md`,
  `IP22_CHIP_REGISTERS.md`, `MAME_QUESTIONS.md`.
