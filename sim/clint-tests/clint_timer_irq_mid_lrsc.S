// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Eoghain Gray

// clint_timer_irq_mid_lrsc.S
//
// Regression test for interrupt preemption of an LR/SC retry loop,
// motivated by the same Linux kernel-boot finding as
// clint_timer_irq_mid_amo.S (an inode's i_writecount left permanently
// incremented by one during initramfs unpacking, root-caused to
// vfs_truncate()'s get_write_access()/put_write_access() pair with no
// software-level explanation found). clint_timer_irq_mid_amo.S already
// proved a *bare* AMO (what put_write_access()'s plain atomic_dec()
// compiles to) is exactly-once under interrupt preemption — that
// hypothesis is closed. But get_write_access() itself compiles to
// atomic_inc_unless_negative(), which on RISC-V (see
// arch/riscv/include/asm/atomic.h's _arch_atomic_inc_unless_negative) is
// NOT a bare AMO — it's a genuine lr.w/sc.w.rl retry loop:
//
//   0:  lr.w      p,  (c)
//       bltz      p,  1f
//       addi      rc, p, 1
//       sc.w.rl   rc, rc, (c)
//       bnez      rc, 0b
//       fence     rw, rw
//   1:
//
// This is architecturally a much richer target for an interrupt-timing
// bug than a bare AMO: the RISC-V spec requires that taking a trap
// invalidate any outstanding LR reservation, and mepc must correctly
// redirect resumption back to the lr.w (not resume mid-sequence at the
// sc.w with a stale computed value) for the loop to behave correctly.
// This test arms a timer interrupt to land partway into a tight loop of
// exactly this lr.w/sc.w.rl sequence and checks the final counter value
// lands exactly on N_ITERS — neither under- nor over-counted.

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
0:  lr.w      t1, (t3)
    bltz      t1, 1f
    addi      t2, t1, 1
    sc.w.rl   t2, t2, (t3)
    bnez      t2, 0b
    fence     rw, rw
1:
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
