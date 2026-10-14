# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Eoghain Gray

## DDR3 bring-up, stage B debug variant: genesys2_top_ddr built with a
## directly-instantiated ila_0 IP core wired to the icache<->axi4lite_master
## boundary, to root-cause the open, non-deterministic instruction-fetch
## data-corruption bug (an "open bug, NOT resolved" item).
## Reuses the SAME project/runs as build_ddr.tcl (build/vivado_proj/
## genesys2_ddr.xpr, synth_1/impl_1) -- only difference from a clean build
## is GENESYS2_ILA_DEBUG=1 (see genesys2_top_ddr.sv's `ifdef guards) plus
## the ila_0 IP itself. Outputs are distinctly named
## (genesys2_top_ddr_ila.bit/.ltx) so they never collide with the clean
## build's genesys2_top_ddr.bit -- run build_ddr.tcl again afterward (it
## unconditionally clears verilog_define first) to get back to a clean
## bitstream on this same project.
##
## Direct IP instantiation, NOT mark_debug/create_debug_core netlist
## insertion -- this Vivado install's ILA entitlement is Basic-tier
## (1 core / <=5 probes / <=1024 bits, instantiation-only, no auto-insert),
## and project-mode's launch_runs
## re-reads each run's on-disk checkpoint rather than picking up
## interactive post-open_run modifications, so a plain IP flowing through
## the exact same add_files -> reset_run synth_1 -> launch_runs synth_1 ->
## launch_runs impl_1 pipeline build_ddr.tcl already uses is the reliable
## choice for a single non-interactive batch run.
##
## Assumes fpga/bd_build.tcl has already been run against this project
## (same prerequisite as build_ddr.tcl).
##
## Run from the project root:
##   vivado -mode batch -source fpga/build_ddr_ila.tcl -log build/ddr_ila_build.log -journal build/ddr_ila_build.jou

set part      xc7k325tffg900-2
set proj_dir  build/vivado_proj
set proj_name genesys2_ddr
set outdir    build

file mkdir $outdir

open_project [file join $proj_dir $proj_name.xpr]

# ila_0: 5 probes (this license tier's max), all clk_core-domain --
# retargeted 2026-09-06 from the earlier icache
# instruction-fetch corruption investigation (resolved) to the interactive
# console freeze investigation. See genesys2_top_ddr.sv's u_ila_dbg
# instance for exactly what each bit is and why.
#   probe0 (19b, trigger bit18): dbg_stuck_flag, in_service1, pending1,
#                 uart_dr_status, iir_val[7:0], ier[1:0], seip, meip,
#                 tx_valid, tx_busy, irq
#   probe1 (17b): tx_data[7:0], rx_inject_data[7:0], rx_inject_valid
#   probe2 (6b):  plic_ren, plic_wen, complete_fire_ctx1, complete_fire_ctx0,
#                 claim_fire_ctx1, claim_fire_ctx0
#   probe3 (33b): dbg_id_ex_valid, dbg_id_ex_pc[31:0]
#   probe4 (10b): dbg_stuck_cnt[23:16], axi_infra_rst_n, cpu_rst_n
# Depth 8192: 85 total probe bits x 8192 samples ~= 0.68Mb ~= 19 BRAM36
# blocks (~4% of the xc7k325t's 445-block budget). dbg_stuck_flag (in
# genesys2_top_ddr.sv) IS the trigger condition, not a plain probe -- it
# only asserts once the PLIC's own pending/in_service state has gone
# unresolved for far longer (~17.8ms) than any real interrupt service
# should take, so capture starts exactly at the freeze regardless of how
# much idle real time (the freeze was reproduced with 15ms-paced typing,
# nowhere near "too fast") preceded it -- no plain sample buffer at this
# width could otherwise bridge that gap.
## create_ip is NOT idempotent -- it errors ("IP name 'ila_0' is already in
## use") on any re-run against this same persistent project once it's been
## created once, including by a prior run that failed a later step (e.g. a
## bad CONFIG.* value) but still left the IP registered. This project gets
## rebuilt routinely, so only create it the first time.
if {[llength [get_ips -quiet ila_0]] == 0} {
  create_ip -name ila -vendor xilinx.com -library ip -version 6.2 \
    -module_name ila_0 -dir [file join $proj_dir $proj_name.srcs sources_1 ip]
} else {
  puts "ila_0 IP already exists in this project -- reconfiguring it in place."
}
set_property -dict [list \
  CONFIG.C_NUM_OF_PROBES  {5} \
  CONFIG.C_PROBE0_WIDTH   {19} \
  CONFIG.C_PROBE1_WIDTH   {17} \
  CONFIG.C_PROBE2_WIDTH   {6} \
  CONFIG.C_PROBE3_WIDTH   {33} \
  CONFIG.C_PROBE4_WIDTH   {10} \
  CONFIG.C_DATA_DEPTH     {8192} \
  CONFIG.C_TRIGIN_EN      {false} \
  CONFIG.C_TRIGOUT_EN     {false} \
  CONFIG.C_ADV_TRIGGER    {false} \
  CONFIG.C_EN_STRG_QUAL   {1} \
] [get_ips ila_0]
# Echo the actually-applied CONFIG.* values before this IP is synthesized
# into anything -- same "print real values before using them, so a wrong
# guess fails loudly" discipline as bd_build.tcl. If any width below
# doesn't match the -dict call above, STOP and check this install's real
# ila 6.2 CONFIG.* property names (`report_property -all [get_ips ila_0]`)
# before continuing -- do not guess past a mismatch here.
puts "ILA_PROBE_WIDTHS: probe0=[get_property CONFIG.C_PROBE0_WIDTH [get_ips ila_0]] \
probe1=[get_property CONFIG.C_PROBE1_WIDTH [get_ips ila_0]] \
probe2=[get_property CONFIG.C_PROBE2_WIDTH [get_ips ila_0]] \
probe3=[get_property CONFIG.C_PROBE3_WIDTH [get_ips ila_0]] \
probe4=[get_property CONFIG.C_PROBE4_WIDTH [get_ips ila_0]] \
depth=[get_property CONFIG.C_DATA_DEPTH [get_ips ila_0]]"

generate_target {instantiation_template} [get_files ila_0.xci]
generate_target all [get_files ila_0.xci]
catch { export_ip_user_files -of_objects [get_files ila_0.xci] -no_script -sync -force -quiet }
create_ip_run [get_files ila_0.xci]

# The one line of difference from build_ddr.tcl's project state: makes
# genesys2_top_ddr.sv's `ifdef GENESYS2_ILA_DEBUG guards compile in.
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
write_checkpoint -force $outdir/ddr_ila_post_synth.dcp
report_utilization -file $outdir/ddr_ila_post_synth_utilization.rpt

launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1

open_run impl_1 -name impl_1
report_timing_summary -delay_type min_max -report_unconstrained \
  -max_paths 10 -input_pins -file $outdir/ddr_ila_timing_summary.rpt
report_utilization -file $outdir/ddr_ila_utilization.rpt
write_checkpoint -force $outdir/ddr_ila_post_route.dcp

# .ltx probes file -- capture_ddr_ila.tcl needs this alongside the .bit to
# map the ila_0 core's probes back to signal names in Hardware Manager.
write_debug_probes -force $outdir/genesys2_top_ddr_ila.ltx

file copy -force \
  [file join $proj_dir $proj_name.runs impl_1 genesys2_top_ddr.bit] \
  [file join $outdir genesys2_top_ddr_ila.bit]

puts "DDR_ILA_BUILD_COMPLETE"
