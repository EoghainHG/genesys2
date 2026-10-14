// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Eoghain Gray

// mmu_tlb_perm_recheck.S
//
// Permission checks must apply on a DTLB *hit*, not only during the page-
// table walk that filled the entry. Each stage first does an access the PTE
// allows (which walks and caches the translation), then -- with NO
// sfence.vma in between -- a second access to the same page that the PTE
// does not allow. The second access hits the cached entry and must still
// fault. Found 2026-10-13 root-causing a deterministic Linux panic
// (`dmesg | tail -60`): after fork() every writable page is write-protected
// for copy-on-write; a load cached the read-only translation and a later
// store went straight through with no fault, so parent and child wrote into
// each other's shared stack/heap pages.
//
// Same MPRV technique as mmu_perm_fault.S (everything runs from M-mode).
//
//   Stage 0: W=0 page, MPP=S: load (ok, fills DTLB), then store
//            -> expect CAUSE_STORE_PAGE_FAULT, mtval==faulting VA
//   Stage 1: W=1,D=0 page, MPP=S: load (ok), then store
//            -> expect CAUSE_STORE_PAGE_FAULT (D must be set by software)
//   Stage 2: U=1 page, MPP=S, SUM=1: load (ok), then clear SUM and load again
//            -> expect CAUSE_LOAD_PAGE_FAULT
//   Stage 3: U=1 page, MPP=S, SUM=1: load then store, both allowed
//            -> expect success (the recheck must not break a legal hit)

#include "mmu_macros.h"

.section .text.init
.globl _start
.align 2
_start:
    la   t0, m_trap_handler
    csrw mtvec, t0
    csrw medeleg, zero
    li   s1, 0                  // stage counter

    // ---- l1[VPN1(_start)] -> l2_table (identity map, code stays here) ----
    la   t0, l2_table
    srli t0, t0, 12
    slli t0, t0, 10
    ori  t0, t0, PTE_V
    la   t1, _start
    srli t2, t1, 22
    slli t2, t2, 2
    la   t3, l1_table
    add  t3, t3, t2
    sw   t0, 0(t3)

    // ---- l2_table[VPN0(_start)] = leaf for the code page (M-mode never
    // translates fetches, but keep this mapping present/correct anyway) ----
    la   t0, _start
    srli t0, t0, 12
    slli t0, t0, 10
    ori  t0, t0, (PTE_V | PTE_R | PTE_W | PTE_X | PTE_A | PTE_D)
    la   t1, _start
    srli t2, t1, 12
    andi t2, t2, 0x3FF
    slli t2, t2, 2
    la   t3, l2_table
    add  t3, t3, t2
    sw   t0, 0(t3)

    // ---- l2_table[VPN0(data_page)]: rewritten per-stage below ----
    la   t1, data_page
    srli t4, t1, 12
    andi t4, t4, 0x3FF
    slli t4, t4, 2
    la   t5, l2_table
    add  s2, t5, t4              // s2 = &l2_table[VPN0(data_page)], reused every stage

    // Stage 0: readable, not writable
    la   t0, data_page
    srli t0, t0, 12
    slli t0, t0, 10
    ori  t0, t0, (PTE_V | PTE_R | PTE_A | PTE_D)
    sw   t0, 0(s2)

    la   t0, l1_table
    srli t0, t0, 12
    li   t1, SATP_MODE_SV32
    or   t0, t0, t1
    csrw satp, t0
    sfence.vma

    // MPRV=1, MPP=S
    li   t0, MSTATUS_MPP
    csrc mstatus, t0
    li   t0, MPP_S
    csrs mstatus, t0
    li   t0, (1 << 17)           // MSTATUS_MPRV
    csrs mstatus, t0

    la   t0, data_page
    lw   t2, 0(t0)                // allowed: walks, fills the DTLB
    li   t1, 0xDEADBEEF
    sw   t1, 0(t0)                // stage 0: DTLB hit, expect STORE_PAGE_FAULT
    j    fail

m_trap_handler:
    li   t2, 0
    beq  s1, t2, check0
    li   t2, 1
    beq  s1, t2, check1
    li   t2, 2
    beq  s1, t2, check2
    j    fail                     // stage 3 must not trap

check0:
    csrr t0, mcause
    li   t1, CAUSE_STORE_PAGE_FAULT
    bne  t0, t1, fail
    csrr t0, mtval
    la   t1, data_page
    bne  t0, t1, fail
    addi s1, s1, 1

    li   t0, (1 << 17)
    csrc mstatus, t0              // plain M-mode for the PTE rewrite
    la   t0, data_page
    lw   t1, 0(t0)                // the faulted store must not have landed
    bnez t1, fail
    sfence.vma

    // Stage 1: writable but clean (D=0)
    la   t0, data_page
    srli t0, t0, 12
    slli t0, t0, 10
    ori  t0, t0, (PTE_V | PTE_R | PTE_W | PTE_A)
    sw   t0, 0(s2)

    li   t0, MSTATUS_MPP          // the trap set MPP=M; back to MPP=S
    csrc mstatus, t0
    li   t0, MPP_S
    csrs mstatus, t0
    li   t0, (1 << 17)
    csrs mstatus, t0

    la   t0, data_page
    lw   t2, 0(t0)                // allowed
    li   t1, 0xDEADBEEF
    sw   t1, 0(t0)                // stage 1: expect STORE_PAGE_FAULT (D=0)
    j    fail

check1:
    csrr t0, mcause
    li   t1, CAUSE_STORE_PAGE_FAULT
    bne  t0, t1, fail
    addi s1, s1, 1

    li   t0, (1 << 17)
    csrc mstatus, t0
    sfence.vma

    // Stage 2: U=1 page, S-mode access allowed only while SUM=1
    la   t0, data_page
    srli t0, t0, 12
    slli t0, t0, 10
    ori  t0, t0, (PTE_V | PTE_R | PTE_W | PTE_U | PTE_A | PTE_D)
    sw   t0, 0(s2)

    li   t0, MSTATUS_MPP          // the trap set MPP=M; back to MPP=S
    csrc mstatus, t0
    li   t0, MPP_S
    csrs mstatus, t0
    li   t0, MSTATUS_SUM
    csrs mstatus, t0
    li   t0, (1 << 17)
    csrs mstatus, t0

    la   t0, data_page
    lw   t2, 0(t0)                // allowed (SUM=1)
    li   t3, MSTATUS_SUM
    csrc mstatus, t3              // SUM=0, no sfence.vma
    lw   t2, 0(t0)                // stage 2: expect LOAD_PAGE_FAULT
    j    fail

check2:
    csrr t0, mcause
    li   t1, CAUSE_LOAD_PAGE_FAULT
    bne  t0, t1, fail
    addi s1, s1, 1

    // Stage 3: SUM=1 again, load then store through the same cached entry
    li   t0, MSTATUS_MPP          // the trap set MPP=M; back to MPP=S
    csrc mstatus, t0
    li   t0, MPP_S
    csrs mstatus, t0
    li   t0, MSTATUS_SUM
    csrs mstatus, t0
    la   t0, data_page
    lw   t2, 0(t0)
    li   t1, 0x5A5A5A5A
    sw   t1, 0(t0)
    lw   t2, 0(t0)

    li   t0, (1 << 17)
    csrc mstatus, t0              // drop MPRV before touching tohost normally

    bne  t1, t2, fail
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
