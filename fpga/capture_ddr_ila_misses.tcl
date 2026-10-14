# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Eoghain Gray

## Multi-window ILA capture variant: instead of triggering once on
## cpu_rst_n's rising edge (fpga/capture_ddr_ila.tcl -- proved the FIRST
## two real cache-line fills totally clean, 2026-09-03, but only covers
## the first ~8192 cycles post-release, while sw/uart-test/uart_test.mem's
## real DELAY_ITERS=4000 busy-loops between each of its 9 characters push
## total execution to an estimated ~72000-100000 cycles), this triggers
## on EVERY real post-release cache
## miss (ic_dbg_miss_pulse AND cpu_rst_n, ANDed via two comparators) using
## the ILA's WINDOW_COUNT feature (still "Basic" capture mode -- this
## Basic-tier license does NOT support Advanced trigger mode per
## this license tier, but basic multi-window re-arm on one
## simple AND'd trigger condition is a different, still-supported
## feature). This spends the same 8192-sample hardware budget on N
## SHORT snapshots around every real miss across the WHOLE run instead of
## one long continuous capture that never reaches most of the misses.
##
## Sequencing -- same protocol as capture_ddr_ila.tcl EXCEPT the CPU only
## needs releasing ONCE: hold cpu_resetn, run load_ddr_program.tcl if the
## DDR3 program payload isn't already known-good, run THIS script (arms,
## prints "Waiting for ILA trigger..."), release the button ONCE -- the
## CPU then runs the entire ~72k-100k cycle test autonomously while the
## ILA auto-re-arms and captures a window around every subsequent miss,
## with no further button interaction needed.
##
## Run from the project root:
##   vivado -mode batch -source fpga/capture_ddr_ila_misses.tcl -tclargs \
##     build/genesys2_top_ddr_ila.ltx build/ddr_ila_capture_misses.csv \
##     -log build/ddr_ila_capture_misses.log -journal build/ddr_ila_capture_misses.jou

set probes_file [lindex $argv 0]
set out_csv     [lindex $argv 1]
if {$probes_file eq ""} { set probes_file "build/genesys2_top_ddr_ila.ltx" }
if {$out_csv     eq ""} { set out_csv     "build/ddr_ila_capture_misses.csv" }

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

# See capture_ddr_ila.tcl's own header for why this matters: the debug
# hub/ILA clock (clk_core, ~18.754MHz) must run faster than JTAG TCK for
# reliable readback.
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
    puts "DDR_ILA_CAPTURE_FAILED: expected exactly 1 hw_ila core (u_ila_dbg), found \
[llength $ila_cores]: $ila_cores"
    close_hw_target
    close_hw_manager
    exit 1
}
set ila [lindex $ila_cores 0]
puts "Using hw_ila core: $ila"

set miss_probe [get_hw_probes {*ic_dbg_miss_pulse} -of_objects $ila]
set rst_probe  [get_hw_probes {*cpu_rst_n} -of_objects $ila]
if {[llength $miss_probe] != 1 || [llength $rst_probe] != 1} {
    puts "DDR_ILA_CAPTURE_FAILED: expected exactly 1 probe each for ic_dbg_miss_pulse \
($miss_probe) and cpu_rst_n ($rst_probe) -- check HW_ILA_PROBES: [get_hw_probes -of_objects $ila]"
    close_hw_target
    close_hw_manager
    exit 1
}

set n_windows 8
set max_attempts 3
set attempt 0
set captured 0
while {!$captured && $attempt < $max_attempts} {
    incr attempt
    # CRITICAL ORDERING (see capture_ddr_ila.tcl's own hard-won note):
    # reset_hw_ila wipes trigger/window config back to IP defaults, so it
    # must run FIRST each iteration, before (re-)applying every setting
    # below, every time -- not just once before the loop.
    catch { reset_hw_ila $ila }
    set_property CONTROL.WINDOW_COUNT $n_windows $ila
    catch { set_property CONTROL.TRIGGER_POSITION 64 $ila }
    # Edge (not level) trigger on the miss pulse (real bug hit,
    # 2026-09-03): a level match (eq1'b1) can stay satisfied for MULTIPLE
    # consecutive cycles (ic_dbg_miss_pulse is high for as long as
    # icache's state register is pinned in ST_IDLE with no hit -- e.g.
    # during the whole reset-held window, since icache's sequential FSM
    # can't leave ST_IDLE under async reset even though its combinational
    # miss-decision logic keeps re-evaluating every cycle), which let all
    # 8 requested windows consume back-to-back on the SAME initial
    # reset-release burst instead of spreading across the run -- the
    # exported CSV showed one continuous 8192-sample "window" with
    # "Sample in Window" never resetting, not 8 separate ones. A rising
    # edge only fires once per genuine new miss decision.
    set_property TRIGGER_COMPARE_VALUE eq1'bR $miss_probe
    set_property TRIGGER_COMPARE_VALUE eq1'b1 $rst_probe
    set_property CONTROL.TRIGGER_CONDITION AND $ila
    puts "TRIGGER_CONFIG_CHECK (attempt $attempt/$max_attempts): \
WINDOW_COUNT=[get_property CONTROL.WINDOW_COUNT $ila] \
DATA_DEPTH=[get_property CONTROL.DATA_DEPTH $ila] \
miss=[get_property TRIGGER_COMPARE_VALUE $miss_probe] \
rst=[get_property TRIGGER_COMPARE_VALUE $rst_probe] \
COND=[get_property CONTROL.TRIGGER_CONDITION $ila]"

    if {$attempt > 1} {
        puts "Retrying (attempt $attempt/$max_attempts) -- press cpu_resetn down and release it \
again once ready; this attempt needs a fresh trigger edge, not a replay of the last one."
    }
    run_hw_ila $ila
    puts "Waiting for ILA trigger (attempt $attempt/$max_attempts) -- release the cpu_resetn \
pushbutton now if not already released. The CPU then runs the WHOLE test autonomously -- no \
further button action needed once released."
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
