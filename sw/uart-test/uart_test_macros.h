// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Eoghain Gray

// Shared constants for uart_test.S — Genesys 2 UART console bring-up
// milestone (genesys2_top_uart.sv). This board has 8 plain LEDs
// (led_reg[7:0], see genesys2_top_uart.sv) with no "green" channel to
// target, so all 8 lit is the simplest unambiguous "program ran to
// completion" signal here.

#define GPIO_ADDR  0xFFFFFFF0
#define UART_BASE  0x10000000  // THR at offset 0 -- see rtl/periph/uart.sv

#define LED_GREEN_BOTH 0xFF  // all 8 LEDs on -- "program ran to completion"

// Cycles to wait between THR writes. uart.sv's LSR.THRE is hardwired to a
// constant 1 (no real transmit-latency modeling -- see uart.sv's header
// comment), so software gets no real back-pressure signal and must
// self-pace. One byte at 115200 baud is ~87us; at genesys2_top_uart.sv's
// 20MHz clk_core that's ~1740 cycles minimum -- this uses a large safety
// margin since pacing correctness matters far more than speed for a
// one-shot bring-up test.
#define DELAY_ITERS 4000
