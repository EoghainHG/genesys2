// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Eoghain Gray

// priv_mret_transition.S
//
// Confirms MRET actually transitions priv_mode (not just PC): M-mode clears
// mstatus.MPP to U, sets mepc to u_mode_code, and executes MRET. If MRET
// correctly drops privilege to U, the ECALL in u_mode_code produces
// mcause==CAUSE_USER_ECALL(8); if MRET left the core in M-mode (the
// pre-Phase-0 bug — MRET only jumped to mepc and never touched privilege
// state), the ECALL would instead produce mcause==CAUSE_MACHINE_ECALL(11).

#include "priv_macros.h"

.section .text.init
.globl _start
.align 2
_start:
    la   t0, trap_handler
    csrw mtvec, t0
    csrw medeleg, zero          // no delegation in this test — trap must land in M

    li   t0, MSTATUS_MPP
    csrc mstatus, t0            // MPP = 00 = U
    la   t0, u_mode_code
    csrw mepc, t0
    mret

u_mode_code:
    ecall
    j    fail                   // unreachable — ecall always traps away

trap_handler:
    csrr t0, mcause
    li   t1, CAUSE_USER_ECALL
    bne  t0, t1, fail
    csrr t0, mepc
    la   t1, u_mode_code
    bne  t0, t1, fail
    j    pass

pass:
    li   t0, 1
    la   t1, tohost
    sw   t0, 0(t1)
    sw   zero, 4(t1)
1:  j    1b

fail:
    li   t0, 3                  // (1<<1)|1
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
