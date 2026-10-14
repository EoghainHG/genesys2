# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Eoghain Gray

## Genesys 2 pin constraints for genesys2_top_uart.sv
## Same source/verification as genesys2_top_min.xdc -- see that file's header.
## Adds the two real UART pins (see genesys2_top_uart.sv's own header for the
## tx/rx naming rationale -- named from the onboard bridge chip's perspective,
## not the FPGA's).

## System clock -- 200 MHz LVDS differential, bank 33
set_property -dict { PACKAGE_PIN AD12 IOSTANDARD LVDS } [get_ports { sysclk_p }]; #IO_L12P_T1_MRCC_33 Sch=sysclk_p
set_property -dict { PACKAGE_PIN AD11 IOSTANDARD LVDS } [get_ports { sysclk_n }]; #IO_L12N_T1_MRCC_33 Sch=sysclk_n
create_clock -add -name sysclk -period 5.000 [get_ports { sysclk_p }]

## clk_core -- a plain synchronous /10 divider, NOT auto-detected by
## Vivado's generated-clock inference. See genesys2_top_min.xdc's header for
## the full story (21649-unconstrained-endpoints bug this fixes).
create_generated_clock -name clk_core -source [get_pins u_ibufds/O] -divide_by 10 [get_pins u_bufg_core/O]

## CPU reset pushbutton -- active-low
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

## UART -- FTDI USB-UART bridge. uart_rx_out is the FPGA's OUTPUT (feeds
## the bridge's RX, i.e. this project's UART TX); uart_tx_in is the FPGA's
## INPUT (fed by the bridge's TX, i.e. this project's UART RX). Named for
## the bridge chip's perspective per Digilent's own XDC convention.
set_property -dict { PACKAGE_PIN Y23 IOSTANDARD LVCMOS33 } [get_ports { uart_rx_out }]; #Sch=uart_rx_out
set_property -dict { PACKAGE_PIN Y20 IOSTANDARD LVCMOS33 } [get_ports { uart_tx_in }]; #Sch=uart_tx_in
set_false_path -from [get_ports { uart_tx_in }]
