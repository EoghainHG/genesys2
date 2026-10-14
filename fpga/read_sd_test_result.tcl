# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Eoghain Gray

## Read back sw/sd-test/sd_init_read_write.S's `tohost` result word over
## JTAG-AXI, for real hardware where there's no tb_riscv.sv sim harness to
## check it directly. tohost lives at CPU address 0x80001000 (confirmed via
## `riscv64-unknown-elf-nm build/sd/sd_init_read_write.elf`, ELF-address ==
## .text.init page-rounded up); AXI-side address is 0x1000 after the usual
## 0x8000_0000 ADDR_OFFSET subtraction (same convention every other real-
## hardware load/read in this project uses).
##
## riscv-tests' own tohost convention: 0 = still running/never written,
## 1 = PASS, any other odd value = FAIL with exit code (value >> 1).
##
## Run from the project root, any time after cpu_resetn has been released
## and the test has had time to run (it's short -- a handful of SPI byte
## transfers plus polling loops, real time dominated by the ~400kHz
## init-phase SCLK, well under a second):
##   vivado -mode batch -source fpga/read_sd_test_result.tcl -log build/sd_test_read.log -journal build/sd_test_read.jou

set tohost_addr 0x00001000
set debug_byte_idx_addr 0x00002000

open_hw_manager
connect_hw_server

set targets [get_hw_targets]
if {[llength $targets] != 1} {
    puts "SD_TEST_READ_FAILED: expected exactly 1 hw_target, found [llength $targets]: $targets"
    close_hw_manager
    exit 1
}
open_hw_target [lindex $targets 0]

set devs [get_hw_devices]
if {[llength $devs] != 1} {
    puts "SD_TEST_READ_FAILED: expected exactly 1 hw_device, found [llength $devs]: $devs"
    close_hw_target
    close_hw_manager
    exit 1
}
set dev [lindex $devs 0]
current_hw_device $dev
refresh_hw_device -update_hw_probes false $dev

set axi_masters [get_hw_axis -of_objects $dev]
if {[llength $axi_masters] != 1} {
    puts "SD_TEST_READ_FAILED: expected exactly 1 hw_axi master (jtag_axi), found \
[llength $axi_masters]: $axi_masters"
    close_hw_target
    close_hw_manager
    exit 1
}
set axi_master [lindex $axi_masters 0]

create_hw_axi_txn read_tohost $axi_master -address $tohost_addr -type read -force
run_hw_axi [get_hw_axi_txns read_tohost]
set rresp [get_property STATUS.RRESP $axi_master]
set rdata [get_property DATA [get_hw_axi_txns read_tohost]]

puts "SD_TEST_TOHOST_RAW: RRESP=$rresp DATA=$rdata"

if {$rresp ne "OKAY"} {
    puts "SD_TEST_READ_FAILED: RRESP=$rresp (expected OKAY) -- AXI infrastructure issue, not a \
test result."
    close_hw_target
    close_hw_manager
    exit 1
}

scan $rdata "%x" val
if {$val == 0} {
    puts "SD_TEST_RESULT: STILL_RUNNING_OR_NEVER_STARTED (tohost=0)"
} elseif {$val == 1} {
    puts "SD_TEST_RESULT: PASS"
} else {
    set checkpoint [expr {$val >> 16}]
    puts "SD_TEST_RESULT: FAIL (tohost=$val, checkpoint=$checkpoint -- see \
sw/sd-test/sd_init_read_write.S's cmd*_fail labels for what each checkpoint means)"
}

create_hw_axi_txn read_dbg $axi_master -address $debug_byte_idx_addr -type read -force
run_hw_axi [get_hw_axi_txns read_dbg]
set dbg_rresp [get_property STATUS.RRESP $axi_master]
set dbg_rdata [get_property DATA [get_hw_axi_txns read_dbg]]
scan $dbg_rdata "%x" dbg_val
puts "SD_TEST_DEBUG_BYTE_IDX: RRESP=$dbg_rresp value=$dbg_val (0xFFFFFFFF = never written this run)"

close_hw_target
close_hw_manager
