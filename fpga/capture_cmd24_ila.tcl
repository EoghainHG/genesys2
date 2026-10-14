# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Eoghain Gray

## Arm, trigger, and read back the debug-only ILA capture from the
## ILA-instrumented genesys2_top_sd build, investigating CMD24
## (WRITE_BLOCK)'s data-response-token timeout (checkpoint 13,
## cmd24_notoken_fail). See genesys2_top_sd.sv's u_ila_dbg instance and
## sw/sd-test/sd_init_read_write.S's dbg_dataresp_marker write for what's
## being captured and why a software-driven marker is the trigger instead
## of a raw-SPI-byte decode.
##
## UNLIKE fpga/capture_uart_freeze_ila.tcl's dbg_stuck_flag (which fires
## automatically, possibly tens of milliseconds after a human-paced UART
## repro), this trigger fires quickly and unconditionally on every run --
## the marker write happens a fraction of a second after cpu_resetn is
## released, as soon as the driver finishes CMD0/CMD8/ACMD41/CMD58/CMD17
## and CMD24's own data+CRC. So sequencing here is the reverse of that
## script's: arm THIS script FIRST while the CPU is still HELD in reset
## (right after fpga/load_ddr_program.tcl / fpga/program_sd_ila.tcl), THEN
## release cpu_resetn once this prints "waiting for trigger" -- arming
## after release risks missing the trigger in the race.
##
## Run from the project root (CPU still held in reset at this point):
##   vivado -mode batch -source fpga/capture_cmd24_ila.tcl -tclargs \
##     build/genesys2_top_sd_ila.ltx build/cmd24_ila_capture.csv \
##     -log build/cmd24_ila_capture.log -journal build/cmd24_ila_capture.jou

set probes_file [lindex $argv 0]
set out_csv     [lindex $argv 1]
if {$probes_file eq ""} { set probes_file "build/genesys2_top_sd_ila.ltx" }
if {$out_csv     eq ""} { set out_csv     "build/cmd24_ila_capture.csv" }

if {![file exists $probes_file]} {
    puts "CMD24_ILA_CAPTURE_FAILED: probes file not found at $probes_file -- run build_sd_ila.tcl first"
    exit 1
}

open_hw_manager
connect_hw_server

set targets [get_hw_targets]
if {[llength $targets] != 1} {
    puts "CMD24_ILA_CAPTURE_FAILED: expected exactly 1 hw_target, found [llength $targets]: $targets"
    close_hw_manager
    exit 1
}
set target [lindex $targets 0]
open_hw_target $target

# Same fix as capture_ddr_ila.tcl/capture_uart_freeze_ila.tcl: JTAG TCK must
# stay comfortably below clk_core's own rate (~56.26MHz) for reliable debug-
# hub waveform readback.
catch { set_property PARAM.FREQUENCY 2000000 $target }
puts "JTAG_TCK_FREQUENCY: [get_property PARAM.FREQUENCY $target] Hz"

set devs [get_hw_devices]
if {[llength $devs] != 1} {
    puts "CMD24_ILA_CAPTURE_FAILED: expected exactly 1 hw_device, found [llength $devs]: $devs"
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
    puts "CMD24_ILA_CAPTURE_FAILED: expected exactly 1 hw_ila core (u_ila_dbg), found \
[llength $ila_cores]: $ila_cores -- either the bitstream wasn't built with GENESYS2_ILA_DEBUG \
defined, program_sd_ila.tcl hasn't been run yet, or $probes_file doesn't match the currently \
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
# original signal names -- dbg_dataresp_marker should show up as its own
# named probe, not a probe0-bit-group. If the get_hw_probes call below
# returns anything other than exactly 1, run `report_property -all $ila`
# here to find the real name for this Vivado version before guessing further.
set trig_probe [get_hw_probes {*dbg_dataresp_marker} -of_objects $ila]
if {[llength $trig_probe] != 1} {
    puts "CMD24_ILA_CAPTURE_FAILED: expected exactly 1 probe matching *dbg_dataresp_marker, found \
[llength $trig_probe]: $trig_probe -- check HW_ILA_PROBES above for the real probe name."
    close_hw_target
    close_hw_manager
    exit 1
}

# CRITICAL ORDERING (capture_ddr_ila.tcl's own finding, re-applied here):
# reset_hw_ila wipes TRIGGER_COMPARE_VALUE/CONTROL.TRIGGER_POSITION back to
# IP defaults -- it must run BEFORE (re-)applying them, every time, or this
# re-arms with an effectively unconditional trigger instead of a real
# rising-edge match on dbg_dataresp_marker.
catch { reset_hw_ila $ila }
set_property TRIGGER_COMPARE_VALUE eq1'bR $trig_probe
# Modest pretrigger margin (4096 of the 65536-deep buffer) -- enough to see
# roughly the last ~128 real data bytes plus the CRC16 bytes immediately
# before the marker, with the bulk of the window (~63488 samples, ~1984
# byte-times at the ~14MHz data-phase SCLK) watching what the card actually
# drives (or doesn't) once the data-response poll loop starts.
catch { set_property CONTROL.TRIGGER_POSITION 4096 $ila }
puts "TRIGGER_CONFIG_CHECK: TRIGGER_COMPARE_VALUE=[get_property TRIGGER_COMPARE_VALUE $trig_probe] \
TRIGGER_POSITION=[get_property CONTROL.TRIGGER_POSITION $ila] -- must show eq1'bR here, NOT eq1'bX."

run_hw_ila $ila
puts "CMD24_ILA_ARMED: waiting for dbg_dataresp_marker trigger -- release cpu_resetn now (the CPU \
must have been held in reset up to this point, or the marker may already have fired before arming)."

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
    puts "CMD24_ILA_CAPTURE_FAILED: $err -- if this was a timeout, cpu_resetn likely wasn't \
released after arming, or dbg_dataresp_marker's real probe name/polarity needs re-checking."
    close_hw_target
    close_hw_manager
    exit 1
}

puts "CMD24_ILA_CAPTURE_COMPLETE: wrote $out_csv"

close_hw_target
close_hw_manager
