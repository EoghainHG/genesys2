// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Eoghain Gray

// clint_timer_irq_mid_jal_icache_miss.S
//
// Sharper variant of clint_timer_irq_mid_jal.S targeting the specific
// mechanism that actually manifested during real kernel-boot debugging
// (busybox's __init_libc() calling memset via
// `jal 0x129e3c` right as an interrupt landed on an in-flight icache miss
// fetching memset's page for the first time).
//
// The bug needs a JAL whose *target* is still being fetched (a multi-cycle
// icache-miss stall) when the timer interrupt lands. During such a stall,
// id_ex is frozen holding whatever instruction preceded the JAL, while
// if_id already holds the JAL itself — and at the very first cycle the
// stall clears, id_ex has not yet caught up to hold the JAL (it lags
// if_id by exactly one cycle at a stall's trailing edge). If the pending
// interrupt is taken on exactly that cycle, mepc/sepc capture the *older*
// instruction's PC, not the JAL's, and the JAL — whose redirect already
// committed for real back in IF — gets silently flushed out of if_id with
// no record of its still-owed rd write anywhere.
//
// To force a genuine icache miss on every single call (not just the
// first), this test alternates calls between two leaf subroutines placed
// exactly 4096 bytes apart. icache.sv is direct-mapped with SETS=256,
// WORDS_PER_LINE=4 (4KB total capacity, index = addr[11:4]) — two
// addresses 4096 bytes apart share every index/word-offset bit but differ
// in tag, so alternating between them evicts and refetches on every call.
// This gives 2*N_ITERS independent chances for the timer interrupt (swept
// across many phases via the trap handler's periodic re-arm) to land
// exactly in the one-cycle stall-trailing-edge race window described
// above.
//
// Uses the same ra-poisoning trick as clint_timer_irq_mid_jal.S: each
// call site loads ra with a trampoline that jumps straight to fail before
// the jal, so only a genuine rd-write can leave ra pointing at the real
// return site.

#include "clint_macros.h"

#define N_ITERS 1000

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
    jal  ra, sub_a
    la   ra, ra_poison_trap
    jal  ra, sub_b
    addi s0, s0, -1
    bnez s0, loop
    j    pass

ra_poison_trap:
    j    fail

trap_handler:
    csrr t0, mcause
    li   t1, CAUSE_MACHINE_TIMER_INT
    bne  t0, t1, fail

    // Re-arm for another period instead of permanently disarming, sweeping
    // the interrupt's landing phase across many different points relative
    // to each forced icache miss over N_ITERS iterations. Unlike the plain
    // jal test's short (~40-cycle) period, this test's per-call cost is
    // dominated by a genuine multi-cycle icache-miss line fill each and
    // every call — an empirically-found short period here (originally 37)
    // resonantly locked the timer to fire on almost every single retry
    // attempt, putting the CPU in a near-permanent trap-handler treadmill
    // with only extremely rare forward progress (confirmed via +TRACE: s0
    // advanced only ~7 counts across 1.5M cycles). 997 (a four-digit prime,
    // comfortably larger than one call's worst-case stall+handler cost) is
    // long enough that most interrupts land between calls with real forward
    // progress in between, while still drifting out of phase with the
    // per-call cycle count over many iterations, since 997 doesn't evenly
    // divide it.
    li   t0, CLINT_MTIMECMP_HI
    li   t1, -1
    sw   t1, 0(t0)

    li   t0, CLINT_MTIME_LO
    lw   t1, 0(t0)
    addi t1, t1, 997
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

// sub_a/sub_b deliberately live in .text (not .text.init): the linker
// script places .tohost right after .text.init at the next 0x1000
// boundary, then .text after that at the boundary following. Keeping
// these two heavily-.align-12-padded stubs out of .text.init keeps
// .tohost at its normal, small address — tb_riscv.sv's tohost detection
// defaults to TOHOST_DEF=0x80001000, and having sub_a/sub_b (needed 4096
// bytes apart for the icache-alias trick) inside .text.init would have
// pushed the linker-placed .tohost section past that address, silently
// breaking tohost detection (the writes would still happen correctly,
// just never be observed — caught during test bring-up by TIMEOUT
// results with no PASS/FAIL despite s0 correctly reaching 0).
.section .text
.align 12
sub_a:
    ret

.align 12
sub_b:
    ret

.section .tohost
.align 3
.globl tohost
tohost:
    .word 0
    .word 0
