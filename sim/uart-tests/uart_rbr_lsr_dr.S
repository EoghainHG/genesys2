// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Eoghain Gray

// uart_rbr_lsr_dr.S
//
// Exercises the sim-only RX-inject backdoor: confirms LSR.DR starts clear,
// becomes set after an injected byte, that RBR returns the injected byte,
// and that reading RBR clears LSR.DR again. No PLIC/interrupt involved.

#include "uart_macros.h"

.section .text.init
.globl _start
.align 2
_start:
    li   t0, UART_LSR
    lbu  t1, 0(t0)
    andi t1, t1, LSR_DR
    bnez t1, fail             // DR must start clear

    li   t0, RX_INJECT_ADDR
    li   t1, 0x5A
    sw   t1, 0(t0)

    nop
    nop
    nop

    li   t0, UART_LSR
    lbu  t1, 0(t0)
    andi t1, t1, LSR_DR
    beqz t1, fail             // DR must be set after injection

    li   t0, UART_RBR
    lbu  t2, 0(t0)
    li   t3, 0x5A
    bne  t2, t3, fail

    li   t0, UART_LSR
    lbu  t1, 0(t0)
    andi t1, t1, LSR_DR
    bnez t1, fail             // reading RBR must clear DR

    j    pass

pass:
    li   t0, 1
    la   t1, tohost
    sw   t0, 0(t1)
    sw   zero, 4(t1)
1:  j    1b

fail:
    li   t0, 3
    la   t1, tohost
    sw   t0, 0(t1)
    sw   zero, 4(t1)
1:  j    1b

.section .tohost
.align 3
.globl tohost
tohost:
    .word 0
    .word 0
