#!/usr/bin/env bash
# fpga_stats.sh -- parse Vivado impl reports into a markdown stats block for
# docs/fpga_stats.md.  Run after a synth (rebuild_henry.tcl writes the two
# reports to ~/):
#
#   ./fpga_stats.sh [timing_summary.rpt] [utilization.rpt] >> docs/fpga_stats.md
#
# Defaults to the paths rebuild_henry.tcl emits.
set -u
TIM="${1:-$HOME/timing_after.rpt}"
UTIL="${2:-$HOME/util_after.rpt}"
[ -f "$TIM" ]  || { echo "no timing report: $TIM"  >&2; exit 1; }
[ -f "$UTIL" ] || { echo "no util report: $UTIL"   >&2; exit 1; }

# strip the boilerplate instance prefix from a netlist path
shorten() { sed -E 's#.*/inst/henrysoc0/##; s#/[A-Z0-9]+$##'; }

# --- timing ---------------------------------------------------------------
wns=$(awk '/ *WNS\(ns\)/{getline;getline;print $1;exit}' "$TIM")
met=$(grep -m1 -oiE "All user specified timing constraints are met|Timing constraints are NOT met" "$TIM")
slack=$(grep -m1 "Slack (" "$TIM" | sed -E 's/.*: *//; s/ .*//')
src=$(grep -m1 "Source:"      "$TIM" | sed -E 's/.*Source: *//'      | shorten)
dst=$(grep -m1 "Destination:" "$TIM" | sed -E 's/.*Destination: *//' | shorten)
dpd=$(grep -m1 "Data Path Delay:" "$TIM" | sed -E 's/.*Data Path Delay: *//')
lvl=$(grep -m1 "Logic Levels:"    "$TIM" | sed -E 's/.*Logic Levels: *//')

# --- utilization (| name | used | fixed | prohibited | avail | % |) -------
u() { grep -m1 "| $1 " "$UTIL" | awk -F'|' '{gsub(/ /,"",$3);gsub(/ /,"",$7);print $3" ("$7"%)"}'; }
lut=$(u "CLB LUTs"); lutram=$(u "LUT as Memory"); ff=$(u "CLB Registers")
bram=$(grep -m1 "| Block RAM Tile " "$UTIL" | awk -F'|' '{gsub(/ /,"",$3);print $3}')
dsp=$(grep -m1 "| DSPs " "$UTIL" | awk -F'|' '{gsub(/ /,"",$3);print $3}')

cat <<EOF

## $(date +%Y-%m-%d) ($(git -C "$(dirname "$0")/r9999" rev-parse --short HEAD 2>/dev/null) core)

| metric | value |
|--------|-------|
| WNS @ 100 MHz | **${wns} ns** ($met) |
| Worst path | \`${src}\` -> \`${dst}\` |
| Data path delay | ${dpd} |
| Logic levels | ${lvl} |
| CLB LUTs | ${lut} |
| LUT as Memory (LUTRAM) | ${lutram} |
| CLB Registers (FF) | ${ff} |
| Block RAM | ${bram} |
| DSP | ${dsp} |
EOF
