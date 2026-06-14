# Henry — the wannabe IP22 SoC

A from-scratch FPGA/RTL **System-on-Chip** that impersonates the SGI **Indy** (board code **IP22**) closely
enough to boot **IRIX 6.5.22**, built around the **r9999** MIPS R4000-class core.

> **Why "Henry"?** The Indy is named for **Indiana Jones**, whose real name is **Henry** (Walton Jones Jr.;
> "Indiana" was the dog). Henry answers to a name that isn't quite its own — a *wannabe* IP22.

This repo is **documentation-first**: the [`docs/`](docs/) tree is the platform specification (address map,
per-block register interfaces + "minimum to boot," the ARCS firmware shim, the boot/console contract, the
cache/coherence/TLB rules). The RTL (`rtl/`) and co-simulation harness (`sim/`) are built *against* that spec,
and validated against **MAME** booting the real Indy IRIX image (Henry's golden reference model).

## Layout

```
henry-the-wannabe-ip22-soc/
├── docs/            # the platform spec (see docs/index.md) — mkdocs site
│   ├── peripherals/ #   one spec per block: mc, ioc2, hpc3, gio64, vdma
│   └── ...          #   architecture, cpu-integration, firmware-arcs, boot-and-console,
│                    #   coherence-cache-tlb, methodology
├── r9999/           # git submodule — the CPU core (+ its detailed MAME working notes)
├── rtl/             # (future) peripheral RTL + the SoC top, instantiating r9999
├── sim/             # (future) cosim/diff against MAME; per-block test harnesses
└── mkdocs.yml
```

## Getting it

```sh
git clone --recurse-submodules <this-repo>
# or, after a plain clone:
git submodule update --init --recursive
```

## Reading / building the docs

The docs are plain Markdown — read them directly starting at [`docs/index.md`](docs/index.md), or build the
website:

```sh
pip install mkdocs            # (theme: built-in readthedocs; or `pip install mkdocs-material` and set theme.name: material)
mkdocs serve                 # live preview at http://127.0.0.1:8000
mkdocs build                 # static site → site/
```

## Status

First-pass foundation in place: all five core peripheral specs (MC, IOC2, HPC3, GIO64, VDMA) plus the
cross-cutting docs (architecture, CPU integration, firmware/ARCS, boot & console, cache/coherence/TLB,
methodology), drawn from the SGI IP22 chip documents and validated against MAME. Not yet done: `dmux1`, the
Newport graphics set, audio (HAL2), and the actual RTL/sim. The r9999-side detailed working notes
(`IRIX_CPU_REQUIREMENTS.md`, `IRIX_KERNEL_GAPS.md`, `IP22_CHIP_REGISTERS.md`, `MAME_QUESTIONS.md`) live in the
[`r9999/`](https://github.com/dsheffie/r9999) submodule.
