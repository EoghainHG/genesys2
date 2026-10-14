// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Eoghain Gray

// clint_timer_irq_masked.S
//
// Confirms mstatus.MIE actually gates interrupt-taking: arms mtimecmp
// near-future and sets mie.MTIE, but leaves mstatus.MIE=0 and busy-waits
// well past the threshold, confirming mip.MTIP becomes visible (the
// hardware-driven bit works) while no trap fires (global mask holds).
// Then sets mstatus.MIE=1 and confirms the already-pending interrupt fires
// promptly — validates the enable-gating logic, not just pending-bit wiring.

#include "clint_macros.h"

.section .text.init
.globl _start
.align 2
_start:
    la   t0, trap_handler
    csrw mtvec, t0

    li   t0, CLINT_MTIMECMP_HI
    li   t1, -1
    sw   t1, 0(t0)

    li   t0, CLINT_MTIME_LO
    lw   t2, 0(t0)
    addi t2, t2, 200
    li   t0, CLINT_MTIMECMP_LO
    sw   t2, 0(t0)
    li   t0, CLINT_MTIMECMP_HI
    sw   zero, 0(t0)

    li   t0, MIE_MTIE
    csrs mie, t0
    // mstatus.MIE deliberately left clear (masked) here.

    li   s0, 2000
wait_masked:
    addi s0, s0, -1
    bnez s0, wait_masked

    csrr t0, mip
    li   t1, MIP_MTIP
    and  t0, t0, t1
    beqz t0, fail            // MTIP must be set (CLINT crossed threshold) even while masked

    li   t0, MSTATUS_MIE
    csrs mstatus, t0

spin2:
    j    spin2

after_spin2:
    j    pass

trap_handler:
    csrr t0, mcause
    li   t1, CAUSE_MACHINE_TIMER_INT
    bne  t0, t1, fail

    li   t0, CLINT_MTIMECMP_HI
    li   t1, -1
    sw   t1, 0(t0)             // disarm before mret restores mstatus.MIE

    la   t0, after_spin2
    csrw mepc, t0
    mret

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
