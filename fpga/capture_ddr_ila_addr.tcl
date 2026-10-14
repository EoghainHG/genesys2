# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Eoghain Gray

## Single-window ILA capture triggered on a SPECIFIC icmem_addr's first
## real miss, not the reset-release edge (fpga/capture_ddr_ila.tcl, only
## reaches ~8192 cycles post-release) or the attempted multi-window
## variant (fpga/capture_ddr_ila_misses.tcl -- WINDOW_COUNT config read
## back correctly but the exported CSV showed only one continuous
## 8192-sample window, not 8 separate re-armed ones; root cause not yet
## understood, abandoned for this more direct approach). This lets a
## single capture jump straight to a LATER point in
## sw/uart-test/uart_test.mem's execution (skipping the ~4000-iteration
## DELAY_ITERS busy-loops between characters that a plain time-based
## capture can't skip past) by triggering on
## (icmem_addr == <target>) AND ic_dbg_miss_pulse -- the exact cycle that
## address is FIRST fetched over real AXI, since the corruption was
## observed in later character-load fetches this project's
## first reset-triggered capture never reached.
##
## Run from the project root, target address as a plain hex string
## (no 0x prefix stripping needed, Tcl accepts 0x-prefixed literals):
##   vivado -mode batch -source fpga/capture_ddr_ila_addr.tcl -tclargs \
##     0x80000010 build/genesys2_top_ddr_ila.ltx build/ddr_ila_capture_addr.csv \
##     -log build/ddr_ila_capture_addr.log -journal build/ddr_ila_capture_addr.jou

set target_addr [lindex $argv 0]
set probes_file [lindex $argv 1]
set out_csv     [lindex $argv 2]
if {$target_addr eq ""} {
    puts "DDR_ILA_CAPTURE_FAILED: no target address given -- usage: ... -tclargs 0x80000010 \[probes_file\] \[out_csv\]"
    exit 1
}
if {$probes_file eq ""} { set probes_file "build/genesys2_top_ddr_ila.ltx" }
if {$out_csv     eq ""} { set out_csv     "build/ddr_ila_capture_addr.csv" }

if {![file exists $probes_file]} {
    puts "DDR_ILA_CAPTURE_FAILED: probes file not found at $probes_file -- run build_ddr_ila.tcl first"
    exit 1
}

open_hw_manager
connect_hw_server

set targets [get_hw_targets]
if {[llength $targets] != 1} {
    puts "DDR_ILA_CAPTURE_FAILED: expected exactly 1 hw_target, found [llength $targets]: $targets"
    close_hw_manager
    exit 1
}
set target [lindex $targets 0]
open_hw_target $target
catch { set_property PARAM.FREQUENCY 2000000 $target }
puts "JTAG_TCK_FREQUENCY: [get_property PARAM.FREQUENCY $target] Hz"

set devs [get_hw_devices]
if {[llength $devs] != 1} {
    puts "DDR_ILA_CAPTURE_FAILED: expected exactly 1 hw_device, found [llength $devs]: $devs"
    close_hw_target
    close_hw_manager
    exit 1
}
set dev [lindex $devs 0]
current_hw_device $dev
refresh_hw_device -update_hw_probes false $dev
set_property PROBES.FILE $probes_file $dev
refresh_hw_device -update_hw_probes true $dev

set ila_cores [get_hw_ilas -of_objects $dev]
if {[llength $ila_cores] != 1} {
    puts "DDR_ILA_CAPTURE_FAILED: expected exactly 1 hw_ila core, found [llength $ila_cores]: $ila_cores"
    close_hw_target
    close_hw_manager
    exit 1
}
set ila [lindex $ila_cores 0]
puts "Using hw_ila core: $ila"

set addr_probe [get_hw_probes {*icmem_addr*} -of_objects $ila]
set miss_probe [get_hw_probes {*ic_dbg_miss_pulse} -of_objects $ila]
if {[llength $addr_probe] != 1 || [llength $miss_probe] != 1} {
    puts "DDR_ILA_CAPTURE_FAILED: expected exactly 1 probe each for icmem_addr ($addr_probe) and \
ic_dbg_miss_pulse ($miss_probe) -- check HW_ILA_PROBES: [get_hw_probes -of_objects $ila]"
    close_hw_target
    close_hw_manager
    exit 1
}

set max_attempts 3
set attempt 0
set captured 0
while {!$captured && $attempt < $max_attempts} {
    incr attempt
    # CRITICAL ORDERING (see capture_ddr_ila.tcl's own hard-won note):
    # reset_hw_ila wipes trigger config back to IP defaults -- must run
    # FIRST every iteration, before (re-)applying every setting below.
    catch { reset_hw_ila $ila }
    set_property CONTROL.WINDOW_COUNT 1 $ila
    catch { set_property CONTROL.TRIGGER_POSITION 64 $ila }
    set_property TRIGGER_COMPARE_VALUE eq32'h[string range $target_addr 2 end] $addr_probe
    set_property TRIGGER_COMPARE_VALUE eq1'b1 $miss_probe
    set_property CONTROL.TRIGGER_CONDITION AND $ila
    puts "TRIGGER_CONFIG_CHECK (attempt $attempt/$max_attempts): \
addr=[get_property TRIGGER_COMPARE_VALUE $addr_probe] (target $target_addr) \
miss=[get_property TRIGGER_COMPARE_VALUE $miss_probe] \
COND=[get_property CONTROL.TRIGGER_CONDITION $ila] \
DEPTH=[get_property CONTROL.DATA_DEPTH $ila] POS=[get_property CONTROL.TRIGGER_POSITION $ila]"

    if {$attempt > 1} {
        puts "Retrying (attempt $attempt/$max_attempts) -- this needs the CPU actually reaching \
$target_addr again; if it already ran past this point, reset (hold+release cpu_resetn) to \
restart the whole test from PC_RESET first."
    }
    run_hw_ila $ila
    puts "Waiting for ILA trigger (attempt $attempt/$max_attempts) on first real miss at \
$target_addr -- if the CPU is currently held in reset, release cpu_resetn now; if it's already \
running, no action needed, just wait for it to reach this address naturally."
    if {[catch {
        wait_on_hw_ila $ila
        set ila_data [upload_hw_ila_data $ila]
        write_hw_ila_data -csv_file $out_csv -force $ila_data
        set fh [open $out_csv r]
        set n_lines 0
        while {[gets $fh line] >= 0} { incr n_lines }
        close $fh
        if {$n_lines <= 2} {
            error "capture produced no sample rows ($n_lines lines total, header only)"
        }
        puts "CSV_ROW_COUNT: $n_lines"
    } err]} {
        puts "DDR_ILA_CAPTURE_ATTEMPT_FAILED (attempt $attempt/$max_attempts): $err"
    } else {
        set captured 1
    }
}

if {!$captured} {
    puts "DDR_ILA_CAPTURE_FAILED: all $max_attempts attempts hit an upload/readback error or \
produced zero sample rows."
    close_hw_target
    close_hw_manager
    exit 1
}

puts "DDR_ILA_CAPTURE_COMPLETE: wrote $out_csv"

close_hw_target
close_hw_manager
