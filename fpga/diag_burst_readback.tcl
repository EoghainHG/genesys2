# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Eoghain Gray

## One-shot diagnostic, not part of the normal bring-up sequence: probes the
## EXACT raw format Vivado's hw_axi -data/DATA properties use for a
## multi-beat (len > 1) transaction, since fpga/load_ddr_program_burst.tcl's
## first real-hardware run (2026-09-05) wrote all 7777 bursts cleanly (0
## retries) but every single sparse read-back verification failed even
## after retries -- a 100% failure rate across a uniform address sample,
## which points at a parsing/format bug in the script's own compare logic
## rather than real DDR3 corruption (already proven clean at the bit level
## by the 2026-09-03 ILA investigation). Run with:
##   vivado -mode batch -source fpga/diag_burst_readback.tcl -log build/diag_burst.log -journal build/diag_burst.jou
## Requires the board already programmed with genesys2_top_ddr.bit and the
## opensbi-hw payload already loaded (uses address 0x0, already known-good
## content from the write pass) -- read-only, makes no writes.

open_hw_manager
connect_hw_server
set targets [get_hw_targets]
open_hw_target [lindex $targets 0]
set dev [lindex [get_hw_devices] 0]
current_hw_device $dev
refresh_hw_device -update_hw_probes false $dev

set axi_master [lindex [get_hw_axis -of_objects $dev] 0]
puts "Using hw_axi master: $axi_master"

## Single-beat read first -- known-good baseline, same shape as the already-
## proven load_ddr_program.tcl per-word path.
create_hw_axi_txn rd1 $axi_master -address 0x00000000 -len 1 -type read -force
run_hw_axi [get_hw_axi_txns rd1]
puts "SINGLE_BEAT: RRESP=[get_property STATUS.RRESP $axi_master] RAW_DATA=\{[get_property DATA [get_hw_axi_txns rd1]]\}"

## 8-beat burst read at the same address -- fw_payload.hex's first 8 lines
## are known from direct file inspection: 00050433 000584b3 00060933
## 105000ef 00050833 (5th) ... print raw, unparsed, to see the real
## delimiter/word-count/ordering Vivado actually uses for len>1, rather
## than assuming it matches the single-beat case.
create_hw_axi_txn rd8 $axi_master -address 0x00000000 -len 8 -type read -force
run_hw_axi [get_hw_axi_txns rd8]
set raw [get_property DATA [get_hw_axi_txns rd8]]
puts "BURST_RAW_DATA=\{$raw\}"
puts "BURST_RAW_LENGTH_CHARS=[string length $raw]"
set split_ws [split [string trim $raw]]
puts "SPLIT_ON_WHITESPACE: llength=[llength $split_ws] -> $split_ws"

close_hw_target
close_hw_manager
