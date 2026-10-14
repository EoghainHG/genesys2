// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Eoghain Gray

// priv_cause_matrix.S
//
// Confirms the priv_mode-indexed ECALL cause mux in isolation from
// delegation (medeleg stays zero throughout, so every trap lands in M).
// Three ECALLs back to back, from M, then S, then U:
//   M-mode ECALL   -> expect mcause == CAUSE_MACHINE_ECALL    (11)
//   drop to S, ECALL -> expect mcause == CAUSE_SUPERVISOR_ECALL (9)
//   drop to U, ECALL -> expect mcause == CAUSE_USER_ECALL       (8)

#include "priv_macros.h"

.section .text.init
.globl _start
.align 2
_start:
    li   s1, 0
    la   t0, trap_handler
    csrw mtvec, t0
    csrw medeleg, zero            // never delegate — keep every trap in M

    ecall                          // stage 0: M-mode ECALL
    j    fail                      // unreachable

trap_handler:
    csrr t0, mcause
    li   t2, 0
    beq  s1, t2, check_m
    li   t2, 1
    beq  s1, t2, check_s
    li   t2, 2
    beq  s1, t2, check_u
    j    fail

check_m:
    li   t1, CAUSE_MACHINE_ECALL
    bne  t0, t1, fail
    addi s1, s1, 1
    li   t2, MSTATUS_MPP
    csrc mstatus, t2
    li   t2, MPP_S
    csrs mstatus, t2              // MPP = S
    la   t2, s_code
    csrw mepc, t2
    mret

s_code:
    ecall
    j    fail                      // unreachable

check_s:
    li   t1, CAUSE_SUPERVISOR_ECALL
    bne  t0, t1, fail
    addi s1, s1, 1
    li   t2, MSTATUS_MPP
    csrc mstatus, t2              // MPP = 00 = U
    la   t2, u_code
    csrw mepc, t2
    mret

u_code:
    ecall
    j    fail                      // unreachable

check_u:
    li   t1, CAUSE_USER_ECALL
    bne  t0, t1, fail
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
