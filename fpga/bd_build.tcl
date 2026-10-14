# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Eoghain Gray

## Vivado Block Design build: MIG 7-Series DDR3 (imported from Digilent's
## verified mig.prj via CONFIG.XML_INPUT_FILE) + one SmartConnect doing
## AXI4-Lite(32b, clk_core)->AXI4(256b, ui_clk) protocol+width+clock
## conversion for icache, dcache, AND a JTAG-to-AXI-Master IP (xilinx.com:
## ip:jtag_axi:1.2) used to load a real program into DDR3 over JTAG before
## the CPU's own reset is released -- Genesys 2 has no PS at all, so this
## JTAG-AXI flow is how programs reach DDR3 before CPU release. jtag_axi
## lives entirely inside this BD (its JTAG side wires to the FPGA's BSCAN
## primitive automatically, no top-level port needed) -- only its
## aclk/aresetn come from the same clk_core/clk_core_aresetn external
## ports SmartConnect's own domain-0 already uses, deliberately NOT the
## CPU-gated reset (see genesys2_top_ddr.sv's two-reset-domain design: AXI
## infrastructure runs as soon as DDR3 calibrates, independent of whether
## the CPU itself is still held in reset by the cpu_resetn pushbutton --
## this is what makes loading-before-release possible at all). The BD
## contains only Xilinx IP, no project RTL.
##
## Run from the project root:
##   vivado -mode batch -source fpga/bd_build.tcl -log build/bd_build.log -journal build/bd_build.jou
##
## SmartConnect's exact per-clock pin names (aclk/aresetn for SI-domain-0,
## aclk1/aresetn1 for the ui_clk domain) and MIG's exact address segment
## name are NOT statically verifiable (SmartConnect's ports are
## Tcl-generator-driven; the segment name depends on IP-generated
## addressing metadata) -- this script prints the real values via `puts`
## immediately after each cell is created/configured, BEFORE using them,
## so a wrong guess fails loudly with the real names still visible in the
## log for a quick fix, rather than silently miswiring.

set part       xc7k325tffg900-2
set board_part digilentinc.com:genesys2:part0:1.1
set proj_dir   build/vivado_proj
set proj_name  genesys2_ddr
set bd_name    mig_bridge

set_param board.repoPaths [file normalize fpga/board_files]

file mkdir build
create_project -force $proj_name $proj_dir -part $part
set_property board_part $board_part [current_project]

create_bd_design $bd_name

create_bd_cell -type ip -vlnv xilinx.com:ip:mig_7series:4.2 mig
set_property CONFIG.XML_INPUT_FILE \
  [file normalize fpga/board_files/genesys2/H/mig.prj] [get_bd_cells mig]

puts "MIG_INTF_PINS: [get_bd_intf_pins -of_objects [get_bd_cells mig]]"
puts "MIG_PINS: [get_bd_pins -of_objects [get_bd_cells mig]]"

# Physical DDR3 pins + real 200MHz diff clock -- MIG owns the IBUFDS
# internally (SystemClock=Differential in mig.prj). This is now the only
# legal consumer of sysclk_p/n at the top level.
make_bd_intf_pins_external [get_bd_intf_pins mig/DDR3]
make_bd_intf_pins_external [get_bd_intf_pins mig/SYS_CLK]
set_property name DDR3    [get_bd_intf_ports DDR3_0]
set_property name SYS_CLK [get_bd_intf_ports SYS_CLK_0]

# sys_rst -- ACTIVE LOW per mig.prj's SysResetPolarity, matches cpu_resetn
# convention used everywhere else in this project.
make_bd_pins_external [get_bd_pins mig/sys_rst]
set_property name sys_rst [get_bd_ports sys_rst_0]

# init_calib_complete / ui_clk / ui_clk_sync_rst / mmcm_locked -- exposed
# so genesys2_top_ddr.sv's own reset synchronizer can gate CPU reset on
# real calibration completion instead of a human pushbutton. NOTE:
# mig/aresetn is deliberately NOT in this list -- it's an INPUT pin driven
# internally from the ui_rst_inv inverter below, not something to expose
# externally (would otherwise double-drive it).
foreach p {init_calib_complete ui_clk ui_clk_sync_rst mmcm_locked} {
  make_bd_pins_external [get_bd_pins mig/$p]
  set_property name $p [get_bd_ports ${p}_0]
}

# SmartConnect: 3 SI (icache, dcache, jtag_axi -- all clk_core domain) -> 1
# MI (mig/S_AXI, ui_clk domain). Handles AXI4-Lite->AXI4 protocol
# conversion, 32b->256b width conversion, AND the clk_core<->ui_clk CDC in
# one IP.
create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:1.0 smc
set_property -dict [list \
  CONFIG.NUM_SI    {3} \
  CONFIG.NUM_MI    {1} \
  CONFIG.NUM_CLKS  {2} \
] [get_bd_cells smc]

# jtag_axi: entirely BD-internal (no top-level port -- Vivado wires its
# JTAG side to the FPGA's BSCAN primitive automatically). 32-bit address/
# data to match SmartConnect's other two SI ports and axi4lite_master.sv's
# own port widths.
create_bd_cell -type ip -vlnv xilinx.com:ip:jtag_axi:1.2 jtag_axi
set_property -dict [list \
  CONFIG.M_AXI_ADDR_WIDTH {32} \
  CONFIG.M_AXI_DATA_WIDTH {32} \
] [get_bd_cells jtag_axi]

puts "JTAG_AXI_INTF_PINS: [get_bd_intf_pins -of_objects [get_bd_cells jtag_axi]]"
puts "JTAG_AXI_PINS: [get_bd_pins -of_objects [get_bd_cells jtag_axi]]"

puts "SMC_INTF_PINS: [get_bd_intf_pins -of_objects [get_bd_cells smc]]"
puts "SMC_PINS: [get_bd_pins -of_objects [get_bd_cells smc]]"

connect_bd_intf_net [get_bd_intf_pins smc/M00_AXI] [get_bd_intf_pins mig/S_AXI]

# mig/aresetn is MIG's own AXI-side reset INPUT (distinct from
# ui_clk_sync_rst, which is MIG's reset OUTPUT, active-high, synchronous to
# ui_clk) -- confirmed via the MIG_PINS dump above (both are separate real
# pins). Xilinx's own MIG7 AXI example design ties s_axi_aresetn from an
# inverted ui_clk_sync_rst -- same self-referential pattern here, via
# util_vector_logic (IP-only inside the BD, matching bd_build.tcl's own
# "BD = IP only" convention rather than adding RTL here).
#
# SmartConnect (per the SMC_PINS dump above) has exactly ONE aresetn pin
# total, not one per clock domain -- it's associated with aclk (domain 0,
# clk_core here) per Xilinx's own SmartConnect documentation (PG247); it
# handles CDC into its other internal clock domains itself. So smc/aresetn
# connects to clk_core_aresetn below, NOT to this inverted ui_clk_sync_rst.
create_bd_cell -type ip -vlnv xilinx.com:ip:util_vector_logic:2.0 ui_rst_inv
set_property CONFIG.C_SIZE {1} [get_bd_cells ui_rst_inv]
set_property CONFIG.C_OPERATION {not} [get_bd_cells ui_rst_inv]
connect_bd_net [get_bd_pins mig/ui_clk_sync_rst] [get_bd_pins ui_rst_inv/Op1]
connect_bd_net [get_bd_pins ui_rst_inv/Res] [get_bd_pins mig/aresetn]

connect_bd_net [get_bd_pins mig/ui_clk] [get_bd_pins smc/aclk1]

# clk_core/its reset (from genesys2_top_ddr.sv, driving SI-domain-0) come
# in as external BD inputs -- NOT generated inside this BD, since clk_core
# is a plain project-RTL divider off ui_clk (see top-level plan). Frequency
# hint is the planned ui_clk/12 divider target (~18.75MHz, conservative
# vs. the already-proven 20MHz) -- purely advisory for BD tooling; the
# real constraint comes from the top-level XDC's create_generated_clock.
create_bd_port -dir I -type clk -freq_hz 18750000 clk_core
create_bd_port -dir I -type rst clk_core_aresetn
connect_bd_net [get_bd_ports clk_core]          [get_bd_pins smc/aclk]
connect_bd_net [get_bd_ports clk_core_aresetn]  [get_bd_pins smc/aresetn]

# jtag_axi runs on the same clk_core/clk_core_aresetn pair -- at the top
# level this is deliberately the calib-only reset domain, NOT the
# CPU-gated one (see this file's header). connect_bd_intf_net for
# jtag_axi/M_AXI -> smc/S02_AXI happens in the foreach loop below (it's
# BD-internal, no external port).
connect_bd_net [get_bd_pins jtag_axi/aclk]    [get_bd_ports clk_core]
connect_bd_net [get_bd_pins jtag_axi/aresetn] [get_bd_ports clk_core_aresetn]
connect_bd_intf_net [get_bd_intf_pins jtag_axi/M_AXI] [get_bd_intf_pins smc/S02_AXI]

foreach {n ext} {0 icache 1 dcache} {
  make_bd_intf_pins_external [get_bd_intf_pins smc/S0${n}_AXI]
  set_property name S_AXI_LITE_${ext} [get_bd_intf_ports S0${n}_AXI_0]
}

# ASSOCIATED_BUSIF must be set after the external interface names exist
# (setting it earlier, before this foreach loop, produced "Associated
# interface by name S00_AXI not found" warnings on the first attempt at
# this script -- the external port names are what this property resolves
# against, not smc's own internal pin names). S02_AXI (jtag_axi) is
# BD-internal, not an external interface name, so it's deliberately not
# listed here.
set_property CONFIG.ASSOCIATED_BUSIF {S_AXI_LITE_icache:S_AXI_LITE_dcache} [get_bd_ports clk_core]

validate_bd_design
save_bd_design

puts "MIG_ADDR_SEGS: [get_bd_addr_segs -of_objects [get_bd_cells mig]]"

# Address map -- MIG's S_AXI decodes the full 1GB (30-bit byte address,
# matches C0_MEM_SIZE=1073741824 exactly) starting at 0x0.
set mig_seg [lindex [get_bd_addr_segs -of_objects [get_bd_cells mig]] 0]
puts "Using MIG address segment: $mig_seg"

puts "JTAG_AXI_ADDR_SPACES: [get_bd_addr_spaces -of_objects [get_bd_cells jtag_axi]]"
set jtag_axi_space [lindex [get_bd_addr_spaces -of_objects [get_bd_cells jtag_axi]] 0]
puts "Using jtag_axi address space: $jtag_axi_space"

assign_bd_address -target_address_space [get_bd_addr_spaces S_AXI_LITE_icache] \
  -offset 0x00000000 -range 1G $mig_seg
assign_bd_address -target_address_space [get_bd_addr_spaces S_AXI_LITE_dcache] \
  -offset 0x00000000 -range 1G $mig_seg
assign_bd_address -target_address_space $jtag_axi_space \
  -offset 0x00000000 -range 1G $mig_seg

validate_bd_design
save_bd_design

generate_target all [get_files [file join $proj_dir $proj_name.srcs sources_1 bd $bd_name $bd_name.bd]]
make_wrapper -files [get_files [file join $proj_dir $proj_name.srcs sources_1 bd $bd_name $bd_name.bd]] -top
add_files -norecurse [file join $proj_dir $proj_name.gen sources_1 bd $bd_name hdl ${bd_name}_wrapper.v]

puts "BD_BUILD_COMPLETE"
