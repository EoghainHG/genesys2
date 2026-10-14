# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Eoghain Gray

## clk_core generated-clock constraint for genesys2_top_sd.sv.
## Identical to genesys2_top_ddr_timing.xdc (same clk_core divider, same
## instance names u_mig_bridge/u_bufg_core) -- see that file's own header
## for the full USED_IN_SYNTHESIS=false rationale and the /1, /6, /4
## divider history. Kept as a separate file (matching genesys2_top_ddr.xdc's
## own separate-timing-file convention) rather than sharing one across top
## levels, since each top level gets its own project run.
create_generated_clock -name clk_core -source [get_pins u_mig_bridge/ui_clk] -divide_by 4 [get_pins u_bufg_core/O]
