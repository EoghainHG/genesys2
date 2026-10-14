// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Eoghain Gray

// mmu_perm_fault.S
//
// Three sub-cases run entirely from M-mode using mstatus.MPRV to make M-mode's
// own data accesses get permission-checked as if from S-mode or U-mode
// (mem_eff_priv = MPRV ? MPP : priv_mode), without ever actually dropping
// privilege via MRET. This avoids needing separate U-executable code pages
// (S-mode may never execute a U=1 page, so a single shared code page can't
// serve both an S-mode and a U-mode test stage) and directly exercises the
// MPRV plumbing itself, which is easy to get wrong (see cpu.sv's mem_eff_priv
// comment) since instruction fetch must stay untranslated throughout.
//
//   Stage 0: W=0 data page, MPRV+MPP=S, attempt a store
//            -> expect CAUSE_STORE_PAGE_FAULT, stval==faulting VA
//   Stage 1: U=0 data page, MPRV+MPP=U, attempt a load
//            -> expect CAUSE_LOAD_PAGE_FAULT (U-mode may only access U pages)
//   Stage 2: U=1 data page, MPRV+MPP=S, SUM=0, attempt a load
//            -> expect CAUSE_LOAD_PAGE_FAULT (S-mode needs SUM=1 for U pages)
//   Stage 3: same U=1 data page, MPRV+MPP=S, SUM=1, attempt a load
//            -> expect success (mem_eff_priv/SUM plumbing both correct)
//
// Since every stage runs from M-mode, faults land directly at mtvec
// (M-mode traps are never delegated) — no S-mode trap handler is needed.

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

    // Stage 0: R|W=0? no — need V=1,R=1,X=0,W=0,A=1,D=1 (readable, not writable)
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
    li   t1, 0xDEADBEEF
    sw   t1, 0(t0)                // stage 0: expect STORE_PAGE_FAULT
    j    fail                     // unreachable

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
    li   t1, CAUSE_STORE_PAGE_FAULT
    bne  t0, t1, fail
    csrr t0, mtval
    la   t1, data_page
    bne  t0, t1, fail
    addi s1, s1, 1

    // clear MPRV before rewriting the PTE (plain M-mode store, untranslated)
    li   t0, (1 << 17)
    csrc mstatus, t0
    sfence.vma                    // drop the stale stage-0 TLB entry

    // Stage 1: U=0 data page, access as U-mode -> expect LOAD_PAGE_FAULT
    la   t0, data_page
    srli t0, t0, 12
    slli t0, t0, 10
    ori  t0, t0, (PTE_V | PTE_R | PTE_W | PTE_A | PTE_D)   // still no U
    sw   t0, 0(s2)

    li   t0, MSTATUS_MPP
    csrc mstatus, t0
    li   t0, (0 << 11)            // MPP = U
    csrs mstatus, t0
    li   t0, (1 << 17)
    csrs mstatus, t0

    la   t0, data_page
    lw   t1, 0(t0)                 // stage 1: expect LOAD_PAGE_FAULT
    j    fail

check1:
    csrr t0, mcause
    li   t1, CAUSE_LOAD_PAGE_FAULT
    bne  t0, t1, fail
    addi s1, s1, 1

    li   t0, (1 << 17)
    csrc mstatus, t0
    sfence.vma

    // Stage 2: U=1 data page, MPP=S, SUM=0 -> expect LOAD_PAGE_FAULT
    la   t0, data_page
    srli t0, t0, 12
    slli t0, t0, 10
    ori  t0, t0, (PTE_V | PTE_R | PTE_W | PTE_U | PTE_A | PTE_D)
    sw   t0, 0(s2)

    li   t0, MSTATUS_MPP
    csrc mstatus, t0
    li   t0, MPP_S
    csrs mstatus, t0
    li   t0, MSTATUS_SUM
    csrc mstatus, t0              // SUM = 0 (explicit)
    li   t0, (1 << 17)
    csrs mstatus, t0

    la   t0, data_page
    lw   t1, 0(t0)                 // stage 2: expect LOAD_PAGE_FAULT
    j    fail

check2:
    csrr t0, mcause
    li   t1, CAUSE_LOAD_PAGE_FAULT
    bne  t0, t1, fail
    addi s1, s1, 1

    li   t0, (1 << 17)
    csrc mstatus, t0
    sfence.vma

    // Stage 3: same U=1 page, MPP=S, SUM=1 -> expect SUCCESS (no trap)
    li   t0, MSTATUS_MPP
    csrc mstatus, t0
    li   t0, MPP_S
    csrs mstatus, t0
    li   t0, MSTATUS_SUM
    csrs mstatus, t0              // SUM = 1
    li   t0, (1 << 17)
    csrs mstatus, t0

    la   t0, data_page
    li   t1, 0x5A5A5A5A
    sw   t1, 0(t0)
    lw   t2, 0(t0)

    li   t0, (1 << 17)
    csrc mstatus, t0              // drop MPRV before touching tohost normally

    bne  t1, t2, fail
    j    pass

check3:
    // Should never be reached — stage 3 must not trap.
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
