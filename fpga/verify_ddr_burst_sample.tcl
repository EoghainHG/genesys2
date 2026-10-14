# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Eoghain Gray

## Read-only sibling of fpga/load_ddr_program_burst.tcl's sparse verify
## pass -- exists to re-check the 2026-09-05 opensbi-hw load against real
## DDR3 using the CORRECTED burst-data parsing (see that script's own
## 2026-09-05 comment) WITHOUT repeating the ~5 minute write pass, since
## the write phase already reported 0 failures/0 retries across all 7777
## bursts and a direct diagnostic (fpga/diag_burst_readback.tcl) proved
## address 0's content is byte-for-byte correct -- this script exists only
## to extend that same confidence across the rest of the address space
## before trusting the loaded image for a boot attempt.
## Usage: vivado -mode batch -source fpga/verify_ddr_burst_sample.tcl \
##   -tclargs <file.hex> [burst_len] -log build/ddr_verify.log -journal build/ddr_verify.jou

set mem_file  [lindex $argv 0]
set burst_len [lindex $argv 1]
set load_base 0x00000000
if {$burst_len eq ""} { set burst_len 256 }

open_hw_manager
connect_hw_server
open_hw_target [lindex [get_hw_targets] 0]
set dev [lindex [get_hw_devices] 0]
current_hw_device $dev
refresh_hw_device -update_hw_probes false $dev
set axi_master [lindex [get_hw_axis -of_objects $dev] 0]
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
set n_bursts [expr {($n + $burst_len - 1) / $burst_len}]
puts "Verifying $n words ($n_bursts bursts, burst_len=$burst_len) from $mem_file"

set mismatches 0
set sampled 0
for {set b 0} {$b < $n_bursts} {incr b} {
    if {$b % 32 != 0 && $b != $n_bursts - 1} { continue }
    incr sampled
    set start [expr {$b * $burst_len}]
    set end   [expr {min($start + $burst_len, $n) - 1}]
    set len   [expr {$end - $start + 1}]
    set addr_hex [format "0x%08x" [expr {$load_base + $start * 4}]]
    set want_words [lrange $words $start $end]
    create_hw_axi_txn vb $axi_master -address $addr_hex -len $len -type read -force
    run_hw_axi [get_hw_axi_txns vb]
    set rresp [get_property STATUS.RRESP $axi_master]
    set raw_data [string trim [get_property DATA [get_hw_axi_txns vb]]]
    set got_words {}
    if {[string length $raw_data] == $len * 8} {
        set chunks {}
        for {set ci 0} {$ci < $len} {incr ci} {
            lappend chunks [string range $raw_data [expr {$ci * 8}] [expr {$ci * 8 + 7}]]
        }
        set got_words [lreverse $chunks]
    }
    set ok [expr {$rresp eq "OKAY" && [llength $got_words] == $len}]
    if {$ok} {
        foreach w $want_words g $got_words {
            if {[string tolower $w] ne [string tolower $g]} { set ok 0; break }
        }
    }
    if {!$ok} {
        puts "VERIFY_MISMATCH at burst $b, $addr_hex (words $start-$end): RRESP=$rresp got_len=[llength $got_words] want_len=$len"
        incr mismatches
    }
}
puts "VERIFY_STATS: $mismatches mismatches out of $sampled sampled bursts ($n_bursts total)"
if {$mismatches > 0} {
    puts "VERIFY_FAILED"
} else {
    puts "VERIFY_PASSED"
}

close_hw_target
close_hw_manager
