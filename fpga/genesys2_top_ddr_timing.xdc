# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Eoghain Gray

## clk_core generated-clock constraint for genesys2_top_ddr.sv.
##
## Deliberately a SEPARATE constraint file from genesys2_top_ddr.xdc, added
## in build_ddr.tcl with USED_IN_SYNTHESIS=false (so Vivado skips it during
## synth_design and applies it only during implementation instead). This is
## the standard, documented technique (UG903) for constraining a pin that
## lives inside an out-of-context-synthesized IP/Block Design cell from the
## top level: at plain synthesis time, mig_bridge_wrapper's internals
## (including its ui_clk output pin) are still an unlinked black box, so a
## top-level create_generated_clock sourced from a pin inside it can't
## resolve yet. Confirmed the hard way while building
## genesys2_top_ddr_calib.sv: the exact same constraint applied at normal
## synthesis time produced "CRITICAL WARNING: ... No valid object(s) found
## for '-source [get_pins u_mig_bridge/ui_clk]'" and 16742
## unconstrained_internal_endpoints -- by the time implementation runs
## (opt_design onward), the design is fully linked/flattened and this pin
## resolves correctly.
## divide_by 1 (direct ui_clk connect, no divider) was tried 2026-09-05 and
## FAILED real timing badly (11,891/61,025 clk_core-domain endpoints
## violated setup, WNS=-7.695ns). divide_by 6 (~37.5MHz) was tried next and
## PASSED cleanly (0 unconstrained_internal_endpoints, WNS=+8.184ns,
## WHS=+0.049ns), verified end-to-end on real hardware -- see
## genesys2_top_ddr.sv's module header for the full history. divide_by 4
## (~56.3MHz) is the next attempt, close enough to the critical-path
## estimate implied by /6's margin to have a real chance.
create_generated_clock -name clk_core -source [get_pins u_mig_bridge/ui_clk] -divide_by 4 [get_pins u_bufg_core/O]
