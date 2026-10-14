// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Eoghain Gray

// clint_mtime_counts.S
//
// Sanity check: CLINT's mtime is free-running and actually advances between
// two reads separated by a busy loop. No interrupts involved.

#include "clint_macros.h"

.section .text.init
.globl _start
.align 2
_start:
    li   t3, CLINT_MTIME_LO
    lw   t0, 0(t3)

    li   t4, 500
1:  addi t4, t4, -1
    bnez t4, 1b

    lw   t1, 0(t3)
    bltu t0, t1, pass
    j    fail

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
