// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Eoghain Gray

// clint_timer_irq_mid_amo.S
//
// Regression test for interrupt preemption of a bare AMO, motivated by a
// real-workload finding during Phase 4 kernel-boot debugging: the Linux
// kernel's vfs_truncate() -> get_write_access()/put_write_access() pair
// (a bare atomic_inc/atomic_dec on an inode's i_writecount, compiling to a
// single amoadd.w) left i_writecount permanently incremented by one during
// initramfs unpacking, with no software-level explanation found by direct
// VFS source inspection. This mirrors clint_timer_irq_mid_instr.S (which
// proved a preempted plain load/increment/store's memory effect happens
// exactly once) but replaces the load/increment/store with a single
// amoadd.w per iteration, to test whether a bare AMO's memory effect is
// equally exactly-once under interrupt preemption, or whether it can be
// lost (dropped, matching the i_writecount symptom) or double-applied.
//
// A timer interrupt is armed to fire partway into a 2000-iteration loop
// whose only memory-visible effect per iteration is `amoadd.w x0, t1, (t3)`
// (t1 = 1, matching what atomic_inc/atomic_dec compile to — a bare AMO
// with no register result consumed, rd=x0). If interrupt preemption can
// ever squash an in-flight or about-to-start AMO's write while still
// letting cpu.sv believe it completed (or vice versa: let it commit twice),
// the final counter will land off N_ITERS instead of exactly at it.

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
    li   s1, 1          // AMO addend, kept in s1 (callee-saved-by-convention;
                         // trap_handler below only clobbers t0/t1, never s0/s1)

loop:
    amoadd.w x0, s1, (t3)
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
