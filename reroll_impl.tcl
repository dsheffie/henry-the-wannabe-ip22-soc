# Re-roll impl_11 to escape the marginal-TLB-CAM timing outcome (WNS -0.812).
# place_design has no -seed in Vivado 2025.1, so vary placement via DIRECTIVE and
# add post-route phys_opt to close the route-dominated ITLB-CAM path.
#   vivado -mode batch -source reroll_impl.tcl
set proj /home/dsheffie/fpga/ultra96v2-henry/BASELINE_2022.2/ultra96v2_oob.xpr
open_project $proj
set run impl_11
reset_run $run
# clear the stale -seed MORE OPTIONS left from the failed attempt
set_property -name {STEPS.PLACE_DESIGN.ARGS.MORE OPTIONS} -value {} -objects [get_runs $run]
set_property STEPS.PLACE_DESIGN.ARGS.DIRECTIVE Explore [get_runs $run]
set_property STEPS.ROUTE_DESIGN.ARGS.DIRECTIVE Explore [get_runs $run]
set_property STEPS.POST_ROUTE_PHYS_OPT_DESIGN.IS_ENABLED true [get_runs $run]
set_property STEPS.POST_ROUTE_PHYS_OPT_DESIGN.ARGS.DIRECTIVE Explore [get_runs $run]
launch_runs $run -to_step write_bitstream -jobs 12
wait_on_run $run
puts "REROLL_DONE run=$run"
