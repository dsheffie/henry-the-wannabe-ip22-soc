#!/usr/bin/env bash
# run_go_unbounded.sh -- boot IP22 Linux (+ the go benchmark) on the henry SoC
# Verilator testbench with NO practical instruction/cycle bound.  Runs until the
# guest halts (magic-halt store), the sim hits $finish, or you Ctrl-C.
#
# henry_tb's main loop terminates on:  cyc >= max_cyc  ||  (max_icnt && retired>=max_icnt)
#   || halted || $finish.  So "unbounded instructions" = max_icnt 0 (unlimited,
#   the default) + a max_cyc set far beyond any real boot.  At ~1e5 cyc/s under
#   Verilator, the 1e12 ceiling below is ~4 months of wall clock -- i.e. never
#   the limiting factor; you'll Ctrl-C or hit a halt long before.
#
#   Usage:   ./run_go_unbounded.sh [extra henry_tb args]
#   Env:     KERNEL= ARCS= MAXCYC=   to override.
#   Log it:  ./run_go_unbounded.sh 2>&1 | tee /tmp/go_unbounded.log
set -eu

SIM_DIR="$(cd "$(dirname "$0")" && pwd)"
KERNEL=${KERNEL:-/home/dsheffie/code/linux-mips/vmlinux.32}
ARCS=${ARCS:-/home/dsheffie/code/r9999/arcs/henry_arcs.bin}
MAXCYC=${MAXCYC:-1000000000000}   # 1e12 cycles == effectively unbounded

[ -f "$KERNEL" ] || { echo "[run_go] kernel not found: $KERNEL" >&2; exit 1; }
[ -f "$ARCS" ]   || { echo "[run_go] arcs blob not found: $ARCS"   >&2; exit 1; }

# Rebuild henry_tb so the run always reflects the current r9999 core sources
# (the Makefile depends on $(R9999)/*.sv, but rm -rf obj_dir guarantees no stale
# Verilated object slips through -- cheap insurance for a long run).
cd "$SIM_DIR"
make -s

echo "[run_go] kernel=$KERNEL"
echo "[run_go] arcs=$ARCS"
echo "[run_go] UNBOUNDED: maxcyc=$MAXCYC  maxicnt=0 (unlimited insns)  -- Ctrl-C to stop"

exec ./obj_dir/henry_tb --checker --kernel "$KERNEL" --arcs "$ARCS" --start-pc 0xbfc00000 \
     --maxcyc "$MAXCYC" "$@"
