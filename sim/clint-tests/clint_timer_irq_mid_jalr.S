// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Eoghain Gray

// clint_timer_irq_mid_jalr.S
//
// Confirmatory/regression-guard companion to clint_timer_irq_mid_jal.S and
// clint_timer_irq_mid_jal_icache_miss.S. Unlike those two, JALR's target is
// only ever resolved in EX (id_ex_jumpr in cpu.sv, computed from the ALU
// using a register value read fresh every time the instruction is
// decoded) — there is no separate, early IF-stage commitment for JALR the
// way if_is_jal provides for JAL, so JALR's redirect and its own rd write
// happen together, from the same id_ex entry, at the same time an
// interrupt squash would hit. Squashing it discards both together;
// refetching after mret regenerates both consistently. JALR is therefore
// NOT expected to exhibit the JAL bug.
//
// This test is expected to PASS both before and after the JAL fix in
// cpu.sv — it exists to (1) empirically confirm JALR isn't currently
// broken (rather than relying on the argument above alone), and (2) guard
// against a future regression (e.g. if a future BTB/prediction redesign
// ever gives JALR an early-IF resolution path, or if the JAL fix's
// id_ex_jumpr handling is ever touched). A failure here in the future
// would mean something about JALR's resolution changed, not a repeat of
// the JAL bug this suite otherwise targets.
//
// Calls through a register-held function pointer (jalr, not a direct
// jal), reloaded fresh each iteration, with the same ra-poisoning trick
// and periodic interrupt re-arm as the JAL tests.

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
    la   t2, callee
    la   ra, ra_poison_trap
    jalr ra, t2, 0
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

    // Re-arm for another short, loop-length-incommensurate period (43
    // cycles, prime — different from both jal tests' 41/37) instead of
    // permanently disarming, sweeping the interrupt's landing phase across
    // many different points in the loop body/callee over N_ITERS
    // iterations.
    li   t0, CLINT_MTIMECMP_HI
    li   t1, -1
    sw   t1, 0(t0)

    li   t0, CLINT_MTIME_LO
    lw   t1, 0(t0)
    addi t1, t1, 43
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
