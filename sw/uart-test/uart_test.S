// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Eoghain Gray

// uart_test.S — Genesys 2 UART console bring-up milestone
// (genesys2_top_uart.sv).
//
// Writes the bytes of "UART OK\r\n" one at a time to uart.sv's THR
// register (UART_BASE+0), self-paced with a fixed delay between bytes
// (see uart_test_macros.h's DELAY_ITERS comment for why). This exercises
// the real icache/dcache -> mmio_decoder -> uart.sv -> uart_phy.sv ->
// uart_rx_out pin -> onboard USB-UART bridge path on actual silicon,
// which nothing before genesys2_top_uart.sv had proven end-to-end. Sets
// all 8 LEDs on once every byte has been issued -- this only confirms the
// program ran to completion, not that the bytes were actually seen; the
// real verification is watching "UART OK" arrive on a serial terminal
// (115200 8N1) connected to the board's dedicated UART port.
//
// No tohost -- runs on real hardware, program baked directly into the
// bitstream's on-chip LUTRAM via MEMORY_INIT_FILE (sw/uart-test/uart_test.mem),
// same convention as sw/blink.mem/genesys2_top_min.sv -- not Verilator,
// and not JTAG-loaded DDR (this board has no DDR wired up yet). Entry
// point must be 0x80000000 (this core's PC_RESET).

#include "uart_test_macros.h"

.section .text.init
.globl _start
.align 2
_start:
    li   t0, UART_BASE

    li   t1, 'U'
    sb   t1, 0(t0)
    call delay

    li   t1, 'A'
    sb   t1, 0(t0)
    call delay

    li   t1, 'R'
    sb   t1, 0(t0)
    call delay

    li   t1, 'T'
    sb   t1, 0(t0)
    call delay

    li   t1, ' '
    sb   t1, 0(t0)
    call delay

    li   t1, 'O'
    sb   t1, 0(t0)
    call delay

    li   t1, 'K'
    sb   t1, 0(t0)
    call delay

    li   t1, '\r'
    sb   t1, 0(t0)
    call delay

    li   t1, '\n'
    sb   t1, 0(t0)
    call delay

    li   t3, GPIO_ADDR
    li   t4, LED_GREEN_BOTH
    sw   t4, 0(t3)

1:  j    1b

// Self-paced delay between THR writes -- see uart_test_macros.h.
delay:
    li   a5, DELAY_ITERS
2:  addi a5, a5, -1
    bnez a5, 2b
    ret
