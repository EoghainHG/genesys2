# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Eoghain Gray

## DDR3 bring-up, stage A: genesys2_top_ddr_calib on the Genesys 2
## (XC7K325T-2FFG900C). Project-mode (Block Designs require a real project --
## unlike fpga/build_min.tcl's non-project batch flow). Assumes
## fpga/bd_build.tcl has already been run against the same project (creates
## the mig_bridge Block Design this depends on) -- run it first.
##
## Run from the project root:
##   vivado -mode batch -source fpga/build_ddr_calib.tcl -log build/ddr_calib_build.log -journal build/ddr_calib_build.jou

set part      xc7k325tffg900-2
set proj_dir  build/vivado_proj
set proj_name genesys2_ddr
set outdir    build

file mkdir $outdir

open_project [file join $proj_dir $proj_name.xpr]

# Only this stage's top level -- no CPU/cache/periph RTL at all (see
# genesys2_top_ddr_calib.sv's own header for why: no way to load a real
# program into DDR3 yet, so a CPU here would just execute uninitialized
# garbage with no meaningful pass/fail signal). Re-adding the BD wrapper
# (already added by bd_build.tcl) is harmless -- add_files no-ops on
# already-added files.
add_files -norecurse {
  fpga/genesys2_top_ddr_calib.sv
}
add_files -fileset constrs_1 -norecurse fpga/genesys2_top_ddr_calib.xdc

set_property top genesys2_top_ddr_calib [current_fileset]
update_compile_order -fileset sources_1

# Vivado refuses to re-launch a run that already completed without an
# explicit reset first -- reset unconditionally rather than only on
# known-dirty runs (bites every re-run against an existing project, not
# just a first-time build).
reset_run synth_1
launch_runs synth_1 -jobs 4
wait_on_run synth_1
open_run synth_1 -name synth_1
write_checkpoint -force $outdir/ddr_calib_post_synth.dcp
report_utilization -file $outdir/ddr_calib_post_synth_utilization.rpt

launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1

open_run impl_1 -name impl_1
report_timing_summary -delay_type min_max -report_unconstrained \
  -max_paths 10 -input_pins -file $outdir/ddr_calib_timing_summary.rpt
report_utilization -file $outdir/ddr_calib_utilization.rpt
write_checkpoint -force $outdir/ddr_calib_post_route.dcp

file copy -force \
  [file join $proj_dir $proj_name.runs impl_1 genesys2_top_ddr_calib.bit] \
  [file join $outdir genesys2_top_ddr_calib.bit]

puts "DDR_CALIB_BUILD_COMPLETE"
