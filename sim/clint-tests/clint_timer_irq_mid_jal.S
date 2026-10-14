// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Eoghain Gray

// clint_timer_irq_mid_jal.S
//
// Regression test for a real RTL bug found during Linux kernel-boot
// debugging: a jal's register write can be lost while its PC-redirect
// survives, when an interrupt lands on it --
// JAL is resolved "for free" in the IF stage (if_is_jal/if_pred_target in
// cpu.sv) — its PC-redirect takes effect the same cycle it's fetched,
// fully decoupled from its own progress through id_ex/ex_mem/mem_wb, where
// its rd=pc+4 write actually happens several cycles later. The EX/MEM
// interrupt squash (irq_taken_now, cpu.sv) zeroes ex_mem_reg_write for
// whatever instruction is sitting in id_ex when a timer interrupt is
// taken, on the assumption that a later mepc-based re-fetch will
// regenerate the exact same effect — true for an ordinary ALU/load/store,
// but the concern for JAL is that its control-flow effect already
// committed via the separate, earlier IF-stage mechanism.
//
// This test isolates the simplest case: a single, already-icache-resident
// subroutine called in a tight loop (no forced cache miss — see
// clint_timer_irq_mid_jal_icache_miss.S for the sharper, miss-driven
// variant), with a periodically-rearmed timer interrupt sweeping across
// many different phase offsets relative to the loop body over N_ITERS
// iterations. Each iteration first poisons ra to a trampoline that jumps
// straight to fail — only a genuine, successful jal rd-write can leave ra
// pointing at the real return site, so a silently-dropped write is caught
// immediately rather than being masked by every iteration's return address
// being numerically identical.

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

    li   s0, N_ITERS

loop:
    la   ra, ra_poison_trap
    jal  ra, callee
    addi s0, s0, -1
    bnez s0, loop
    j    pass

callee:
    ret

ra_poison_trap:
    j    fail

trap_handler:
    csrr t0, mcause
    li   t1, CAUSE_MACHINE_TIMER_INT
    bne  t0, t1, fail

    // Re-arm for another short, loop-length-incommensurate period (41
    // cycles, prime) instead of permanently disarming — sweeps the
    // interrupt's landing phase across many different points in the loop
    // body/callee over N_ITERS iterations, rather than testing only one
    // fixed (and likely uninteresting) phase.
    li   t0, CLINT_MTIMECMP_HI
    li   t1, -1
    sw   t1, 0(t0)

    li   t0, CLINT_MTIME_LO
    lw   t1, 0(t0)
    addi t1, t1, 41
    li   t0, CLINT_MTIMECMP_LO
    sw   t1, 0(t0)
    li   t0, CLINT_MTIMECMP_HI
    sw   zero, 0(t0)

    mret                       // natural resumption — mepc untouched

// mstatus.MIE is cleared first in both pass:/fail: — unlike the sibling
// single-shot-armed tests, this test's trap handler re-arms forever, so
// without this an interrupt could land mid-sequence here and corrupt the
// pending tohost write via the handler's own (by-convention) t0/t1
// clobbering. Found via a real failure during test bring-up: tohost ended
// up holding a stray CLINT address instead of 1/3.
pass:
    csrci mstatus, 8
    li   t0, 1
    la   t1, tohost
    sw   t0, 0(t1)
    sw   zero, 4(t1)
1:  j    1b

fail:
    csrci mstatus, 8
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
