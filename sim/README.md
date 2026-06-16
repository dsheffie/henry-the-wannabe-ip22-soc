# Henry SoC simulation

Verilator harness that boots a kernel on the Henry IP22 SoC (`rtl/henry_soc.sv`),
which wraps the r9999 core (`core_l1d_l1i`) and inlines RTL models of the
boot-critical IP22 devices (MC, HPC3/IOC2, SCC), translated from the r9999 C++
functional models.

## Build & run

```sh
make build                                   # Verilate henry_soc + the r9999 core + tb
make run                                      # boot /unix with arcs_irix.bin
make run KERNEL=foo.elf ARCS=blob MAXCYC=... # boot something else
```

`R9999` (default `/home/dsheffie/code/r9999`) points at the core sources. The
in-repo `r9999/` submodule is the intended source once it's updated to a current
`main`.

## What the harness provides

- **Behavioral RAM** on the SoC's external memory bus. The MC/HPC/SCC devices now
  live in RTL inside `henry_soc`, so the external bus is pure memory — the harness
  just services 16-byte line loads (`opcode==4`) and masked stores, matching the
  r9999 `top.cc` protocol.
- **BE-ELF32 loader** for the IRIX `/unix` kernel (entry `0x88005960`), plus the
  ARCS System Parameter Block blob at physical `0x1000`.
- The core **resume handshake** to launch at the kernel entry.
- **Console**: the SCC UART TX and the core's CP0-reg7 putchar stream are merged
  in `henry_soc` onto the existing `putchar_fifo_*` port; the harness drains it to
  stdout, so the IRIX serial banner appears here.
- A magic-halt store (`0xBFD00000`) stops the run; otherwise it runs `--maxcyc`.

The core's instrumentation/co-sim DPI hooks (`record_*`, `report_exec`,
`check_insn_bytes`) are stubbed in the testbench — this is an RTL-only run, no
interpreter co-sim.

## Memory map (decoded in `henry_soc`)

| Region | Phys range            | Handled by            |
|--------|-----------------------|-----------------------|
| MC     | `0x1fa00000`–`1fafffff` | inline RTL (sgi_mc)  |
| SCC    | `0x1fbd9830`–`1fbd983f` | inline RTL (sgi_scc) |
| HPC/IOC2 | `0x1fb80000`–`1fbfffff` | inline RTL (sgi_hpc) |
| everything else | —            | external bus → RAM    |
