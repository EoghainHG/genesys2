# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Eoghain Gray

## Arm, trigger, and read back the debug-only ILA capture from the
## ILA-instrumented genesys2_top_ddr build (see genesys2_top_ddr.sv's
## u_ila_dbg instance), targeting an interactive-console-freeze
## investigation: `vi` (or fast typing) can leave the shell totally
## unresponsive.
##
## UNLIKE fpga/capture_ddr_ila.tcl's cpu_rst_n trigger (a manual button
## press the operator controls directly), this script's trigger --
## dbg_stuck_flag, asserted only once the PLIC's own pending/in_service
## state has gone unresolved for ~17.8ms -- fires automatically if and when
## the real hardware bug reproduces. So the sequencing is: arm THIS script
## first (it prints "Waiting for ILA trigger..." once armed), THEN run the
## UART-side repro (open vi, type, etc.) from a separate PowerShell
## invocation against COM5 -- the two connections (JTAG here, UART there)
## are physically separate ports and don't interfere.
##
## Run from the project root (after program_ddr_ila.tcl + a fresh kernel
## reload + cpu_resetn released + shell confirmed alive):
##   vivado -mode batch -source fpga/capture_uart_freeze_ila.tcl -tclargs \
##     build/genesys2_top_ddr_ila.ltx build/uart_freeze_ila_capture.csv \
##     -log build/uart_freeze_ila_capture.log -journal build/uart_freeze_ila_capture.jou

set probes_file [lindex $argv 0]
set out_csv     [lindex $argv 1]
if {$probes_file eq ""} { set probes_file "build/genesys2_top_ddr_ila.ltx" }
if {$out_csv     eq ""} { set out_csv     "build/uart_freeze_ila_capture.csv" }

if {![file exists $probes_file]} {
    puts "UART_ILA_CAPTURE_FAILED: probes file not found at $probes_file -- run build_ddr_ila.tcl first"
    exit 1
}

open_hw_manager
connect_hw_server

set targets [get_hw_targets]
if {[llength $targets] != 1} {
    puts "UART_ILA_CAPTURE_FAILED: expected exactly 1 hw_target, found [llength $targets]: $targets"
    close_hw_manager
    exit 1
}
set target [lindex $targets 0]
open_hw_target $target

# Same fix as capture_ddr_ila.tcl: JTAG TCK must stay comfortably below
# clk_core's own rate (~56.26MHz now, was ~18.75MHz when this was first
# found) for reliable debug-hub waveform readback. Keeping the same
# conservative 2MHz that already proved reliable rather than pushing it
# just because clk_core got faster.
catch { set_property PARAM.FREQUENCY 2000000 $target }
puts "JTAG_TCK_FREQUENCY: [get_property PARAM.FREQUENCY $target] Hz"

set devs [get_hw_devices]
if {[llength $devs] != 1} {
    puts "UART_ILA_CAPTURE_FAILED: expected exactly 1 hw_device, found [llength $devs]: $devs"
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
puts "HW_ILA_CORES: $ila_cores"
if {[llength $ila_cores] != 1} {
    puts "UART_ILA_CAPTURE_FAILED: expected exactly 1 hw_ila core (u_ila_dbg), found \
[llength $ila_cores]: $ila_cores -- either the bitstream wasn't built with GENESYS2_ILA_DEBUG \
defined, program_ddr_ila.tcl hasn't been run yet, or $probes_file doesn't match the currently \
programmed bitstream."
    close_hw_target
    close_hw_manager
    exit 1
}
set ila [lindex $ila_cores 0]
puts "Using hw_ila core: $ila"
puts "HW_ILA_PROBES: [get_hw_probes -of_objects $ila]"

# Per capture_ddr_ila.tcl's own hard-won finding: Vivado auto-splits each
# RTL-side concatenation back into individually-named probes matching the
# original signal names -- dbg_stuck_flag should show up as its own named
# probe, not a probe0-bit-group. If the get_hw_probes call below returns
# anything other than exactly 1, run `report_property -all $ila` here to
# find the real name for this Vivado version before guessing further.
set trig_probe [get_hw_probes {*dbg_stuck_flag} -of_objects $ila]
if {[llength $trig_probe] != 1} {
    puts "UART_ILA_CAPTURE_FAILED: expected exactly 1 probe matching *dbg_stuck_flag, found \
[llength $trig_probe]: $trig_probe -- check HW_ILA_PROBES above for the real probe name."
    close_hw_target
    close_hw_manager
    exit 1
}

# CRITICAL ORDERING (capture_ddr_ila.tcl's own finding, re-applied here):
# reset_hw_ila wipes TRIGGER_COMPARE_VALUE/CONTROL.TRIGGER_POSITION back to
# IP defaults -- it must run BEFORE (re-)applying them, every time, or this
# re-arms with an effectively unconditional trigger instead of a real
# rising-edge match on dbg_stuck_flag.
catch { reset_hw_ila $ila }
set_property TRIGGER_COMPARE_VALUE eq1'bR $trig_probe
# Modest pretrigger margin (512 of the 8192-deep buffer) -- enough to see
# the last few genuinely successful RX/TX round trips immediately before
# the freeze, with the bulk of the window watching what the stuck state
# actually looks like afterward.
catch { set_property CONTROL.TRIGGER_POSITION 512 $ila }
puts "TRIGGER_CONFIG_CHECK: TRIGGER_COMPARE_VALUE=[get_property TRIGGER_COMPARE_VALUE $trig_probe] \
TRIGGER_POSITION=[get_property CONTROL.TRIGGER_POSITION $ila] -- must show eq1'bR here, NOT eq1'bX."

run_hw_ila $ila
puts "UART_ILA_ARMED: waiting for dbg_stuck_flag trigger -- run the UART-side repro against COM5 now."

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
} err]} {
    puts "UART_ILA_CAPTURE_FAILED: $err -- if this was a timeout, the freeze either didn't \
reproduce this run, or dbg_stuck_flag's real probe name/polarity needs re-checking."
    close_hw_target
    close_hw_manager
    exit 1
}

puts "UART_ILA_CAPTURE_COMPLETE: wrote $out_csv"

close_hw_target
close_hw_manager
