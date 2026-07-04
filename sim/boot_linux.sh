#!/usr/bin/env bash
# boot_linux.sh -- boot IP22 Linux on the henry SoC Verilator testbench.
#
# Builds henry_tb and the Linux ARCS firmware (arcs_linux.bin) if needed, then
# boots vmlinux.32. The kernel must be built with console=arc (CONFIG_CMDLINE)
# for visible output -- console=ttyS0 produces nothing on henry. arcs_linux's
# memory descriptor reports 128 MiB as free (Type 2); arcs_irix's would panic.
#
#   Usage:  ./boot_linux.sh [extra henry_tb args]
#   e.g.    ./boot_linux.sh --maxcyc 90000000 --trace /tmp/lin.trace
#   Env:    KERNEL=, ARCS=, MAXCYC=  to override the defaults.
set -eu

SIM_DIR="$(cd "$(dirname "$0")" && pwd)"
KERNEL=${KERNEL:-/home/dsheffie/code/linux-mips/vmlinux.32}
ARCS=${ARCS:-/home/dsheffie/code/r9999/arcs/henry_arcs.bin}
MAXCYC=${MAXCYC:-200000000}

# Build the Linux ARCS firmware blob if missing (from arcs_linux.S via its Makefile).
if [ ! -f "$ARCS" ] && [ -d "$(dirname "$ARCS")" ]; then
  echo "[boot_linux] building $(basename "$ARCS") ..."
  make -C "$(dirname "$ARCS")" "$(basename "$ARCS")"
fi
[ -f "$KERNEL" ] || { echo "[boot_linux] kernel not found: $KERNEL" >&2; exit 1; }
[ -f "$ARCS" ]   || { echo "[boot_linux] arcs blob not found: $ARCS" >&2; exit 1; }

cd "$SIM_DIR"
make -s

echo "[boot_linux] kernel=$KERNEL"
echo "[boot_linux] arcs=$ARCS  maxcyc=$MAXCYC"
# --start-pc 0xbfc00000 = the Boot PROM reset vector: run the ARCS first-stage
# boot loader (FSBL), which copies the SPB into RAM and jumps to the kernel
# (matches the FPGA path). Omit it to use the legacy C++ install_arcs_handoff.
exec ./obj_dir/henry_tb --kernel "$KERNEL" --arcs "$ARCS" --maxcyc "$MAXCYC" --start-pc 0xbfc00000 "$@"
