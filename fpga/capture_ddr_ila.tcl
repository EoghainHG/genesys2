# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Eoghain Gray

## Arm, trigger, and read back the debug-only ILA capture from the
## ILA-instrumented genesys2_top_ddr build (fpga/build_ddr_ila.tcl / the
## GENESYS2_ILA_DEBUG-guarded u_ila_dbg instance in
## fpga/genesys2_top_ddr.sv) -- added to root-cause the open,
## non-deterministic instruction-fetch data-corruption bug in
## an "open bug, NOT resolved" investigation.
##
## Distinct from fpga/uart_capture.ps1 (Windows-side PowerShell, captures
## UART BYTES over COM5 -- unrelated). This captures an internal JTAG
## waveform via Vivado's hw_ila Tcl API and writes it to a plain CSV so it
## can be read back and analyzed directly (rather than needing Vivado's own
## waveform GUI).
##
## SEQUENCING -- READ BEFORE RUNNING:
##   1. build_ddr_ila.tcl has completed (DDR_ILA_BUILD_COMPLETE).
##   2. program_ddr_ila.tcl has programmed the board.
##   3. cpu_resetn is HELD DOWN, and fpga/load_ddr_program.tcl has loaded
##      sw/uart-test/uart_test.mem while held (per that script's own
##      header) -- KEEP HOLDING the button through this script starting.
##   4. Run THIS script. It arms the ILA and prints "Waiting for ILA
##      trigger...". ONLY THEN release cpu_resetn -- that release is what
##      the trigger (cpu_rst_n's rising edge) fires on.
##
## Run from the project root:
##   vivado -mode batch -source fpga/capture_ddr_ila.tcl -tclargs \
##     build/genesys2_top_ddr_ila.ltx build/ddr_ila_capture.csv \
##     -log build/ddr_ila_capture.log -journal build/ddr_ila_capture.jou

set probes_file [lindex $argv 0]
set out_csv     [lindex $argv 1]
if {$probes_file eq ""} { set probes_file "build/genesys2_top_ddr_ila.ltx" }
if {$out_csv     eq ""} { set out_csv     "build/ddr_ila_capture.csv" }

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

# Real-world fix (found via research, 2026-09-03, after repeated "ERROR:
# [Labtools 27-3312] Data read from hw_ila is corrupted. Unable to upload
# waveform." on genuinely-triggered captures): the debug hub/ILA's own
# clock -- clk_core here, ~18.754MHz (see genesys2_top_ddr.sv) -- needs to
# run comfortably FASTER than hw_server's JTAG TCK rate for reliable
# debug-hub readback; if TCK is at or above the debug clock, waveform
# upload corrupts intermittently, which matches this design's symptom
# exactly (clk_core is unusually slow for a debug clock -- every prior
# Xilinx-debug-core design in this project family ran hardened logic far
# faster). Lower TCK well below 18.754MHz rather than raise clk_core
# (clk_core's rate is load-bearing for the CPU pipeline's own timing
# closure, not something to change just for debug convenience).
catch { set_property PARAM.FREQUENCY 2000000 $target }
puts "JTAG_TCK_FREQUENCY: [get_property PARAM.FREQUENCY $target] Hz (lowered from hw_server's \
default to stay well under clk_core's ~18.754MHz debug-hub clock -- see the comment above if this \
property name is wrong for this Vivado version)."

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
puts "HW_ILA_CORES: $ila_cores"
if {[llength $ila_cores] != 1} {
    puts "DDR_ILA_CAPTURE_FAILED: expected exactly 1 hw_ila core (u_ila_dbg), found \
[llength $ila_cores]: $ila_cores -- either the bitstream wasn't built with GENESYS2_ILA_DEBUG \
defined (see build_ddr_ila.tcl), program_ddr_ila.tcl hasn't been run yet, or $probes_file doesn't \
match the currently-programmed bitstream."
    close_hw_target
    close_hw_manager
    exit 1
}
set ila [lindex $ila_cores 0]
puts "Using hw_ila core: $ila"
puts "HW_ILA_PROBES: [get_hw_probes -of_objects $ila]"

# Trigger: cpu_rst_n's rising edge (the button release). NOTE (found live,
# 2026-09-03): Vivado's hw_ila object does NOT expose generic probeN names
# for a directly-instantiated ila_0 -- it auto-splits each RTL-side
# concatenation (probe0={icmem_addr,icmem_ren,...}, probe4={cpu_rst_n,
# axi_infra_rst_n}, etc., see genesys2_top_ddr.sv's u_ila_dbg instance)
# back into individually-named probes matching the original signal names
# (confirmed via the HW_ILA_PROBES line above: cpu_rst_n and
# axi_infra_rst_n each show up as their own named probe, not a combined
# "probe4"). So the trigger is set directly on the named cpu_rst_n probe,
# not a probe4 bit-group. If set_property below still fails with a bad
# property/probe name, run `report_property -all $ila` / `report_property
# -all $trig_probe` first to find the real names for this Vivado version --
# same discovery discipline as load_ddr_program.tcl's own
# STATUS.BRESP/STATUS.RRESP story.
set trig_probe [get_hw_probes {*cpu_rst_n} -of_objects $ila]
if {[llength $trig_probe] != 1} {
    puts "DDR_ILA_CAPTURE_FAILED: expected exactly 1 probe matching *cpu_rst_n, found \
[llength $trig_probe]: $trig_probe -- check HW_ILA_PROBES above for the real probe name."
    close_hw_target
    close_hw_manager
    exit 1
}

# Retry loop (found live, 2026-09-03): wait_on_hw_ila/upload_hw_ila_data can
# fail two different ways that don't always throw a catchable Tcl error --
# "ERROR: [Labtools 27-3312] Data read from hw_ila is corrupted. Unable to
# upload waveform." (does throw), and "WARNING: [Labtools 27-157] hw_ila
# stopped. No data to upload." (does NOT throw -- upload_hw_ila_data/
# write_hw_ila_data both "succeed" against zero samples, silently producing
# a CSV with only its header row). Both look like transient JTAG/hw_server
# readback flakiness over the WSL<->Windows USB tunnel (or stale hw_ila
# state left over from a PRIOR script invocation that exited mid-capture
# without cleanly resetting the core -- hence the unconditional
# reset_hw_ila below, on attempt 1 too, not just retries), not a design
# bug -- matches this project's existing retry-with-backoff pattern in
# load_ddr_program.tcl. Real sample data is confirmed by actually counting
# CSV rows after write, since "no exception thrown" alone is not enough.
# IMPORTANT: each retry needs a FRESH cpu_rst_n rising edge (press-and-
# release the button again) -- run_hw_ila re-arms for a brand new trigger,
# not a replay of the last one.
#
# CRITICAL ORDERING (real bug hit and fixed, 2026-09-03): reset_hw_ila
# resets ALL trigger/capture settings back to IP defaults, including
# TRIGGER_COMPARE_VALUE (back to don't-care, "eq1'bX") and
# CONTROL.TRIGGER_POSITION (back to the IP's 50% default, 4096) --
# confirmed live via `report_property -all` on the probe after a run that
# called reset_hw_ila once before the loop's first iteration and never
# reconfigured the trigger afterward: it silently re-armed with an
# effectively unconditional trigger (matches on the very first sample)
# instead of "wait for cpu_rst_n's rising edge," producing an
# instant, empty-looking capture every attempt with no thrown error. So
# reset_hw_ila must run FIRST each iteration, and the trigger compare
# value / position must be (re-)applied AFTER it, every time, not just
# once before the loop.
set max_attempts 3
set attempt 0
set captured 0
while {!$captured && $attempt < $max_attempts} {
    incr attempt
    catch { reset_hw_ila $ila }
    set_property TRIGGER_COMPARE_VALUE eq1'bR $trig_probe
    # Small pretrigger margin (~256 of the 8192-deep buffer) -- the vast
    # majority of the window is POST-trigger, since all AXI/icache fetch
    # activity of interest happens shortly after cpu_rst_n releases (no
    # cache-index aliasing at SETS=16 for this 37-word program -- see
    # build_ddr_ila.tcl's header).
    catch { set_property CONTROL.TRIGGER_POSITION 256 $ila }
    puts "TRIGGER_CONFIG_CHECK (attempt $attempt/$max_attempts): \
TRIGGER_COMPARE_VALUE=[get_property TRIGGER_COMPARE_VALUE $trig_probe] \
TRIGGER_POSITION=[get_property CONTROL.TRIGGER_POSITION $ila] -- must show eq1'bR here, NOT \
eq1'bX, or this attempt will trigger on garbage again (see the CRITICAL ORDERING note above)."
    if {$attempt > 1} {
        puts "Retrying (attempt $attempt/$max_attempts) -- press cpu_resetn down and release it \
again once ready; this attempt needs a fresh trigger edge, not a replay of the last one."
    }
    run_hw_ila $ila
    puts "Waiting for ILA trigger (attempt $attempt/$max_attempts) -- release the cpu_resetn \
pushbutton now if not already released..."
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
        puts "DDR_ILA_CAPTURE_ATTEMPT_FAILED (attempt $attempt/$max_attempts): $err"
    } else {
        set captured 1
    }
}

if {!$captured} {
    puts "DDR_ILA_CAPTURE_FAILED: all $max_attempts attempts hit an upload/readback error or \
produced zero sample rows -- looks like transient JTAG/hw_server flakiness (Labtools 27-3312 / \
27-157) rather than a design bug, since the trigger itself armed correctly every time. If it \
keeps failing, check the physical JTAG cable/USB connection for marginal contact, or try a fresh \
disconnect_hw_server/reconnect."
    close_hw_target
    close_hw_manager
    exit 1
}

puts "DDR_ILA_CAPTURE_COMPLETE: wrote $out_csv"

close_hw_target
close_hw_manager
