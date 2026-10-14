// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Eoghain Gray

// clint_timer_irq_lrsc_reservation.S
//
// Regression test for a specific, confirmed gap in rtl/core/cpu.sv found
// while investigating the Linux kernel-boot i_writecount bug: `lr_valid`
// (the LR/SC reservation flag) is set when an LR commits and cleared when
// an SC commits, but is *never* invalidated on interrupt-taken (or any
// other trap) — grep for `lr_valid` in cpu.sv confirms only those two
// write sites. The RISC-V spec requires a trap to invalidate any
// outstanding LR reservation. clint_timer_irq_mid_lrsc.S already
// confirmed a plain (non-conflicting) LR/SC retry loop is exactly-once
// under interrupt preemption, but that test can't observe this gap: with
// nothing else touching the reserved address during the trap, a stale
// surviving reservation and a freshly re-established one are
// indistinguishable. This test makes it observable: the trap handler
// itself writes to the *same* memory location the interrupted LR/SC pair
// is targeting. If the reservation survives the trap and this core's
// mepc resumes execution precisely at a stranded `sc.w.rl` (skipping the
// `lr.w` that already committed before the interrupt landed — a real
// possibility on this non-superscalar pipeline, where lr.w and sc.w.rl
// occupy separate id_ex cycles), that SC can spuriously succeed using a
// value computed *before* the trap handler's write, silently clobbering
// it. Correct behavior (reservation invalidated by the trap) forces that
// SC to fail and retry the LR fresh, correctly picking up the trap
// handler's write and adding exactly 1 on top.
//
// Expected final value: each of N_ITERS loop iterations contributes
// exactly +1 via LR/SC, and the trap handler (which fires exactly once,
// disarming itself) contributes one additional, non-atomic +1 directly.
// So the correct final count is N_ITERS + 1, regardless of which
// iteration's LR/SC the interrupt happens to land on.

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
    li   t4, N_ITERS + 1
    bne  t2, t4, fail
    j    pass

trap_handler:
    csrr t0, mcause
    li   t1, CAUSE_MACHINE_TIMER_INT
    bne  t0, t1, fail

    li   t0, CLINT_MTIMECMP_HI
    li   t1, -1
    sw   t1, 0(t0)             // disarm so it can't re-fire once mret restores mstatus.MIE

    // Non-atomic write to the SAME address the interrupted LR/SC targets
    // (safe here: interrupts are disabled for the duration of the
    // handler, so no other party can race this specific write).
    la   t0, counter
    lw   t1, 0(t0)
    addi t1, t1, 1
    sw   t1, 0(t0)

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
