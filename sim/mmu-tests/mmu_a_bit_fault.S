// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Eoghain Gray

// mmu_a_bit_fault.S
//
// A leaf PTE with A=0 (Accessed bit clear) but otherwise fully permissive
// (V|R|W|X|D=1) must still fault on any access — this is easy to
// accidentally omit since A isn't a traditional "permission" bit. The
// walker is read-only (no hardware A/D-bit setting, per Phase 1's design
// decision), so A=0 must always be treated as a fault, deferring to
// software (Linux's fault handler already knows how to set A/D and
// retry).

#include "mmu_macros.h"

#define TEST_VA 0xC0003000

.section .text.init
.globl _start
.align 2
_start:
    la   t0, m_trap_handler
    csrw mtvec, t0
    csrw medeleg, zero

    // l1[VPN1(TEST_VA)] -> l2_table
    la   t0, l2_table
    srli t0, t0, 12
    slli t0, t0, 10
    ori  t0, t0, PTE_V
    li   t1, TEST_VA
    srli t2, t1, 22
    slli t2, t2, 2
    la   t3, l1_table
    add  t3, t3, t2
    sw   t0, 0(t3)

    // l2_table[VPN0(TEST_VA)]: fully permissive EXCEPT A=0 (and D=0, since
    // D is meaningless without A, but the fault should be caused by A
    // alone here regardless of D).
    la   t0, data_page
    srli t0, t0, 12
    slli t0, t0, 10
    ori  t0, t0, (PTE_V | PTE_R | PTE_W | PTE_X)
    li   t1, TEST_VA
    srli t2, t1, 12
    andi t2, t2, 0x3FF
    slli t2, t2, 2
    la   t3, l2_table
    add  t3, t3, t2
    sw   t0, 0(t3)

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
    li   t0, (1 << 17)
    csrs mstatus, t0

    li   t0, TEST_VA
    lw   t1, 0(t0)                 // expect LOAD_PAGE_FAULT (A=0)
    j    fail                      // unreachable

m_trap_handler:
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
.align 12
data_page:
    .space 4096

.section .tohost
.align 3
.globl tohost
tohost:
    .word 0
    .word 0
