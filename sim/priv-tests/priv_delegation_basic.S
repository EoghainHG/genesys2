// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Eoghain Gray

// priv_delegation_basic.S
//
// The core new coverage nothing upstream (rv32mi-p-scall) provides: proves
// medeleg-routed traps actually land in S-mode, not M-mode.
//
// M-mode sets medeleg bit 8 (delegate CAUSE_USER_ECALL to S), sets stvec,
// drops to U-mode via MRET, and U-mode executes ECALL. Expected: the trap
// lands at stvec (not mtvec) with scause==8 (not mcause), sepc pointing at
// the ECALL PC, and priv_mode now S. The S-mode handler then SRETs back to
// a second U-mode label and that U-mode code ECALLs again — if SRET
// correctly restored priv_mode=U (from mstatus.SPP), this second ECALL is
// again a USER_ECALL and delegates again, landing back at stvec with
// scause==8. If SRET had incorrectly left priv_mode=S, this second ECALL
// would compute cause SUPERVISOR_ECALL(9) instead, which is NOT delegated
// (medeleg bit 9 is clear) — it would trap to mtvec instead, and
// m_trap_handler below treats that as a failure.

#include "priv_macros.h"

.section .text.init
.globl _start
.align 2
_start:
    li   s1, 0                  // entry counter, shared across all trap entries

    la   t0, m_trap_handler
    csrw mtvec, t0
    la   t0, s_trap_handler
    csrw stvec, t0

    li   t0, (1 << CAUSE_USER_ECALL)
    csrw medeleg, t0

    li   t0, MSTATUS_MPP
    csrc mstatus, t0            // MPP = 00 = U
    la   t0, u_code_1
    csrw mepc, t0
    mret

u_code_1:
    ecall
    j    fail                   // unreachable

u_code_2:
    ecall
    j    fail                   // unreachable

m_trap_handler:
    // Should never be reached in this test — reaching here means
    // delegation or SRET priv-restore failed somewhere.
    j    fail

s_trap_handler:
    csrr t0, scause
    li   t1, CAUSE_USER_ECALL
    bne  t0, t1, fail
    addi s1, s1, 1

    li   t2, 1
    beq  s1, t2, s_first_entry
    li   t2, 2
    beq  s1, t2, s_second_entry
    j    fail

s_first_entry:
    la   t2, u_code_1
    csrr t3, sepc
    bne  t2, t3, fail
    la   t2, u_code_2
    csrw sepc, t2
    sret

s_second_entry:
    la   t2, u_code_2
    csrr t3, sepc
    bne  t2, t3, fail
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
