# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Eoghain Gray

## Load a program into DDR3 over JTAG via the jtag_axi IP (xilinx.com:ip:
## jtag_axi:1.2, part of the mig_bridge block design -- fpga/bd_build.tcl),
## using Vivado's Hardware Manager create_hw_axi_txn/run_hw_axi Tcl API.
## This board has no PS/ARM debug port at all, so this JTAG-AXI flow is
## how programs reach DDR3 before the CPU is released from reset.
##
## Requires genesys2_top_ddr.bit to already be programmed onto the board
## (this script does NOT program it -- see program_ddr.tcl, run that
## first) and the CPU held in reset (cpu_resetn pushbutton held down) for
## the entire duration this script runs -- the AXI infrastructure
## (SmartConnect/jtag_axi) is on its own reset domain gated only on
## init_calib_complete (see genesys2_top_ddr.sv's header), so it's usable
## immediately once DDR3 calibrates, independent of CPU reset state -- but
## the CPU itself must stay held until loading finishes, or it may start
## fetching from a partially-written program.
##
## IMPORTANT: load_base is 0x0, NOT 0x8000_0000, even though the CPU's own
## PC_RESET is 0x8000_0000 and that's the address a real program's own
## symbols/link script use. jtag_axi is a raw AXI master with no address
## translation of its own -- unlike icache/dcache, which reach DDR3 through
## axi4lite_master (#(.ADDR_OFFSET(32'h8000_0000))), which subtracts that
## offset before anything hits the AXI bus. SmartConnect's address map for
## jtag_axi's path (fpga/bd_build.tcl's assign_bd_address) only covers
## 0x0-0x3FFFFFFF, matching MIG's own AXI-side view of DDR3 -- writing to
## the CPU-style 0x8000_0000 directly here bounces off SmartConnect as a
## DECERR (confirmed the hard way: every read returned a fixed 0xdec0dee3
## regardless of address, traced to STATUS.BRESP/STATUS.RRESP = DECERR on
## the hw_axi object -- NOT a property of the hw_axi_txn object itself, a
## real gap in that object's exposed properties). Writing to the AXI-side
## 0x0 instead gives a clean OKAY/OKAY round-trip. The data content ends up
## being exactly what the CPU sees at 0x8000_0000 once it's released from
## reset, since icache/dcache apply the identical offset subtraction in
## the other direction.
##
## Run from the project root, with a word-per-line hex file as the payload
## (same format as sw/*.mem -- one 32-bit word per line, no "0x" prefix,
## loaded starting at AXI-side 0x0, which the CPU sees as 0x8000_0000):
##   vivado -mode batch -source fpga/load_ddr_program.tcl -tclargs sw/uart-test/uart_test.mem \
##     -log build/ddr_load.log -journal build/ddr_load.jou

set mem_file [lindex $argv 0]
set load_base 0x00000000

if {$mem_file eq ""} {
    puts "DDR_LOAD_FAILED: no .mem file given -- usage: vivado -mode batch -source fpga/load_ddr_program.tcl -tclargs <file.mem>"
    exit 1
}
if {![file exists $mem_file]} {
    puts "DDR_LOAD_FAILED: mem file not found at $mem_file"
    exit 1
}

open_hw_manager
connect_hw_server

set targets [get_hw_targets]
if {[llength $targets] != 1} {
    puts "DDR_LOAD_FAILED: expected exactly 1 hw_target, found [llength $targets]: $targets"
    close_hw_manager
    exit 1
}
open_hw_target [lindex $targets 0]

set devs [get_hw_devices]
if {[llength $devs] != 1} {
    puts "DDR_LOAD_FAILED: expected exactly 1 hw_device, found [llength $devs]: $devs"
    close_hw_target
    close_hw_manager
    exit 1
}
set dev [lindex $devs 0]
current_hw_device $dev
refresh_hw_device -update_hw_probes false $dev

# jtag_axi's hw_axi object name is auto-generated from the design's debug
# hub scan -- not guessable in advance, discovered here rather than
# assumed (same discipline as bd_build.tcl's own pin-name introspection).
set axi_masters [get_hw_axis -of_objects $dev]
puts "HW_AXI_MASTERS: $axi_masters"
if {[llength $axi_masters] != 1} {
    puts "DDR_LOAD_FAILED: expected exactly 1 hw_axi master (jtag_axi), found \
[llength $axi_masters]: $axi_masters -- either the debug hub isn't enumerating \
(bitstream not programmed yet? run program_ddr.tcl first) or the design has an \
unexpected number of JTAG-AXI-Master cores."
    close_hw_target
    close_hw_manager
    exit 1
}
set axi_master [lindex $axi_masters 0]
puts "Using hw_axi master: $axi_master"

set fh [open $mem_file r]
set words {}
while {[gets $fh line] >= 0} {
    set line [string trim $line]
    if {$line eq ""} { continue }
    lappend words $line
}
close $fh

set n [llength $words]
puts "Loading $n words from $mem_file starting at [format 0x%08x $load_base]"

## Status/response codes live on the hw_axi object itself (STATUS.BRESP /
## STATUS.RRESP, values like OKAY/DECERR/SLVERR) -- NOT on the individual
## hw_axi_txn object (confirmed via report_property -all on each: the txn
## object only has CLASS/CMD.*/DATA/HW_AXI/NAME/TYPE, no status field at
## all; a first attempt guessing `get_property STATUS <txn>` failed with
## "does not have a [STATUS] property"). This is what actually caught the
## address-offset bug above: every read returned a fixed 0xdec0dee3
## regardless of address (even a never-written one) with no visible error
## until STATUS.BRESP/STATUS.RRESP were found and showed DECERR.

set idx 0
set write_failures 0
set write_retries 0
foreach w $words {
    set addr_hex [format "0x%08x" [expr {$load_base + $idx * 4}]]
    set txn_name "wr_$idx"
    set attempt 0
    while {1} {
        create_hw_axi_txn $txn_name $axi_master -address $addr_hex -data $w -type write -force
        run_hw_axi [get_hw_axi_txns $txn_name]
        set bresp [get_property STATUS.BRESP $axi_master]
        if {$bresp eq "OKAY"} { break }
        incr attempt
        if {$attempt >= 4} {
            puts "DDR_LOAD_WRITE_FAILED at $addr_hex (word $idx = $w): BRESP=$bresp after $attempt attempts"
            incr write_failures
            break
        }
        incr write_retries
        after 20
    }
    after 5
    incr idx
}
puts "DDR_LOAD_WRITE_STATS: $write_failures permanent failures, $write_retries retries needed, out of $n words"

puts "DDR_LOAD_WROTE $n words"

# Read back and verify every word -- don't just trust the write response
# code; confirm DDR3 actually holds what was written.
set idx 0
set mismatches 0
set read_retries 0
foreach w $words {
    set addr_hex [format "0x%08x" [expr {$load_base + $idx * 4}]]
    set txn_name "rd_$idx"
    set want [string tolower $w]
    set attempt 0
    while {1} {
        create_hw_axi_txn $txn_name $axi_master -address $addr_hex -type read -force
        run_hw_axi [get_hw_axi_txns $txn_name]
        set rresp [get_property STATUS.RRESP $axi_master]
        set rdata [get_property DATA [get_hw_axi_txns $txn_name]]
        set got  [string tolower $rdata]
        if {$rresp eq "OKAY" && $got eq $want} { break }
        incr attempt
        if {$attempt >= 4} {
            puts "DDR_LOAD_MISMATCH at $addr_hex (word $idx): wrote $want, RRESP=$rresp, read back $got (after $attempt attempts)"
            incr mismatches
            break
        }
        incr read_retries
        after 20
    }
    after 5
    incr idx
}
puts "DDR_LOAD_READ_STATS: $mismatches permanent mismatches, $read_retries retries needed, out of $n words"

if {$mismatches > 0} {
    puts "DDR_LOAD_FAILED: $mismatches/$n words failed readback verification"
    close_hw_target
    close_hw_manager
    exit 1
}

puts "DDR_LOAD_COMPLETE: $n/$n words written and verified"

close_hw_target
close_hw_manager
