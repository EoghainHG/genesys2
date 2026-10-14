# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Eoghain Gray

## Read-only diagnostic (no board interaction needed) -- dump the real
## property names/values for the ila_0 core and its cpu_rst_n probe, since
## capture_ddr_ila.tcl has now failed to capture any real sample data
## across 4 separate arm attempts (some catch-wrapped set_property calls
## may be silently failing on a bad property name for this Vivado 2026.1
## ila 6.2 IP version). Run from the project root:
##   vivado -mode batch -source fpga/diag_ila_props.tcl -log build/diag_ila_props.log -journal build/diag_ila_props.jou

open_hw_manager
connect_hw_server
set targets [get_hw_targets]
open_hw_target [lindex $targets 0]
set dev [lindex [get_hw_devices] 0]
current_hw_device $dev
refresh_hw_device -update_hw_probes false $dev
set_property PROBES.FILE build/genesys2_top_ddr_ila.ltx $dev
refresh_hw_device -update_hw_probes true $dev

set ila [lindex [get_hw_ilas -of_objects $dev] 0]
puts "=== ila object: $ila ==="
puts [report_property -all -return_string $ila]

set trig_probe [lindex [get_hw_probes {*cpu_rst_n} -of_objects $ila] 0]
puts "=== trig_probe object: $trig_probe ==="
puts [report_property -all -return_string $trig_probe]

puts "DIAG_ILA_PROPS_COMPLETE"
close_hw_target
close_hw_manager
