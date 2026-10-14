# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Eoghain Gray

## Read back sw/sd-test/sd_write_pmon.S's tohost result plus its VCC3V3 AND
## VCC1V0 voltage-sample buffers, over JTAG-AXI (real hardware has no
## tb_riscv.sv sim harness to print through). Addresses confirmed via
## `riscv64-unknown-elf-nm build/sd/sd_write_pmon.elf`:
##   tohost           @ CPU 0x80001000 -> AXI 0x1000
##   debug_byte_idx   @ CPU 0x80002000 -> AXI 0x2000
##   pmon_idx         @ CPU 0x80002004 -> AXI 0x2004
##   pmon_samples[]   @ CPU 0x80002008 -> AXI 0x2008 (VCC3V3, up to
##                       MAX_PMON_SAMPLES=48 words, count given by pmon_idx)
##   pmon_1v0_idx     @ CPU 0x800020c8 -> AXI 0x20c8
##   pmon_1v0_samples[] @ CPU 0x800020cc -> AXI 0x20cc (VCC1V0/VCCINT, same
##                       count as pmon_idx -- both arrays always kept in
##                       lockstep, one store_vcc3v3+store_vcc1v0 pair per
##                       sample point)
## Same "subtract the 0x8000_0000 ADDR_OFFSET" convention every other real-
## hardware load/read in this project uses.
##
## Run from the project root, any time after cpu_resetn has been released
## and the write attempt(s) have had time to complete (each attempt takes
## a fraction of a second normally, up to tens of ms if MAX_DATARESP_POLLS
## is being exhausted -- with MAX_WRITE_RETRIES=10 retries, budget several
## hundred ms to be safe):
##   vivado -mode batch -source fpga/read_pmon_result.tcl -log build/pmon_read.log -journal build/pmon_read.jou

set tohost_addr        0x00001000
set pmon_idx_addr      0x00002004
set pmon_arr_addr      0x00002008
set pmon_1v0_idx_addr  0x000020c8
set pmon_1v0_arr_addr  0x000020cc
set max_pmon_samples 48

open_hw_manager
connect_hw_server

set targets [get_hw_targets]
if {[llength $targets] != 1} {
    puts "PMON_READ_FAILED: expected exactly 1 hw_target, found [llength $targets]: $targets"
    close_hw_manager
    exit 1
}
open_hw_target [lindex $targets 0]

set devs [get_hw_devices]
if {[llength $devs] != 1} {
    puts "PMON_READ_FAILED: expected exactly 1 hw_device, found [llength $devs]: $devs"
    close_hw_target
    close_hw_manager
    exit 1
}
set dev [lindex $devs 0]
current_hw_device $dev
refresh_hw_device -update_hw_probes false $dev

set axi_masters [get_hw_axis -of_objects $dev]
if {[llength $axi_masters] != 1} {
    puts "PMON_READ_FAILED: expected exactly 1 hw_axi master (jtag_axi), found \
[llength $axi_masters]: $axi_masters"
    close_hw_target
    close_hw_manager
    exit 1
}
set axi_master [lindex $axi_masters 0]

proc axi_read_word {axi_master addr_hex label} {
    create_hw_axi_txn rd_$label $axi_master -address $addr_hex -type read -force
    run_hw_axi [get_hw_axi_txns rd_$label]
    set rresp [get_property STATUS.RRESP $axi_master]
    set rdata [get_property DATA [get_hw_axi_txns rd_$label]]
    if {$rresp ne "OKAY"} {
        puts "PMON_READ_FAILED: RRESP=$rresp (expected OKAY) at $addr_hex -- AXI infrastructure \
issue, not a test result."
        return -1
    }
    scan $rdata "%x" val
    return $val
}

set tohost_val [axi_read_word $axi_master $tohost_addr tohost]
if {$tohost_val == -1} { close_hw_target; close_hw_manager; exit 1 }

if {$tohost_val == 0} {
    puts "PMON_TEST_RESULT: STILL_RUNNING_OR_NEVER_STARTED (tohost=0)"
} elseif {$tohost_val == 1} {
    puts "PMON_TEST_RESULT: PASS"
} else {
    set checkpoint [expr {$tohost_val >> 16}]
    puts "PMON_TEST_RESULT: FAIL (tohost=$tohost_val, checkpoint=$checkpoint -- see \
sw/sd-test/sd_write_pmon.S's cmd*_fail labels, shared numbering with sd_init_read_write.S)"
}

set idx_val [axi_read_word $axi_master $pmon_idx_addr pmon_idx]
if {$idx_val == -1} { close_hw_target; close_hw_manager; exit 1 }
if {$idx_val > $max_pmon_samples} {
    puts "PMON_READ_WARNING: pmon_idx=$idx_val exceeds MAX_PMON_SAMPLES=$max_pmon_samples -- \
clamping (should never happen, store_vcc3v3 itself bounds this)."
    set idx_val $max_pmon_samples
}
set idx_1v0_val [axi_read_word $axi_master $pmon_1v0_idx_addr pmon_1v0_idx]
if {$idx_1v0_val == -1} { close_hw_target; close_hw_manager; exit 1 }
if {$idx_1v0_val > $max_pmon_samples} { set idx_1v0_val $max_pmon_samples }
if {$idx_1v0_val != $idx_val} {
    puts "PMON_READ_WARNING: pmon_idx=$idx_val but pmon_1v0_idx=$idx_1v0_val -- expected these \
to always match (one store_vcc3v3+store_vcc1v0 pair per sample point). Reading \
min(\$idx_val,\$idx_1v0_val) pairs; investigate if this recurs."
}
set n_pairs [expr {$idx_val < $idx_1v0_val ? $idx_val : $idx_1v0_val}]
puts "PMON_SAMPLE_COUNT: $n_pairs (each attempt contributes up to 4: P0=baseline, \
P1=after-R1, P2=after-data+CRC, P3=poll-conclusion -- reconstruct which is which from \
index MOD 4, not a stored tag)"

set labels {P0-baseline P1-after-R1 P2-after-data+CRC P3-poll-conclusion}
for {set i 0} {$i < $n_pairs} {incr i} {
    set addr [format "0x%08x" [expr {$pmon_arr_addr + $i * 4}]]
    set mv [axi_read_word $axi_master $addr "pmon$i"]
    if {$mv == -1} { close_hw_target; close_hw_manager; exit 1 }
    set addr_1v0 [format "0x%08x" [expr {$pmon_1v0_arr_addr + $i * 4}]]
    set mv_1v0 [axi_read_word $axi_master $addr_1v0 "pmon1v0_$i"]
    if {$mv_1v0 == -1} { close_hw_target; close_hw_manager; exit 1 }
    set attempt [expr {$i / 4}]
    set label [lindex $labels [expr {$i % 4}]]
    puts "PMON_SAMPLE\[$i\]: attempt=$attempt point=$label vcc3v3=${mv}mV vcc1v0=${mv_1v0}mV"
}

close_hw_target
close_hw_manager
