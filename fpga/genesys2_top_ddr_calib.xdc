# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Eoghain Gray

## Genesys 2 pin constraints for genesys2_top_ddr_calib.sv
## Same source/verification as genesys2_top_uart.xdc -- see that file's header.
##
## NOTE: sysclk_p/sysclk_n and all DDR3_* pins are deliberately NOT
## constrained here -- MIG's own IP-generated XDC (produced automatically
## from mig.prj's full PinSelection block during fpga/bd_build.tcl) already
## owns those pins. Redeclaring them here would conflict with MIG's own
## constraints.

## No clock constraint needed here -- clk_core is a direct loopback of
## ui_clk (see genesys2_top_ddr_calib.sv's header for why: a plain-RTL
## divider's create_generated_clock failed to resolve against
## mig_bridge_wrapper's out-of-context-synthesized hierarchy on a first
## attempt). ui_clk already has a real clock object from MIG's own
## generated constraints.

## CPU reset pushbutton -- active-low. Also drives MIG's sys_rst directly
## (ACTIVE LOW per mig.prj's SysResetPolarity) -- see genesys2_top_ddr_calib.sv.
set_property -dict { PACKAGE_PIN R19 IOSTANDARD LVCMOS33 } [get_ports { cpu_resetn }]; #IO_0_14 Sch=cpu_resetn
set_false_path -from [get_ports { cpu_resetn }]

## LEDs -- led[0]=calibration succeeded, led[1]=MMCM locked, led[7:2] unused.
set_property -dict { PACKAGE_PIN T28  IOSTANDARD LVCMOS33 } [get_ports { led[0] }]; #IO_L11N_T1_SRCC_14 Sch=led[0]
set_property -dict { PACKAGE_PIN V19  IOSTANDARD LVCMOS33 } [get_ports { led[1] }]; #IO_L19P_T3_A10_D26_14 Sch=led[1]
set_property -dict { PACKAGE_PIN U30  IOSTANDARD LVCMOS33 } [get_ports { led[2] }]; #IO_L15N_T2_DQS_DOUT_CSO_B_14 Sch=led[2]
set_property -dict { PACKAGE_PIN U29  IOSTANDARD LVCMOS33 } [get_ports { led[3] }]; #IO_L15P_T2_DQS_RDWR_B_14 Sch=led[3]
set_property -dict { PACKAGE_PIN V20  IOSTANDARD LVCMOS33 } [get_ports { led[4] }]; #IO_L19N_T3_A09_D25_VREF_14 Sch=led[4]
set_property -dict { PACKAGE_PIN V26  IOSTANDARD LVCMOS33 } [get_ports { led[5] }]; #IO_L16P_T2_CSI_B_14 Sch=led[5]
set_property -dict { PACKAGE_PIN W24  IOSTANDARD LVCMOS33 } [get_ports { led[6] }]; #IO_L20N_T3_A07_D23_14 Sch=led[6]
set_property -dict { PACKAGE_PIN W23  IOSTANDARD LVCMOS33 } [get_ports { led[7] }]; #IO_L20P_T3_A08_D24_14 Sch=led[7]
