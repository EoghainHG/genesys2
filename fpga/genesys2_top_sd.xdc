# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Eoghain Gray

## Genesys 2 pin constraints for genesys2_top_sd.sv
## Same source/verification as genesys2_top_ddr.xdc -- see that file's header.
##
## NOTE: sysclk_p/sysclk_n and all DDR3_* pins are deliberately NOT
## constrained here -- MIG's own IP-generated XDC (produced automatically
## from mig.prj's full PinSelection block during fpga/bd_build.tcl) already
## owns those pins.
##
## NOTE: the clk_core generated-clock constraint lives in a SEPARATE file,
## fpga/genesys2_top_sd_timing.xdc, added with USED_IN_SYNTHESIS=false in
## build_sd.tcl -- see that file's header and genesys2_top_ddr.sv's module
## header for why (mig_bridge_wrapper's internals are still an
## out-of-context black box at plain synthesis time).

## CPU reset pushbutton -- active-low, a debounced TOGGLE in RTL (see
## genesys2_top_ddr.sv's module header and its cpu_held_toggle logic).
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

## SD card slot, SPI-mode wiring (cross-checked against Digilent's own
## board_files/genesys2/H/part0_pins.xml,
## which labels these same four pins sd_sclk_i/sd_mosi_i/sd_miso_i/sd_ss_i --
## i.e. Digilent's own board file already treats this slot in SPI terms).
## sd_d1/sd_d2 (R30/P29) and sd_cd/sd_reset (P28/AE24) are deliberately not
## constrained here -- unused in SPI mode, see genesys2_top_sd.sv's header.
set_property -dict { PACKAGE_PIN R28 IOSTANDARD LVCMOS33 } [get_ports { sd_sclk }]; #Sch=sd_sclk
set_property -dict { PACKAGE_PIN R29 IOSTANDARD LVCMOS33 } [get_ports { sd_cmd }]; #Sch=sd_cmd
## sd_d0 (MISO): PULLTYPE PULLUP added 2026-09-09. Every real-world SPI-mode
## SD driver (ChaN, Linux mmc_spi.c, SdFat) runs on a host whose card slot
## provides a DAT0/MISO pull-up; ESP-IDF docs state SPI-mode SD access still
## needs one, and this design had none anywhere. Added as a candidate fix for
## the recurring intermittent CMD0/CMD24-no-R1 card-init/write failures --
## tested on hardware 2026-09-09, did NOT fix them (that failure is now
## believed to be a worn card / slot
## contacts, not a design issue). KEPT regardless: a pull-up on a SPI-mode SD
## MISO is simply correct, harmless in parallel with any external pull-up,
## and weak (~2-10k per bank spec) but present continuously unlike the card's.
set_property -dict { PACKAGE_PIN R26 IOSTANDARD LVCMOS33 PULLTYPE PULLUP } [get_ports { sd_d0 }]; #Sch=sd_dat[0]
set_property -dict { PACKAGE_PIN T30 IOSTANDARD LVCMOS33 } [get_ports { sd_d3 }]; #Sch=sd_dat[3]
## sd_reset (AE24): NOT optional -- per the official Genesys 2 Reference
## Manual's "MicroSD Slot" section, the on-board Auxiliary Function
## microcontroller powers off the SD slot once the FPGA is configured, and
## this signal must be actively driven low by the FPGA to power the slot
## back on. See genesys2_top_sd.sv's header for the full story.
set_property -dict { PACKAGE_PIN AE24 IOSTANDARD LVCMOS33 } [get_ports { sd_reset }]; #Sch=sd_reset
## sd_d0 (MISO) is driven by the card asynchronously relative to clk_core.
## spi_master.sv now runs it through a real 2-FF synchronizer before shift_in
## ever sees it (2026-09-07 -- a single-register sample was found to be a
## real metastability risk, not just a false-path convenience; see
## spi_master.sv's spi_miso_sync1/2 for the full real-hardware story
## that motivated it). This constraint still
## correctly tells the STA tool not to compute setup/hold slack against an
## inherently asynchronous source -- that's exactly what a synchronizer's
## first stage needs, not a workaround being papered over.
set_false_path -from [get_ports { sd_d0 }]

## System I2C bus (2026-09-07) -- the onboard INA219 power-monitor chips'
## bus, confirmed against Digilent's own board_files/genesys2/H/part0_pins.xml
## (pin indices 71/72, named scl_i/sda_i there). True open-drain inout pins,
## board-level pull-ups already present (permanently-attached slave chips on
## this bus). See rtl/periph/i2c_gpio.sv and genesys2_top_sd.sv's header for
## why this was added -- reading real VCC3V3 voltage during a CMD24 write
## attempt, as a software alternative to an oscilloscope.
set_property -dict { PACKAGE_PIN AE30 IOSTANDARD LVCMOS33 } [get_ports { i2c_scl }]; #Sch=scl
set_property -dict { PACKAGE_PIN AF30 IOSTANDARD LVCMOS33 } [get_ports { i2c_sda }]; #Sch=sda
set_false_path -from [get_ports { i2c_scl }]
set_false_path -from [get_ports { i2c_sda }]
