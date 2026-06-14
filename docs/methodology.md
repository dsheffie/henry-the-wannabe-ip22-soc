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

## Source material

- MAME (the oracle): `~/code/mame` (v0.287), Indy `indy_4610` + the IRIX 6.5.22 CHD.
- SGI chip docs: `~/code/sgi/docs/arcs_spec.pdf`, `~/code/sgi/docs/indy_docs/ip22/{mc,ioc,hpc3,gio64,vdma,dmux1}.pdf`.
- The symbolized IRIX kernel: `~/code/chd-dumper/extracted/unix` (ELF, with symbols).
- The r9999 working notes (in the submodule): `IRIX_CPU_REQUIREMENTS.md`, `IRIX_KERNEL_GAPS.md`,
  `IP22_CHIP_REGISTERS.md`, `MAME_QUESTIONS.md`.
