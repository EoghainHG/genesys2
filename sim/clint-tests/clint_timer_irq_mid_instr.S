// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Eoghain Gray

// clint_timer_irq_mid_instr.S
//
// Regression test for the EX/MEM squash: a timer interrupt is guaranteed to
// land mid-loop while a memory-visible load/increment/store is in flight.
// The handler disarms mtimecmp and mrets *without* touching mepc (natural
// resumption — unlike clint_timer_irq_basic.S, which deliberately redirects
// mepc, this test needs the interrupted instruction to be re-fetched and
// re-execute exactly once, which is the architecturally correct behavior).
// If the EX/MEM squash were missing, the interrupted instruction's memory
// write would additionally commit once "prematurely" from the abandoned
// pipeline stage, then again after resumption — the counter would land one
// past N_ITERS instead of exactly at it.

#include "clint_macros.h"

#define N_ITERS 2000

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

    la   t3, counter
    sw   zero, 0(t3)
    li   s0, N_ITERS

loop:
    lw   t2, 0(t3)
    addi t2, t2, 1
    sw   t2, 0(t3)
    addi s0, s0, -1
    bnez s0, loop

    lw   t2, 0(t3)
    li   t4, N_ITERS
    bne  t2, t4, fail
    j    pass

trap_handler:
    csrr t0, mcause
    li   t1, CAUSE_MACHINE_TIMER_INT
    bne  t0, t1, fail

    li   t0, CLINT_MTIMECMP_HI
    li   t1, -1
    sw   t1, 0(t0)             // disarm so it can't re-fire once mret restores mstatus.MIE

    mret                       // natural resumption — mepc untouched

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

.section .data
.align 2
counter:
    .word 0

.section .tohost
.align 3
.globl tohost
tohost:
    .word 0
    .word 0
