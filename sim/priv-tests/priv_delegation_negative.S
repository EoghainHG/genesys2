// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Eoghain Gray

// priv_delegation_negative.S
//
// Mirror/negative-control test for priv_delegation_basic.S: same MRET-to-U
// + ECALL setup, but medeleg bit 8 is left CLEAR. Confirms the trap still
// lands in M-mode (mcause==8) and stvec is never reached — proving the
// delegation *gate* condition itself (ecall_delegated = priv_mode!=M &&
// medeleg[cause]), not just the delegated path.

#include "priv_macros.h"

.section .text.init
.globl _start
.align 2
_start:
    la   t0, m_trap_handler
    csrw mtvec, t0
    la   t0, s_trap_handler
    csrw stvec, t0
    csrw medeleg, zero           // explicit: no delegation

    li   t0, MSTATUS_MPP
    csrc mstatus, t0             // MPP = 00 = U
    la   t0, u_code
    csrw mepc, t0
    mret

u_code:
    ecall
    j    fail                    // unreachable

m_trap_handler:
    csrr t0, mcause
    li   t1, CAUSE_USER_ECALL
    bne  t0, t1, fail
    csrr t0, mepc
    la   t1, u_code
    bne  t0, t1, fail
    j    pass

s_trap_handler:
    j    fail                    // must never be reached — delegation is off

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
