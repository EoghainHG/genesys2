// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Eoghain Gray

// mmu_invalid_pte.S
//
// Four sub-cases, all run from M-mode via MPRV (MPP=S) so instruction fetch
// never needs translation at all (if_translate_en requires priv_mode!=M,
// and priv_mode never actually changes here) — only the data access under
// test gets walked. Every case must raise a page fault (mcause ==
// CAUSE_LOAD_PAGE_FAULT, since each stage does a plain load):
//
//   Stage 0: V=0 at level 1 (l1 entry never written, stays zero-init)
//   Stage 1: V=0 at level 0 (l1 entry valid pointer, l2 entry never written)
//   Stage 2: reserved encoding at level 0 (V=1, R=0, W=1)
//   Stage 3: reserved encoding at level 1 (V=1, R=0, W=1) — same invalid
//            bit pattern as Stage 2, but on the l1 entry itself, proving
//            ptw_l1_fault's reserved-encoding check is enforced
//            independently of ptw_l2_fault's (2026-07-16: this used to be
//            a "level-1 leaf = attempted 4MB superpage, always faulted"
//            case, but superpages are now legitimately supported — see
//            sim/mmu-tests/mmu_superpage_basic.S for the positive
//            translation test that replaced this one).

#include "mmu_macros.h"

#define TARGET_VA 0xD0000000

.section .text.init
.globl _start
.align 2
_start:
    la   t0, m_trap_handler
    csrw mtvec, t0
    csrw medeleg, zero
    li   s1, 0

    // l1_table[VPN1(TARGET_VA)] intentionally left zero (V=0) for stage 0 —
    // no write here.

    la   t0, l1_table
    srli t0, t0, 12
    li   t1, SATP_MODE_SV32
    or   t0, t0, t1
    csrw satp, t0
    sfence.vma

    li   t0, MSTATUS_MPP
    csrc mstatus, t0
    li   t0, MPP_S
    csrs mstatus, t0
    li   t0, (1 << 17)            // MPRV
    csrs mstatus, t0

    li   t0, TARGET_VA
    lw   t1, 0(t0)                 // stage 0: expect LOAD_PAGE_FAULT (V=0 @ L1)
    j    fail

m_trap_handler:
    li   t2, 0
    beq  s1, t2, check0
    li   t2, 1
    beq  s1, t2, check1
    li   t2, 2
    beq  s1, t2, check2
    li   t2, 3
    beq  s1, t2, check3
    j    fail

check0:
    csrr t0, mcause
    li   t1, CAUSE_LOAD_PAGE_FAULT
    bne  t0, t1, fail
    addi s1, s1, 1

    li   t0, (1 << 17)
    csrc mstatus, t0              // drop MPRV before untranslated table writes
    sfence.vma

    // Stage 1: l1 entry now a valid pointer to l2_table, but l2 entry for
    // TARGET_VA left zero (V=0 @ L0).
    la   t0, l2_table
    srli t0, t0, 12
    slli t0, t0, 10
    ori  t0, t0, PTE_V
    li   t1, TARGET_VA
    srli t2, t1, 22
    slli t2, t2, 2
    la   t3, l1_table
    add  t3, t3, t2
    sw   t0, 0(t3)

    li   t0, MSTATUS_MPP
    csrc mstatus, t0
    li   t0, MPP_S
    csrs mstatus, t0
    li   t0, (1 << 17)
    csrs mstatus, t0

    li   t0, TARGET_VA
    lw   t1, 0(t0)                 // stage 1: expect LOAD_PAGE_FAULT (V=0 @ L0)
    j    fail

check1:
    csrr t0, mcause
    li   t1, CAUSE_LOAD_PAGE_FAULT
    bne  t0, t1, fail
    addi s1, s1, 1

    li   t0, (1 << 17)
    csrc mstatus, t0
    sfence.vma

    // Stage 2: reserved encoding at level 0 (V=1, W=1, R=0).
    li   t0, (PTE_V | PTE_W)
    li   t1, TARGET_VA
    srli t2, t1, 12
    andi t2, t2, 0x3FF
    slli t2, t2, 2
    la   t3, l2_table
    add  t3, t3, t2
    sw   t0, 0(t3)

    li   t0, MSTATUS_MPP
    csrc mstatus, t0
    li   t0, MPP_S
    csrs mstatus, t0
    li   t0, (1 << 17)
    csrs mstatus, t0

    li   t0, TARGET_VA
    lw   t1, 0(t0)                 // stage 2: expect LOAD_PAGE_FAULT (reserved)
    j    fail

check2:
    csrr t0, mcause
    li   t1, CAUSE_LOAD_PAGE_FAULT
    bne  t0, t1, fail
    addi s1, s1, 1

    li   t0, (1 << 17)
    csrc mstatus, t0
    sfence.vma

    // Stage 3: reserved encoding at level 1 (V=1, W=1, R=0) — mirrors
    // Stage 2's bit pattern but on the l1 entry, proving the reserved-
    // encoding check applies at L1 independently of L2.
    li   t0, (PTE_V | PTE_W)
    li   t1, TARGET_VA
    srli t2, t1, 22
    slli t2, t2, 2
    la   t3, l1_table
    add  t3, t3, t2
    sw   t0, 0(t3)

    li   t0, MSTATUS_MPP
    csrc mstatus, t0
    li   t0, MPP_S
    csrs mstatus, t0
    li   t0, (1 << 17)
    csrs mstatus, t0

    li   t0, TARGET_VA
    lw   t1, 0(t0)                 // stage 3: expect LOAD_PAGE_FAULT (reserved @ L1)
    j    fail

check3:
    csrr t0, mcause
    li   t1, CAUSE_LOAD_PAGE_FAULT
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

.section .data
.align 12
l1_table:
    .space 4096
.align 12
l2_table:
    .space 4096

.section .tohost
.align 3
.globl tohost
tohost:
    .word 0
    .word 0
