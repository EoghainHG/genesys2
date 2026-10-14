# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Eoghain Gray

## Non-project batch programming for the ILA-instrumented genesys2_top_ddr
## build on the Genesys 2 (XC7K325T-2FFG900C). Identical to program_ddr.tcl
## except for the bitfile path and marker prefix -- see that script for the
## full defensive-check rationale. Run from the project root:
##   vivado -mode batch -source fpga/program_ddr_ila.tcl -log build/ddr_ila_program.log -journal build/ddr_ila_program.jou
##
## Requires build/genesys2_top_ddr_ila.bit (and its companion
## build/genesys2_top_ddr_ila.ltx) to already exist -- see build_ddr_ila.tcl
## / DDR_ILA_BUILD_COMPLETE. Holding cpu_resetn is NOT required for
## programming itself (same as program_ddr.tcl) -- hold it starting before
## fpga/load_ddr_program.tcl runs, per that script's own header, and keep
## holding through fpga/capture_ddr_ila.tcl's arm step.

set bitfile   build/genesys2_top_ddr_ila.bit
set part_glob "xc7k325t*"

if {![file exists $bitfile]} {
    puts "DDR_ILA_PROGRAM_FAILED: bitstream not found at $bitfile -- run build_ddr_ila.tcl first"
    exit 1
}

open_hw_manager
connect_hw_server

set targets [get_hw_targets]
if {[llength $targets] == 0} {
    puts "DDR_ILA_PROGRAM_FAILED: no hw_target found. Check: board powered on; JTAG micro-USB port \
connected (not a UART-only or power-only port); FTDI/Digilent cable drivers installed for this \
Vivado install; no interactive Windows Firewall prompt is stuck waiting on the Windows desktop \
for hw_server.exe's first-ever launch."
    close_hw_manager
    exit 1
}
if {[llength $targets] > 1} {
    puts "DDR_ILA_PROGRAM_FAILED: found [llength $targets] hw_targets, expected exactly 1: $targets \
-- disconnect other JTAG-capable USB devices before programming so the wrong board can't be hit."
    close_hw_manager
    exit 1
}
open_hw_target [lindex $targets 0]

set devs [get_hw_devices]
if {[llength $devs] == 0} {
    puts "DDR_ILA_PROGRAM_FAILED: hw_target opened but no hw_devices found in the JTAG chain -- \
check board power and that the JTAG cable is seated."
    close_hw_target
    close_hw_manager
    exit 1
}
if {[llength $devs] > 1} {
    puts "DDR_ILA_PROGRAM_FAILED: found [llength $devs] devices in the JTAG chain, expected exactly \
1 ($devs) -- unexpected for a single Kintex-7 with no PS. Investigate before programming device 0."
    close_hw_target
    close_hw_manager
    exit 1
}

set dev [lindex $devs 0]
current_hw_device $dev
refresh_hw_device $dev

set dev_part [get_property PART $dev]
set idcode "unknown"
catch { set idcode [get_property IDCODE $dev] }

if {![string match $part_glob $dev_part]} {
    puts "DDR_ILA_PROGRAM_FAILED: device found is '$dev_part' (IDCODE=$idcode), does not match \
expected '$part_glob' -- wrong board connected, or a stale/wrong chain. Refusing to program."
    close_hw_target
    close_hw_manager
    exit 1
}

puts "Found matching device: $dev ($dev_part), IDCODE=$idcode"

set_property PROGRAM.FILE $bitfile $dev
program_hw_devices $dev

puts "DDR_ILA_PROGRAM_COMPLETE"

close_hw_target
close_hw_manager
