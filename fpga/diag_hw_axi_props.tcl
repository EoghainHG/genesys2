# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Eoghain Gray

## Read-only diagnostic (no board interaction needed beyond the board
## already being programmed/connected) -- dump the jtag_axi hw_axi
## object's full property set to confirm it supports AXI4 burst
## transactions (not AXI4LITE) before trusting
## fpga/load_ddr_program_burst.tcl for the real ~35-40 minute OpenSBI+
## kernel load. See that script's own header for why this matters.
## Run from the project root:
##   vivado -mode batch -source fpga/diag_hw_axi_props.tcl -log build/diag_hw_axi_props.log -journal build/diag_hw_axi_props.jou

open_hw_manager
connect_hw_server
set targets [get_hw_targets]
open_hw_target [lindex $targets 0]
set dev [lindex [get_hw_devices] 0]
current_hw_device $dev
refresh_hw_device -update_hw_probes false $dev

set axi_masters [get_hw_axis -of_objects $dev]
puts "HW_AXI_MASTERS: $axi_masters"
set axi_master [lindex $axi_masters 0]

puts "=== hw_axi object: $axi_master ==="
puts [report_property -all -return_string $axi_master]

puts "DIAG_HW_AXI_PROPS_COMPLETE"
close_hw_target
close_hw_manager
