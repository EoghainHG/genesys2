// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Eoghain Gray

// uart_thr_lsr_basic.S
//
// Basic register plumbing: write a byte to THR, confirm LSR.THRE/TEMT read
// back set (held constant 1 in this minimal, no-latency-transmit model).
// No PLIC/interrupt involved.

#include "uart_macros.h"

.section .text.init
.globl _start
.align 2
_start:
    li   t0, UART_THR
    li   t1, 0x41            // 'A'
    sb   t1, 0(t0)

    li   t0, UART_LSR
    lbu  t2, 0(t0)
    andi t3, t2, LSR_THRE
    beqz t3, fail
    andi t3, t2, LSR_TEMT
    beqz t3, fail

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
