#!/usr/bin/env bash
# gen_mipscore.sh -- regenerate hdl/mipscore.v (the single Verilog file the
# ultra96v2-henry "axi_is_the_worst" IP synthesizes) from the henry SoC RTL
# (rtl/*.sv: henry_soc/mc/hpc3/ioc) + the r9999 core (r9999/*.sv), via sv2v.
#
# Run after editing any rtl/ or r9999/ .sv, then synth with
# ~/fpga/ultra96v2-henry/rebuild_henry.tcl (Vivado batch).
#
# Why a build dir: convert_sv_to_v.py globs *.sv in its CWD and sv2v must also
# see the headers (machine.vh/uop.vh/rob.vh), so we copy SoC + core sources AND
# headers into one dir. hdl/ is a symlink into the IP's hdl dir.
set -eu
ROOT="$(cd "$(dirname "$0")" && pwd)"

# --- keep the r9999 submodule current ---------------------------------------
# This script builds mipscore.v from the r9999 SUBMODULE working tree. A stale
# submodule pointer once silently shipped an OLD core to the FPGA (an l2.sv
# missing the UNCACHE_WB_TURNAROUND AXI fix -> Linux boot hang) while the sim
# used a newer tree -- a textbook sim/synth divergence that took a day to find.
# So: fast-forward the submodule to origin/main before building. If it has local
# modifications, warn and use as-is (never clobber WIP). Override with
# HENRY_NO_SUBMODULE_UPDATE=1. The submodule SHA is always echoed into the build.
SUB="$ROOT/r9999"
if [ -e "$SUB/.git" ]; then
  if [ "${HENRY_NO_SUBMODULE_UPDATE:-0}" = "1" ]; then
    echo "[gen_mipscore] submodule update SKIPPED (HENRY_NO_SUBMODULE_UPDATE=1)"
  elif ! git -C "$SUB" diff --quiet 2>/dev/null || ! git -C "$SUB" diff --cached --quiet 2>/dev/null; then
    echo "[gen_mipscore] WARNING: r9999 submodule has LOCAL changes -- using as-is, NOT updating" >&2
  else
    git -C "$SUB" fetch -q origin 2>/dev/null || echo "[gen_mipscore] WARNING: submodule fetch failed (offline?) -- using current checkout" >&2
    if [ -n "$(git -C "$SUB" rev-list -n1 HEAD..origin/main 2>/dev/null)" ]; then
      echo "[gen_mipscore] r9999 submodule was BEHIND origin/main -- fast-forwarding"
      git -C "$SUB" checkout -q origin/main
    fi
  fi
  echo "[gen_mipscore] r9999 submodule @ $(git -C "$SUB" rev-parse --short HEAD 2>/dev/null) -- $(git -C "$SUB" log -1 --format=%s 2>/dev/null | cut -c1-60)"
fi

BUILD="${BUILD:-/tmp/henry_mipscore_build}"
rm -rf "$BUILD"; mkdir -p "$BUILD"

cp "$ROOT"/rtl/*.sv   "$BUILD"/ 2>/dev/null || true
cp "$ROOT"/rtl/*.vh   "$BUILD"/ 2>/dev/null || true
cp "$ROOT"/r9999/*.sv "$BUILD"/ 2>/dev/null || true
cp "$ROOT"/r9999/*.vh "$BUILD"/ 2>/dev/null || true
cp "$ROOT"/r9999/convert_sv_to_v.py "$BUILD"/

echo "[gen_mipscore] $(ls "$BUILD"/*.sv | wc -l) .sv + $(ls "$BUILD"/*.vh 2>/dev/null | wc -l) .vh -> sv2v"
( cd "$BUILD" && python3 convert_sv_to_v.py )

[ -s "$BUILD/mipscore.v" ] || { echo "[gen_mipscore] ERROR: empty mipscore.v (sv2v failed?)" >&2; exit 1; }
cp "$BUILD/mipscore.v" "$ROOT"/hdl/mipscore.v
echo "[gen_mipscore] wrote hdl/mipscore.v ($(wc -c < "$ROOT"/hdl/mipscore.v) bytes)"
echo "[gen_mipscore] modules: $(grep -oE 'module (henry_soc|ioc|mc|hpc3|core_l1d_l1i)' "$ROOT"/hdl/mipscore.v | sort -u | tr '\n' ' ')"
