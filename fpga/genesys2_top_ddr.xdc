# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Eoghain Gray

## Genesys 2 pin constraints for genesys2_top_ddr.sv
## Same source/verification as genesys2_top_uart.xdc -- see that file's header.
##
## NOTE: sysclk_p/sysclk_n and all DDR3_* pins are deliberately NOT
## constrained here -- MIG's own IP-generated XDC (produced automatically
## from mig.prj's full PinSelection block during fpga/bd_build.tcl) already
## owns those pins.
##
## NOTE: the clk_core generated-clock constraint lives in a SEPARATE file,
## fpga/genesys2_top_ddr_timing.xdc, added with USED_IN_SYNTHESIS=false in
## build_ddr.tcl -- see that file's header and genesys2_top_ddr.sv's module
## header for why (mig_bridge_wrapper's internals are still an
## out-of-context black box at plain synthesis time).

## CPU reset pushbutton -- active-low, now a debounced TOGGLE in RTL (see
## genesys2_top_ddr.sv's module header and its cpu_held_toggle logic).
## Stale note removed 2026-09-03: this does NOT drive MIG's sys_rst --
## that's tied to a constant deasserted 1'b1 in genesys2_top_ddr.sv,
## deliberately independent of this button (see that file's own
## mig_bridge_wrapper instantiation comment and the reset-domain memory
## lesson from this project's history for why: tying MIG's reset to this
## same button would hold DDR3 itself in reset for as long as the button
## is held, hanging the exact JTAG-AXI loading window this button exists
## to enable).
set_property -dict { PACKAGE_PIN R19 IOSTANDARD LVCMOS33 } [get_ports { cpu_resetn }]; #IO_0_14 Sch=cpu_resetn
set_false_path -from [get_ports { cpu_resetn }]

## LEDs
set_property -dict { PACKAGE_PIN T28  IOSTANDARD LVCMOS33 } [get_ports { led[0] }]; #IO_L11N_T1_SRCC_14 Sch=led[0]
set_property -dict { PACKAGE_PIN V19  IOSTANDARD LVCMOS33 } [get_ports { led[1] }]; #IO_L19P_T3_A10_D26_14 Sch=led[1]
set_property -dict { PACKAGE_PIN U30  IOSTANDARD LVCMOS33 } [get_ports { led[2] }]; #IO_L15N_T2_DQS_DOUT_CSO_B_14 Sch=led[2]
set_property -dict { PACKAGE_PIN U29  IOSTANDARD LVCMOS33 } [get_ports { led[3] }]; #IO_L15P_T2_DQS_RDWR_B_14 Sch=led[3]
set_property -dict { PACKAGE_PIN V20  IOSTANDARD LVCMOS33 } [get_ports { led[4] }]; #IO_L19N_T3_A09_D25_VREF_14 Sch=led[4]
set_property -dict { PACKAGE_PIN V26  IOSTANDARD LVCMOS33 } [get_ports { led[5] }]; #IO_L16P_T2_CSI_B_14 Sch=led[5]
set_property -dict { PACKAGE_PIN W24  IOSTANDARD LVCMOS33 } [get_ports { led[6] }]; #IO_L20N_T3_A07_D23_14 Sch=led[6]
set_property -dict { PACKAGE_PIN W23  IOSTANDARD LVCMOS33 } [get_ports { led[7] }]; #IO_L20P_T3_A08_D24_14 Sch=led[7]

## UART -- FTDI USB-UART bridge.
set_property -dict { PACKAGE_PIN Y23 IOSTANDARD LVCMOS33 } [get_ports { uart_rx_out }]; #Sch=uart_rx_out
set_property -dict { PACKAGE_PIN Y20 IOSTANDARD LVCMOS33 } [get_ports { uart_tx_in }]; #Sch=uart_tx_in
set_false_path -from [get_ports { uart_tx_in }]
