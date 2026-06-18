# Headless rebuild: pick up the freshly-copied mipscore.v in the axi_is_the_worst
# user IP, regenerate the BD, then synth+impl to a bitstream. Commands mirror what
# the GUI logged in vivado.jou, so it's the real update flow (no guessing).
# Usage:  vivado -mode batch -source rebuild.tcl -tclargs [impl_run]
set proj   /home/dsheffie/fpga/ultra96v2-henry/BASELINE_2022.2/ultra96v2_oob.xpr
set bd     /home/dsheffie/fpga/ultra96v2-henry/BASELINE_2022.2/ultra96v2_oob.srcs/sources_1/bd/ultra96v2_oob/ultra96v2_oob.bd
set ipinst ultra96v2_oob_axi_is_the_worst_0_0

open_project $proj
if {$argc >= 1} { set run [lindex $argv 0] } else { set run [get_property NAME [current_run -implementation]] }
puts "### rebuild: impl run = $run"

update_ip_catalog -rebuild -scan_changes
upgrade_ip -vlnv user.org:user:axi_is_the_worst:1.0 [get_ips $ipinst] -log ip_upgrade.log
generate_target all [get_files $bd]
export_ip_user_files -of_objects [get_files $bd] -no_script -sync -force -quiet
update_compile_order -fileset sources_1

# --- ipshared stale-cache guard ---------------------------------------------
# generate_target frequently reports the BD "up-to-date" and does NOT refresh
# the cached copy of the IP HDL under <proj>.gen/.../ipshared/<hash>/hdl/.  When
# that happens synth/impl silently build STALE RTL (this cost a 37-min run + a
# bogus result).  Force every cached HDL file to match the IP-repo source and
# hard-abort if any still differs.  See the fpga_ipshared_stale note.
set ip_hdl /home/dsheffie/fpga/ultra96v2-henry/ip_repo/axi_is_the_worst_1_0/hdl
set gendir /home/dsheffie/fpga/ultra96v2-henry/BASELINE_2022.2/ultra96v2_oob.gen/sources_1/bd/ultra96v2_oob/ipshared
set nrefresh 0
foreach cached [glob -nocomplain $gendir/*/hdl/*.v] {
    set src $ip_hdl/[file tail $cached]
    if {![file exists $src]} { continue }
    if {[catch {exec cmp -s $src $cached}]} {
	puts "### ipshared guard: REFRESHING stale [file tail $cached]"
	file copy -force $src $cached
	incr nrefresh
    }
    if {[catch {exec cmp -s $src $cached}]} {
	puts "### ipshared guard: FATAL -- $cached != $src after refresh; aborting"
	exit 1
    }
}
puts "### ipshared guard: OK (refreshed $nrefresh stale file(s))"

reset_run synth_1
launch_runs $run -to_step write_bitstream -jobs 12
wait_on_run $run

open_run $run
report_utilization    -file /home/dsheffie/util_after.rpt
report_timing_summary -max_paths 10 -file /home/dsheffie/timing_after.rpt
puts "### rebuild DONE: run=$run  bit + reports (/home/dsheffie/{util,timing}_after.rpt)"
