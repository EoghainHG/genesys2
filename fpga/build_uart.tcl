# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Eoghain Gray

## Non-project batch build for genesys2_top_uart on the Genesys 2 (XC7K325T-2FFG900C).
## Requires Vivado 2026.1 -- see build_blink.tcl's header for the install path note.
##
## Run from the project root:
##   vivado -mode batch -source fpga/build_uart.tcl -log build/uart_build.log -journal build/uart_build.jou

set part    xc7k325tffg900-2
set outdir  build

file mkdir $outdir

read_verilog -sv {
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
  fpga/genesys2_top_uart.sv
}

read_xdc fpga/genesys2_top_uart.xdc

synth_design -top genesys2_top_uart -part $part
write_checkpoint -force $outdir/uart_post_synth.dcp
report_utilization -file $outdir/uart_post_synth_utilization.rpt

opt_design
place_design
phys_opt_design
route_design

report_timing_summary -delay_type min_max -report_unconstrained \
  -max_paths 10 -input_pins -file $outdir/uart_timing_summary.rpt
report_utilization -file $outdir/uart_utilization.rpt
report_clocks -file $outdir/uart_clocks.rpt

write_checkpoint -force $outdir/uart_post_route.dcp
write_bitstream -force $outdir/genesys2_top_uart.bit

puts "UART_BUILD_COMPLETE"
