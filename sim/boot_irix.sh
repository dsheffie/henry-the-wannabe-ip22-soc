#!/usr/bin/env bash
# boot_irix.sh -- boot IRIX 6.5 (/unix) on the henry SoC Verilator testbench.
#
# Builds henry_tb if needed, then boots /unix via the henry_arcs FSBL with the
# IRIX root disk attached -- mirrors the FPGA path (--start-pc = the PROM reset
# vector; the FSBL hands off to the kernel).
#
# CAVEAT: the RTL sim's CP0 timer is CYCLE-paced, so the scheduler tick lands
# ~1M cycles apart and the kernel parks in <idler> long before the IRIX banner --
# a *full* boot is impractical in Verilator. interp_mips (insn-paced Count +
# FASTDELAY, see interp_mips/boot_irix.sh) is the vehicle for a full IRIX boot.
# This script is mainly to exercise the SCSI/DMA engine against the real kernel.
#
#   Usage:  ./boot_irix.sh [extra henry_tb args]
#   e.g.    ./boot_irix.sh --maxcyc 200000000
#   Env:    KERNEL=, ARCS=, DISK=, MAXCYC=   override the defaults
#           RAW=1     show raw output (default: filter the core debug $display floods)
#           SCSIDBG=0 silence the [scsi]/[sdma] engine trace (default on)
set -eu

SIM_DIR="$(cd "$(dirname "$0")" && pwd)"
KERNEL=${KERNEL:-/home/dsheffie/code/chd-dumper/extracted/unix}
ARCS=${ARCS:-/home/dsheffie/code/r9999/arcs/henry_arcs.bin}
DISK=${DISK:-/home/dsheffie/code/iris/irix65-clean.img}
MAXCYC=${MAXCYC:-60000000000}

for f in "$KERNEL" "$ARCS" "$DISK"; do
  [ -f "$f" ] || { echo "[boot_irix] not found: $f" >&2; exit 1; }
done

cd "$SIM_DIR"
make -s

echo "[boot_irix] kernel=$KERNEL"
echo "[boot_irix] arcs=$ARCS"
echo "[boot_irix] disk=$DISK  maxcyc=$MAXCYC"

export SCSIDBG=${SCSIDBG:-1}
CMD=(./obj_dir/henry_tb --kernel "$KERNEL" --arcs "$ARCS" --start-pc 0xbfc00000 \
     --disk "$DISK" --maxcyc "$MAXCYC" "$@")

if [ "${RAW:-0}" = "1" ]; then
  exec "${CMD[@]}"
else
  # Drop the high-volume live-core debug $display floods (l2->dram / creq / dram /
  # hpc3acc / mode / soc-dev / la) for readable + faster output. Keeps the console,
  # [tb] markers, and [scsi]/[sdma] engine activity.
  "${CMD[@]}" 2>&1 | grep --line-buffered -vE "l2->dram|creq|dram\]|desc l2|hpc3acc|\[mode\]|soc-dev|\[la\]"
fi
