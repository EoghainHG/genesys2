// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Eoghain Gray

// clint_timer_irq_basic.S
//
// End-to-end machine-timer-interrupt-taking test: arms mtimecmp near-future,
// enables mie.MTIE + mstatus.MIE, then spins on a single self-looping `j`
// (so mepc is deterministically the spin instruction's own address whenever
// interrupted — no ambiguity from a multi-instruction loop body). The
// handler checks mcause/mepc, disarms mtimecmp (so mret's restored
// mstatus.MIE can't immediately re-trigger it), redirects mepc past the
// spin loop, and mrets — proving the trap actually transitioned control and
// that mret correctly resumes execution at the (redirected) target.

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
    addi t2, t2, 300
    li   t0, CLINT_MTIMECMP_LO
    sw   t2, 0(t0)
    li   t0, CLINT_MTIMECMP_HI
    sw   zero, 0(t0)

    li   t0, MIE_MTIE
    csrs mie, t0
    li   t0, MSTATUS_MIE
    csrs mstatus, t0

spin:
    j    spin

after_spin:
    j    pass                 // reached only via the handler's redirected mret

trap_handler:
    csrr t0, mcause
    li   t1, CAUSE_MACHINE_TIMER_INT
    bne  t0, t1, fail

    csrr t0, mepc
    la   t1, spin
    bne  t0, t1, fail

    li   t0, CLINT_MTIMECMP_HI
    li   t1, -1
    sw   t1, 0(t0)             // disarm before mret restores mstatus.MIE

    la   t0, after_spin
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
