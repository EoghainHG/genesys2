// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Eoghain Gray

// clint_rdtime_counts.S
//
// The `time` / `timeh` CSRs (Zicntr) must be readable and free-running. The
// kernel's arch/riscv/lib/delay.c __delay() busy-waits on rdtime; an
// unimplemented `time` CSR (reads 0) makes every udelay/mdelay spin forever
// -- a silent Linux boot hang right after "Run /init", root-caused via a
// hardware ILA on 2026-08-30. cpu.sv now drives `time`/`timeh` from a
// free-running per-clock counter (same construction as clint.sv's mtime).
//
// Checks:
//   1. rdtimeh == 0 this early (64-bit counter has not crossed 2^32).
//   2. rdtime advances monotonically across a bounded busy loop, and by
//      about the loop length -- i.e. it ticks ~once per core clock, not
//      stuck (0) and not frozen.
//   3. rdtime tracks CLINT mtime (both count core clocks from reset), so the
//      two agree to within a small pipeline-skew delta.

#include "clint_macros.h"

.section .text.init
.globl _start
.align 2
_start:
    // (1) timeh must still be zero
    rdtimeh t0
    bnez    t0, fail

    // (2) monotonic + advances by ~loop length
    rdtime  t0                 // t0 = start
    li      t4, 512
1:  addi    t4, t4, -1
    bnez    t4, 1b
    rdtime  t1                 // t1 = end
    bgeu    t0, t1, fail       // must have advanced
    sub     t2, t1, t0
    li      t3, 400
    bltu    t2, t3, fail       // advanced by clearly less than the loop -> stuck/slow
    li      t3, 100000
    bgeu    t2, t3, fail       // absurdly large -> garbage

    // (3) rdtime vs CLINT mtime: both are per-clock counters from reset
    li      t3, CLINT_MTIME_LO
    rdtime  t0
    lw      t1, 0(t3)
    // abs(t0 - t1) < 128
    bgeu    t0, t1, 2f
    sub     t2, t1, t0
    j       3f
2:  sub     t2, t0, t1
3:  li      t3, 128
    bgeu    t2, t3, fail

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
