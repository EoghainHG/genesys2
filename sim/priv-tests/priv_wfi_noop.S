// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Eoghain Gray

// priv_wfi_noop.S
//
// Confirms WFI behaves as a no-op in Phase 0: PC falls through to the next
// instruction with no hang and no trap.

#include "priv_macros.h"

.section .text.init
.globl _start
.align 2
_start:
    li   t0, 0x1234
    wfi
    li   t1, 0x1234
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
