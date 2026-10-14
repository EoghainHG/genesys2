# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Eoghain Gray

## Non-project batch build for genesys2_blink on the Genesys 2 (XC7K325T-2FFG900C).
## Requires Vivado 2026.1 (this part is not in the free tier of 2024.2) --
## found on this machine at C:\AMDDesignTools\2026.1\Vivado\bin\vivado.bat,
## NOT the classic C:\Xilinx\Vivado\<ver> path.
##
## Run from the project root:
##   vivado -mode batch -source fpga/build_blink.tcl -log build/blink_build.log -journal build/blink_build.jou

set part    xc7k325tffg900-2
set outdir  build

file mkdir $outdir

read_verilog -sv { fpga/genesys2_blink.sv }
read_xdc fpga/genesys2_blink.xdc

synth_design -top genesys2_blink -part $part
write_checkpoint -force $outdir/blink_post_synth.dcp
report_utilization -file $outdir/blink_post_synth_utilization.rpt

opt_design
place_design
phys_opt_design
route_design

report_timing_summary -delay_type min_max -report_unconstrained \
  -max_paths 10 -input_pins -file $outdir/blink_timing_summary.rpt
report_utilization -file $outdir/blink_utilization.rpt
report_clocks -file $outdir/blink_clocks.rpt

write_checkpoint -force $outdir/blink_post_route.dcp
write_bitstream -force $outdir/genesys2_blink.bit

puts "BLINK_BUILD_COMPLETE"
