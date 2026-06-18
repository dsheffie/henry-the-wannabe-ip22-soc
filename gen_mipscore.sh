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
