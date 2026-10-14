# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Eoghain Gray

## Genesys 2 pin constraints for genesys2_top_min.sv
## Same source/verification as genesys2_blink.xdc -- see that file's header.

## System clock -- 200 MHz LVDS differential, bank 33
set_property -dict { PACKAGE_PIN AD12 IOSTANDARD LVDS } [get_ports { sysclk_p }]; #IO_L12P_T1_MRCC_33 Sch=sysclk_p
set_property -dict { PACKAGE_PIN AD11 IOSTANDARD LVDS } [get_ports { sysclk_n }]; #IO_L12N_T1_MRCC_33 Sch=sysclk_n
create_clock -add -name sysclk -period 5.000 [get_ports { sysclk_p }]

## clk_core -- a plain synchronous /10 divider (see genesys2_top_min.sv's
## header for why, not an MMCM), NOT auto-detected by Vivado's generated-
## clock inference (it isn't a standard BUFR/MMCM divider pattern). Without
## this, the first build of this design showed WNS/WHS numbers that looked
## clean but were bogus -- report_timing_summary's own "unconstrained
## internal endpoints" count was 21649, meaning the entire CPU/cache/
## peripheral logic (everything actually clocked by clk_core) was never
## timed at all. Found and fixed 2026-09-01 before ever trusting a build.
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
