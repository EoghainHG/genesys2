// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Eoghain Gray

// plic_threshold_masking.S
//
// Sets the PLIC context-0 threshold above source 1's priority and confirms
// the interrupt is suppressed despite being pending and enabled: PLIC
// records it in the pending bitmap, but meip never asserts (no trap taken —
// the trap_handler existing at all is only a safety net) and a claim read
// returns 0 (nothing claimable). Validates the priority-vs-threshold
// compare, the one piece of real PLIC arbitration logic even with a single
// source.

#include "plic_macros.h"

.section .text.init
.globl _start
.align 2
_start:
    la   t0, trap_handler
    csrw mtvec, t0

    li   t0, PLIC_PRIORITY1
    li   t1, 1
    sw   t1, 0(t0)
    li   t0, PLIC_ENABLE0_CTX0
    li   t1, 2                  // bit1 = source1 (UART RX)
    sw   t1, 0(t0)
    li   t0, PLIC_THRESHOLD_CTX0
    li   t1, 2                  // threshold(2) >= priority(1) -> masked
    sw   t1, 0(t0)

    li   t0, UART_IER
    li   t1, IER_ERBFI
    sb   t1, 0(t0)

    li   t0, MIE_MEIE
    csrs mie, t0
    li   t0, MSTATUS_MIE
    csrs mstatus, t0

    li   t0, RX_INJECT_ADDR
    li   t1, 0x33
    sw   t1, 0(t0)

    li   s0, 500
wait:
    addi s0, s0, -1
    bnez s0, wait

    // PLIC must still have recorded the interrupt as pending...
    li   t0, PLIC_PENDING0
    lw   t1, 0(t0)
    andi t1, t1, 2
    beqz t1, fail

    // ...but a claim must return 0 (nothing claimable) since threshold masks it.
    li   t0, PLIC_CLAIM_CTX0
    lw   t1, 0(t0)
    bnez t1, fail

    j    pass

trap_handler:
    j    fail                   // no interrupt should ever be taken here

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
