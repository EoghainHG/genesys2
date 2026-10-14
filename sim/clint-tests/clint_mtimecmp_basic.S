// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Eoghain Gray

// clint_mtimecmp_basic.S
//
// Proves the mtimecmp comparator and the CLINT->mip.MTIP wiring purely
// through register plumbing, with mstatus.MIE never set — no trap should
// ever be taken here regardless of what mip reads, which is exactly what
// lets this test isolate the CLINT/CSR-composition wiring from the
// interrupt-taking logic exercised by the clint_timer_irq_*.S tests.

#include "clint_macros.h"

.section .text.init
.globl _start
.align 2
_start:
    // Arm mtimecmp far in the future first, then set the real near-future
    // target, avoiding a spurious compare while mtimecmp is only half-set.
    li   t0, CLINT_MTIMECMP_HI
    li   t1, -1
    sw   t1, 0(t0)

    li   t0, CLINT_MTIME_LO
    lw   t2, 0(t0)
    addi t2, t2, 100
    li   t0, CLINT_MTIMECMP_LO
    sw   t2, 0(t0)
    li   t0, CLINT_MTIMECMP_HI
    sw   zero, 0(t0)

    li   s0, 1000
wait:
    addi s0, s0, -1
    bnez s0, wait

    csrr t0, mip
    li   t1, MIP_MTIP
    and  t0, t0, t1
    beqz t0, fail

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
