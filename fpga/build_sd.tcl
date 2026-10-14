# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Eoghain Gray

## SD-over-SPI bring-up: genesys2_top_sd (genesys2_top_ddr's proven CPU+DDR3
## path plus spi_master.sv wired to the board's native SD slot pins for the
## first time on real hardware). Project-mode, reuses the SAME persistent
## project/Block Design as build_ddr.tcl/build_ddr_ila.tcl (assumes
## fpga/bd_build.tcl has already been run against it -- run it first if
## build/vivado_proj/ doesn't exist yet).
##
## Run from the project root:
##   vivado -mode batch -source fpga/build_sd.tcl -log build/sd_build.log -journal build/sd_build.jou

set part      xc7k325tffg900-2
set proj_dir  build/vivado_proj
set proj_name genesys2_ddr
set outdir    build

file mkdir $outdir

open_project [file join $proj_dir $proj_name.xpr]

# Unconditionally clear any verilog_define left over from a prior
# build_ddr_ila.tcl run on this shared project (same discipline
# build_ddr.tcl itself already uses) -- genesys2_top_sd.sv has no
# `ifdef GENESYS2_ILA_DEBUG guards at all, so this is just hygiene, not a
# functional requirement for this specific top level.
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
  rtl/periph/spi_master.sv
  rtl/periph/i2c_gpio.sv
  rtl/bridge/uart_phy.sv
  rtl/bridge/axi4lite_master.sv
  fpga/genesys2_top_sd.sv
}
add_files -fileset constrs_1 -norecurse fpga/genesys2_top_sd.xdc
add_files -fileset constrs_1 -norecurse fpga/genesys2_top_sd_timing.xdc

# See genesys2_top_ddr_timing.xdc's own header (genesys2_top_sd_timing.xdc
# mirrors it) for why this constraint set must be skipped during synthesis
# and applied only during implementation.
set_property USED_IN_SYNTHESIS false [get_files fpga/genesys2_top_sd_timing.xdc]

set_property top genesys2_top_sd [current_fileset]
update_compile_order -fileset sources_1

# Vivado refuses to re-launch a run that already completed without an
# explicit reset first -- reset unconditionally rather than only on
# known-dirty runs (bites every re-run against an existing project).
reset_run synth_1
launch_runs synth_1 -jobs 4
wait_on_run synth_1
open_run synth_1 -name synth_1
write_checkpoint -force $outdir/sd_post_synth.dcp
report_utilization -file $outdir/sd_post_synth_utilization.rpt

launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1

open_run impl_1 -name impl_1
report_timing_summary -delay_type min_max -report_unconstrained \
  -max_paths 10 -input_pins -file $outdir/sd_timing_summary.rpt
report_utilization -file $outdir/sd_utilization.rpt
write_checkpoint -force $outdir/sd_post_route.dcp

file copy -force \
  [file join $proj_dir $proj_name.runs impl_1 genesys2_top_sd.bit] \
  [file join $outdir genesys2_top_sd.bit]

puts "SD_BUILD_COMPLETE"
