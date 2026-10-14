# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Eoghain Gray

## SD-over-SPI bring-up, ILA debug variant: genesys2_top_sd built with a
## directly-instantiated ila_0 IP core wired to sd_sclk/sd_cmd/sd_d0/sd_d3,
## to root-cause CMD24 (WRITE_BLOCK)'s data-response-token timeout
## (checkpoint 13, cmd24_notoken_fail) -- two independent
## software fixes (Nwr turnaround byte, CRC16 dummy value) both left this
## checkpoint unchanged. Reuses the SAME project/runs as build_sd.tcl
## (build/vivado_proj/genesys2_ddr.xpr, synth_1/impl_1) -- only difference
## from a clean build is GENESYS2_ILA_DEBUG=1 (see genesys2_top_sd.sv's
## `ifdef guard) plus the ila_0 IP itself. Outputs are distinctly named
## (genesys2_top_sd_ila.bit/.ltx) so they never collide with the clean
## build's genesys2_top_sd.bit -- run build_sd.tcl again afterward (it
## unconditionally clears verilog_define first) to get back to a clean
## bitstream on this same project.
##
## Direct IP instantiation, NOT mark_debug/create_debug_core netlist
## insertion -- same Basic-tier-license reasoning as build_ddr_ila.tcl.
##
## Assumes fpga/bd_build.tcl has already been run against this project
## (same prerequisite as build_sd.tcl).
##
## Run from the project root:
##   vivado -mode batch -source fpga/build_sd_ila.tcl -log build/sd_ila_build.log -journal build/sd_ila_build.jou

set part      xc7k325tffg900-2
set proj_dir  build/vivado_proj
set proj_name genesys2_ddr
set outdir    build

file mkdir $outdir

open_project [file join $proj_dir $proj_name.xpr]

# ila_0: a single 6-bit probe (dbg_dataresp_marker, sd_reset, sd_d3, sd_d0,
# sd_cmd, sd_sclk -- see genesys2_top_sd.sv's u_ila_dbg instance for what
# each bit is and why). Width is tiny, so depth is pushed well past what
# the earlier DDR/UART investigation used (8192) -- 65536 samples x 6 bits
# is still under 0.4Mb, a small fraction of the xc7k325t's BRAM budget,
# and buys a long post-trigger window to watch the data-response poll live
# out its full MAX_DATARESP_POLLS=50000 iterations if it comes to that.
if {[llength [get_ips -quiet ila_0]] == 0} {
  create_ip -name ila -vendor xilinx.com -library ip -version 6.2 \
    -module_name ila_0 -dir [file join $proj_dir $proj_name.srcs sources_1 ip]
} else {
  puts "ila_0 IP already exists in this project -- reconfiguring it in place."
}
set_property -dict [list \
  CONFIG.C_NUM_OF_PROBES  {1} \
  CONFIG.C_PROBE0_WIDTH   {6} \
  CONFIG.C_DATA_DEPTH     {65536} \
  CONFIG.C_TRIGIN_EN      {false} \
  CONFIG.C_TRIGOUT_EN     {false} \
  CONFIG.C_ADV_TRIGGER    {false} \
  CONFIG.C_EN_STRG_QUAL   {1} \
] [get_ips ila_0]
# Echo the actually-applied CONFIG.* values before this IP is synthesized
# into anything -- same "print real values before using them, so a wrong
# guess fails loudly" discipline as build_ddr_ila.tcl.
puts "ILA_PROBE_WIDTHS: probe0=[get_property CONFIG.C_PROBE0_WIDTH [get_ips ila_0]] \
depth=[get_property CONFIG.C_DATA_DEPTH [get_ips ila_0]]"

generate_target {instantiation_template} [get_files ila_0.xci]
generate_target all [get_files ila_0.xci]
catch { export_ip_user_files -of_objects [get_files ila_0.xci] -no_script -sync -force -quiet }
create_ip_run [get_files ila_0.xci]

# The one line of difference from build_sd.tcl's project state: makes
# genesys2_top_sd.sv's `ifdef GENESYS2_ILA_DEBUG guard compile in.
set_property verilog_define {GENESYS2_ILA_DEBUG=1} [get_filesets sources_1]

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

# See genesys2_top_sd_timing.xdc's own header for why this constraint set
# must be skipped during synthesis and applied only during implementation.
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
write_checkpoint -force $outdir/sd_ila_post_synth.dcp
report_utilization -file $outdir/sd_ila_post_synth_utilization.rpt

launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1

open_run impl_1 -name impl_1
report_timing_summary -delay_type min_max -report_unconstrained \
  -max_paths 10 -input_pins -file $outdir/sd_ila_timing_summary.rpt
report_utilization -file $outdir/sd_ila_utilization.rpt
write_checkpoint -force $outdir/sd_ila_post_route.dcp

# .ltx probes file -- capture_cmd24_ila.tcl needs this alongside the .bit
# to map the ila_0 core's probes back to signal names in Hardware Manager.
write_debug_probes -force $outdir/genesys2_top_sd_ila.ltx

file copy -force \
  [file join $proj_dir $proj_name.runs impl_1 genesys2_top_sd.bit] \
  [file join $outdir genesys2_top_sd_ila.bit]

puts "SD_ILA_BUILD_COMPLETE"
