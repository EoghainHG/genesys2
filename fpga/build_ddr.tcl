# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Eoghain Gray

## DDR3 bring-up, stage B: genesys2_top_ddr (full CPU+AXI+DDR3) on the
## Genesys 2 (XC7K325T-2FFG900C). Project-mode (Block Designs require a
## real project). Assumes fpga/bd_build.tcl has already been run against
## the same project (creates the mig_bridge Block Design, now with 3
## SmartConnect masters: icache, dcache, jtag_axi) -- run it first.
##
## Run from the project root:
##   vivado -mode batch -source fpga/build_ddr.tcl -log build/ddr_build.log -journal build/ddr_build.jou

set part      xc7k325tffg900-2
set proj_dir  build/vivado_proj
set proj_name genesys2_ddr
set outdir    build

file mkdir $outdir

open_project [file join $proj_dir $proj_name.xpr]

# Unconditionally clear GENESYS2_ILA_DEBUG on this shared project -- a
# prior fpga/build_ddr_ila.tcl run would otherwise leave it set on the
# .xpr, silently compiling the ILA into what's supposed to be the clean
# build.
set_property verilog_define {} [get_filesets sources_1]

add_files -norecurse {
  rtl/core/riscv_pkg.sv
  rtl/core/alu.sv
  rtl/core/mul_unit.sv
  rtl/core/div_unit.sv
  rtl/core/imm_gen.sv
  rtl/core/regfile.sv
  rtl/core/control.sv
  rtl/core/icache.sv
  rtl/core/dcache.sv
  rtl/core/cpu.sv
  rtl/periph/mmio_decoder.sv
  rtl/periph/clint.sv
  rtl/periph/plic.sv
  rtl/periph/uart.sv
  rtl/bridge/uart_phy.sv
  rtl/bridge/axi4lite_master.sv
  fpga/genesys2_top_ddr.sv
}
add_files -fileset constrs_1 -norecurse fpga/genesys2_top_ddr.xdc
add_files -fileset constrs_1 -norecurse fpga/genesys2_top_ddr_timing.xdc

# See genesys2_top_ddr_timing.xdc's own header for why this constraint set
# must be skipped during synthesis and applied only during implementation.
set_property USED_IN_SYNTHESIS false [get_files fpga/genesys2_top_ddr_timing.xdc]

set_property top genesys2_top_ddr [current_fileset]
update_compile_order -fileset sources_1

# Vivado refuses to re-launch a run that already completed without an
# explicit reset first -- reset unconditionally rather than only on
# known-dirty runs (bites every re-run against an existing project).
reset_run synth_1
launch_runs synth_1 -jobs 4
wait_on_run synth_1
open_run synth_1 -name synth_1
write_checkpoint -force $outdir/ddr_post_synth.dcp
report_utilization -file $outdir/ddr_post_synth_utilization.rpt

launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1

open_run impl_1 -name impl_1
report_timing_summary -delay_type min_max -report_unconstrained \
  -max_paths 10 -input_pins -file $outdir/ddr_timing_summary.rpt
report_utilization -file $outdir/ddr_utilization.rpt
write_checkpoint -force $outdir/ddr_post_route.dcp

file copy -force \
  [file join $proj_dir $proj_name.runs impl_1 genesys2_top_ddr.bit] \
  [file join $outdir genesys2_top_ddr.bit]

puts "DDR_BUILD_COMPLETE"
