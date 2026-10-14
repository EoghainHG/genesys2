# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Eoghain Gray

## Burst-capable variant of load_ddr_program.tcl for loading large
## (multi-MB) payloads (OpenSBI+kernel+FDT fw_payload.hex, see
## build-opensbi-hw in the top-level Makefile) into DDR3 over JTAG via the
## same jtag_axi IP (xilinx.com:ip:jtag_axi:1.2, fpga/bd_build.tcl) used by
## load_ddr_program.tcl. A SEPARATE file from load_ddr_program.tcl (not a
## parameterized variant of it) so the already-proven, stress-tested
## per-word script (37/37 words, 0 failures, repeated) is
## never touched or put at risk by this new, larger-blast-radius,
## AS-YET-UNVERIFIED-ON-REAL-HARDWARE burst path.
##
## WHY THIS EXISTS: load_ddr_program.tcl does one 32-bit word per
## create_hw_axi_txn/run_hw_axi round-trip (each costing ~250-300ms in
## this real environment), PLUS a full separate read-back-verify pass.
## For a ~10MB payload that's ~16.7 DAYS. This script instead issues
## 256-word (1024-byte) AXI4 burst transactions -- ~500x fewer round
## trips -- and verifies only a sparse sample instead of every word.
##
## *** MANDATORY FIRST REAL-HARDWARE STEP, NOT YET DONE (no Vivado access
## in the session that wrote this script) *** -- before relying on this
## script for anything, with the design already programmed
## (program_ddr.tcl) and hw_server connected, run:
##   report_property -all [get_hw_axis -of_objects [lindex [get_hw_devices] 0]]
## and confirm the exposed protocol property (exact name TBD -- discover
## it the same way this project's other scripts discover undocumented
## property names, e.g. load_ddr_program.tcl's own STATUS.BRESP/RRESP
## discovery) reads AXI4 (full), not AXI4LITE. fpga/bd_build.tcl's
## jtag_axi cell (~line 92-96) is only configured with
## CONFIG.M_AXI_ADDR_WIDTH/CONFIG.M_AXI_DATA_WIDTH -- no CONFIG.PROTOCOL
## override -- so burst support depends entirely on the IP's own default.
##
## If it turns out to be AXI4LITE: -len > 1 will fail outright (AXI4LITE
## has no burst capability -- every transaction is exactly 1 beat), and
## the real fallback is either (a) fpga/bd_build.tcl's jtag_axi cell gains
## CONFIG.PROTOCOL {AXI4}, requiring a full BD regeneration + bitstream
## rebuild -- the ONE scenario this plan identified that would touch the
## bitstream -- or (b) fall back to load_ddr_program.tcl's proven per-word
## path against a much more aggressively trimmed payload (not a path to a
## real Linux+busybox boot as scoped -- last resort only).
##
## Burst-length choice (default 256, AXI4 INCR max at 32-bit width: 256
## beats x 4 bytes = 1024 bytes/txn): load_base=0x0 is 4KB-aligned, and
## every 1024-byte burst starting from a 4KB-aligned base is GUARANTEED
## to never straddle a 4KB boundary (a hard AXI4 requirement) -- true by
## construction for any contiguous sequence of 1024-byte bursts from that
## base, not something checked per-transaction here.
##
## Usage (mirrors load_ddr_program.tcl's own convention):
##   vivado -mode batch -source fpga/load_ddr_program_burst.tcl -tclargs \
##     <file.hex> [burst_len] \
##     -log build/ddr_load_opensbi.log -journal build/ddr_load_opensbi.jou
## burst_len defaults to 256 if omitted.

set mem_file   [lindex $argv 0]
set burst_len  [lindex $argv 1]
set load_base  0x00000000

if {$mem_file eq ""} {
    puts "DDR_LOAD_FAILED: no hex file given -- usage: vivado -mode batch -source fpga/load_ddr_program_burst.tcl -tclargs <file.hex> \[burst_len\]"
    exit 1
}
if {![file exists $mem_file]} {
    puts "DDR_LOAD_FAILED: hex file not found at $mem_file"
    exit 1
}
if {$burst_len eq ""} { set burst_len 256 }

open_hw_manager
connect_hw_server

set targets [get_hw_targets]
if {[llength $targets] != 1} {
    puts "DDR_LOAD_FAILED: expected exactly 1 hw_target, found [llength $targets]: $targets"
    close_hw_manager
    exit 1
}
open_hw_target [lindex $targets 0]

# JTAG TCK bump (2026-09-06): unlike capture_ddr_ila.tcl's ILA readback --
# which must stay well BELOW clk_core (~56.26MHz) because the debug hub's
# waveform upload runs synchronous to the design clock -- this script talks
# to jtag_axi (xilinx.com:ip:jtag_axi:1.2), which bridges the FPGA's BSCAN
# primitive to AXI on its own, TCK-domain-crossing logic, not the debug
# hub. hw_server's default TCK was never explicitly set here before,
# leaving each create_hw_axi_txn/run_hw_axi round trip (7777+ of them for a
# real Linux payload) paying whatever the untuned default cost per bit.
# 15MHz is a conservative, widely-supported rate for this class of
# Digilent JTAG-HS-family cable on a Kintex-7 -- not pushed to a
# theoretical max, since a failed/corrupted load costs far more (a full
# re-run) than a conservative TCK choice costs in speed.
catch { set_property PARAM.FREQUENCY 15000000 [lindex $targets 0] }
puts "JTAG_TCK_FREQUENCY: [get_property PARAM.FREQUENCY [lindex $targets 0]] Hz"

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

# Same discovery discipline as load_ddr_program.tcl -- the hw_axi object
# name is auto-generated, not guessable in advance.
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

## MANDATORY PRE-FLIGHT CHECK -- see this script's own header. Print the
## hw_axi object's full property set so its protocol can be visually
## confirmed as AXI4 (not AXI4LITE) before committing to a long burst
## load -- this does NOT programmatically abort on AXI4LITE (the exact
## property name reporting this was not confirmed against real hardware
## when this script was written), so read this output before trusting
## anything past this point.
puts "=== hw_axi PRE-FLIGHT PROPERTY DUMP (confirm AXI4, not AXI4LITE, before trusting burst mode) ==="
puts [report_property -all -return_string $axi_master]
puts "=== end pre-flight dump ==="

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
puts "Loading $n words ($n_bursts bursts, burst_len=$burst_len) from $mem_file starting at [format 0x%08x $load_base]"

## Status/response codes live on the hw_axi object itself (STATUS.BRESP /
## STATUS.RRESP), same as load_ddr_program.tcl -- see that script's own
## header for the full discovery story (STATUS.* is NOT on the individual
## hw_axi_txn object).

set write_failures 0
set write_retries 0
for {set b 0} {$b < $n_bursts} {incr b} {
    set start [expr {$b * $burst_len}]
    set end   [expr {min($start + $burst_len, $n) - 1}]
    set len   [expr {$end - $start + 1}]
    set addr_hex [format "0x%08x" [expr {$load_base + $start * 4}]]
    set data_str [join [lrange $words $start $end]]
    set txn_name "wr_$b"
    set attempt 0
    while {1} {
        create_hw_axi_txn $txn_name $axi_master -address $addr_hex -data $data_str -len $len -type write -force
        run_hw_axi [get_hw_axi_txns $txn_name]
        set bresp [get_property STATUS.BRESP $axi_master]
        if {$bresp eq "OKAY"} { break }
        incr attempt
        if {$attempt >= 4} {
            puts "DDR_LOAD_WRITE_FAILED at burst $b, $addr_hex (words $start-$end): BRESP=$bresp after $attempt attempts"
            incr write_failures
            break
        }
        incr write_retries
        after 20
    }
    after 5
}
puts "DDR_LOAD_WRITE_STATS: $write_failures permanent failures, $write_retries retries needed, out of $n_bursts bursts"

puts "DDR_LOAD_WROTE $n words ($n_bursts bursts, burst_len=$burst_len)"

## Sparse verification, not 100% read-back: every 32nd burst (indices
## 0, 32, 64, ...), plus the final burst unconditionally (it may be
## partial and generally isn't a multiple of 32). Because
## build-opensbi-hw's FW_PAYLOAD_OFFSET is MiB-aligned (1MiB = 1024
## bursts of 1024 bytes each), the kernel-start burst lands on an exact
## multiple of 32 -- covered "for free" by this uniform sample, no
## special-cased anchor needed. (FW_PAYLOAD_FDT_ADDR does NOT mark a
## static location in this loaded image at all -- confirmed 2026-09-03
## by inspecting the built fw_payload.elf's own symbols: the FDT is
## compiled in as a small `.rodata` blob (`fw_fdt_bin`, near the image's
## own start) and OpenSBI's own startup code copies it to
## FW_PAYLOAD_FDT_ADDR at BOOT TIME, on real hardware, after this whole
## image is already loaded -- nothing needs to be pre-placed there by
## this loader. FW_PAYLOAD_FDT_ADDR still matters for a genuinely
## different reason: it must not collide with anything Linux itself
## uses early in boot, which is why build-opensbi-hw still picks it with
## real margin past the kernel's end -- it just doesn't affect this
## script's own transfer size the way earlier planning assumed.) AXI4's
## own per-burst BRESP=OKAY already gives write acknowledgment for every
## burst regardless of sampling; the residual
## risk this sample guards against is JTAG link-level transients, not a
## DDR3/MIG integrity bug (independently proven with zero known issues
## as of this project's ILA investigation).
set mismatches 0
set read_retries 0
set sampled 0
for {set b 0} {$b < $n_bursts} {incr b} {
    if {$b % 32 != 0 && $b != $n_bursts - 1} { continue }
    incr sampled
    set start [expr {$b * $burst_len}]
    set end   [expr {min($start + $burst_len, $n) - 1}]
    set len   [expr {$end - $start + 1}]
    set addr_hex [format "0x%08x" [expr {$load_base + $start * 4}]]
    set want_words [lrange $words $start $end]
    set txn_name "rd_$b"
    set attempt 0
    while {1} {
        create_hw_axi_txn $txn_name $axi_master -address $addr_hex -len $len -type read -force
        run_hw_axi [get_hw_axi_txns $txn_name]
        set rresp [get_property STATUS.RRESP $axi_master]
        ## REAL BUG FOUND AND FIXED 2026-09-05 (first real-hardware run of
        ## this script): for a multi-beat (len>1) transaction, the DATA
        ## property is NOT a whitespace-separated list of per-beat hex
        ## words -- it's a single concatenated hex string with NO
        ## separator, ordered MOST-SIGNIFICANT-BEAT-FIRST (the LAST beat,
        ## i.e. the highest address in the burst, appears leftmost; the
        ## FIRST beat / lowest address appears rightmost). Confirmed via
        ## fpga/diag_burst_readback.tcl against real hardware: an 8-word
        ## burst read at address 0 returned
        ## "00090633000485b30004053300050833105000ef00060933000584b300050433"
        ## -- the LAST 8 hex chars (rightmost) are word0 (00050433, matches
        ## fw_payload.hex line 1), the FIRST 8 hex chars (leftmost) are
        ## word7. The original code did a plain whitespace split, which
        ## always produced exactly ONE "word" (the whole 64+ char blob) for
        ## any len>1 transaction -- silently failing the
        ## [llength $got_words] == $len check on literally every sampled
        ## burst (100% of the 244 samples in the 2026-09-05 run), even
        ## though the real written data was already byte-for-byte correct.
        ## Fix: split the raw string into fixed 8-hex-char chunks in the
        ## order they appear, then reverse the chunk list to recover
        ## address order (chunk0 in address order = the LAST chunk in the
        ## raw string).
        set raw_data [string trim [get_property DATA [get_hw_axi_txns $txn_name]]]
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
        if {$ok} { break }
        incr attempt
        if {$attempt >= 4} {
            puts "DDR_LOAD_MISMATCH at burst $b, $addr_hex (words $start-$end): RRESP=$rresp after $attempt attempts"
            incr mismatches
            break
        }
        incr read_retries
        after 20
    }
    after 5
}
puts "DDR_LOAD_READ_STATS: $mismatches permanent mismatches, $read_retries retries needed, out of $sampled sampled bursts ([expr {$sampled * 100.0 / $n_bursts}]% of $n_bursts total)"

if {$mismatches > 0 || $write_failures > 0} {
    puts "DDR_LOAD_FAILED: $write_failures write failures, $mismatches/$sampled sampled bursts failed readback verification"
    close_hw_target
    close_hw_manager
    exit 1
}

puts "DDR_LOAD_COMPLETE: $n words / $n_bursts bursts written, $sampled bursts spot-verified, 0 failures"

close_hw_target
close_hw_manager
