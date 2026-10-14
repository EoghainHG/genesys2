// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Eoghain Gray

// mmu_superpage_basic.S
//
// Positive translation test for 4MB Sv32 superpages (2026-07-16). Before
// this, a leaf PTE at level 1 was unconditionally faulted
// (mmu_invalid_pte.S's old Stage 3) — real-hardware Linux boot found this
// is not just a hypothetical: mainline RV32 Linux's own early boot
// relocation code (relocate_enable_mmu) unconditionally uses exactly one
// 4MB superpage to map the whole kernel, so this is now required, not
// optional.
//
// Same two-directional M<->S cross-check style as mmu_walk_nonidentity.S,
// but critically at a NON-ZERO, non-trivial offset within the 4MB region
// (TEST_OFFSET = 0x00200004, 2MB+4 bytes in) rather than offset 0 — a
// translation that incorrectly used only VA[11:0] (the ordinary 4KB-page
// offset width) instead of the full VA[21:0] superpage offset would still
// accidentally pass an offset-0 check, since the low 12 bits are identical
// either way. TEST_OFFSET's low 12 bits are also non-zero (0x004), so a
// bug that dropped just the middle bits (VA[21:12]) instead of the whole
// offset would also be caught.
//
// The code page (_start) is identity-mapped through an ordinary 2-level
// walk, same as mmu_walk_nonidentity.S — only the data VA under test uses
// a superpage, so this also proves ordinary and superpage translations
// coexist correctly in the same TLB/table.

#include "mmu_macros.h"

#define TEST_VA     0xE0000000  // VPN[1]=0x380 -- distinct 4MB region from
                                 // both the code page's own l1 entry and
                                 // TARGET_VA in mmu_invalid_pte.S
#define TEST_OFFSET 0x00200004  // 2MB + 4 bytes into the 4MB region
#define SCRATCH_PA  0x81400000  // 4MB-aligned physical target (0x80000000 +
                                 // 5*0x400000) -- comfortably inside the
                                 // 64MB sim RAM window, far from this small
                                 // program's own load address

.section .text.init
.globl _start
.align 2
_start:
    la   t0, m_trap_handler
    csrw mtvec, t0
    csrw medeleg, zero          // no delegation — ECALL from S traps to M

    // M-mode: write the pre-translation known value directly (physical,
    // untranslated) before satp is even touched.
    li   t0, 0x11111111
    li   t1, SCRATCH_PA
    li   t2, TEST_OFFSET
    add  t1, t1, t2
    sw   t0, 0(t1)

    // ---- l1[VPN1(_start)] -> l2_table_code (ordinary 2-level identity map
    // for the code page, exactly like mmu_walk_nonidentity.S) ----
    la   t0, l2_table_code
    srli t0, t0, 12
    slli t0, t0, 10
    ori  t0, t0, PTE_V
    la   t1, _start
    srli t2, t1, 22
    slli t2, t2, 2
    la   t3, l1_table
    add  t3, t3, t2
    sw   t0, 0(t3)

    la   t0, _start
    srli t0, t0, 12
    slli t0, t0, 10
    ori  t0, t0, (PTE_V | PTE_R | PTE_W | PTE_X | PTE_A | PTE_D)
    la   t1, _start
    srli t2, t1, 12
    andi t2, t2, 0x3FF
    slli t2, t2, 2
    la   t3, l2_table_code
    add  t3, t3, t2
    sw   t0, 0(t3)

    // ---- l1[VPN1(TEST_VA)] = LEAF (4MB superpage) mapping straight to
    // SCRATCH_PA's 4MB-aligned base — no level-0 table at all for this VA.
    // R+W+A+D, no X (not executable) and no U (S-mode only), matching how
    // Linux's own kernel-data superpage mapping is set up.
    li   t0, SCRATCH_PA
    srli t0, t0, 12
    slli t0, t0, 10
    ori  t0, t0, (PTE_V | PTE_R | PTE_W | PTE_A | PTE_D)
    li   t1, TEST_VA
    srli t2, t1, 22
    slli t2, t2, 2
    la   t3, l1_table
    add  t3, t3, t2
    sw   t0, 0(t3)

    // ---- enable Sv32 ----
    la   t0, l1_table
    srli t0, t0, 12
    li   t1, SATP_MODE_SV32
    or   t0, t0, t1
    csrw satp, t0
    sfence.vma

    // ---- drop to S-mode ----
    li   t0, MSTATUS_MPP
    csrc mstatus, t0
    li   t0, MPP_S
    csrs mstatus, t0
    la   t0, s_mode_entry
    csrw mepc, t0
    mret

s_mode_entry:
    // Read back the pre-written value through the superpage-mapped VA at
    // the non-trivial offset.
    li   t0, TEST_VA
    li   t1, TEST_OFFSET
    add  t0, t0, t1
    lw   a0, 0(t0)               // a0 = value read via VA -> checked in M

    // Write a new, distinct value through the same virtual alias.
    li   t1, 0x22222222
    sw   t1, 0(t0)

    ecall
    j    fail                    // unreachable

m_trap_handler:
    csrr t0, mcause
    li   t1, CAUSE_SUPERVISOR_ECALL
    bne  t0, t1, fail

    li   t1, 0x11111111
    bne  a0, t1, fail             // virtual read must see the pre-written value

    li   t1, SCRATCH_PA
    li   t2, TEST_OFFSET
    add  t1, t1, t2
    lw   t2, 0(t1)                // physical, untranslated M-mode read
    li   t3, 0x22222222
    bne  t2, t3, fail             // virtual write must have landed physically

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
l2_table_code:
    .space 4096

.section .tohost
.align 3
.globl tohost
tohost:
    .word 0
    .word 0
