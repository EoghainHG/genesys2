// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Eoghain Gray

// mmu_walk_nonidentity.S
//
// Proves the VPN[1]/VPN[0]/offset address arithmetic is correct, not just
// identity passthrough (which mmu_identity_basic.S alone can't rule out,
// since VA==PA there hides most address-formation bugs). Maps an arbitrary
// VA (0xC0001000, VPN[1]=0x300 — deliberately a different 4MB region than
// the code page's VPN[1]=0x200, so this exercises a *second*, independent
// l1 entry) to a physical scratch page.
//
// M-mode (never translated) writes a known value directly to the physical
// scratch page, then S-mode reads it back through the virtual alias
// (proving VA->PA translation reaches the same physical location) and
// writes a *different* known value back through the virtual alias. After
// returning to M-mode, the physical scratch page is read directly
// (untranslated) to confirm the virtual write landed at the correct
// physical location — this two-directional check is what actually
// exercises VPN[1]/VPN[0] extraction, since a translation that silently
// computed the wrong PPN would show up as a mismatch in one direction or
// the other.

#include "mmu_macros.h"

#define TEST_VA 0xC0001000

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
    la   t1, scratch2
    sw   t0, 0(t1)

    // ---- l1[VPN1(_start)] -> l2_table_code (identity map for the code page)
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

    // ---- l2_table_code[VPN0(_start)] = leaf for the code page (no U) ----
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

    // ---- l1[VPN1(TEST_VA)] -> l2_table_data (a second, independent entry)
    la   t0, l2_table_data
    srli t0, t0, 12
    slli t0, t0, 10
    ori  t0, t0, PTE_V
    li   t1, TEST_VA
    srli t2, t1, 22
    slli t2, t2, 2
    la   t3, l1_table
    add  t3, t3, t2
    sw   t0, 0(t3)

    // ---- l2_table_data[VPN0(TEST_VA)] = leaf mapping TEST_VA -> scratch2
    la   t0, scratch2
    srli t0, t0, 12
    slli t0, t0, 10
    ori  t0, t0, (PTE_V | PTE_R | PTE_W | PTE_A | PTE_D)
    li   t1, TEST_VA
    srli t2, t1, 12
    andi t2, t2, 0x3FF
    slli t2, t2, 2
    la   t3, l2_table_data
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
    // Read back the pre-written value through the virtual alias.
    li   t0, TEST_VA
    lw   a0, 0(t0)               // a0 = value read via VA -> checked in M

    // Write a new, distinct value through the virtual alias.
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

    la   t1, scratch2
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
.align 12
l2_table_data:
    .space 4096
scratch2:
    .word 0

.section .tohost
.align 3
.globl tohost
tohost:
    .word 0
    .word 0
