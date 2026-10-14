// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Eoghain Gray

// mmu_identity_basic.S
//
// "Boots at all" sanity check: M-mode builds a 2-level Sv32 page table that
// identity-maps (VA==PA) the page containing this test's own code plus a
// scratch data page, enables satp.MODE=Sv32, sfence.vma, then drops to
// S-mode via MRET. Because the mapping is identity, execution continues
// seamlessly at the same numeric PC. S-mode does a store/load round-trip
// through the now-translated scratch address, then ECALLs back to M-mode
// (medeleg=0, so it traps directly to M) carrying the round-trip result in
// a0. M-mode's trap handler checks mcause==CAUSE_SUPERVISOR_ECALL and
// a0==1 before declaring PASS.
//
// Page-table addresses are always obtained via la+srli on linker-placed
// symbols (never hand-computed literals) per the test-design constraint
// that tb_riscv.sv's memory model only decodes addr[17:2] (256KB).

#include "mmu_macros.h"

.section .text.init
.globl _start
.align 2
_start:
    la   t0, m_trap_handler
    csrw mtvec, t0
    csrw medeleg, zero          // no delegation — ECALL from S traps to M

    // ---- l1_table[VPN1(_start)] = pointer to l2_table ----
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

    // ---- l2_table[VPN0(_start)] = leaf PTE for the code page ----
    // No PTE_U: this test only ever runs from S-mode, and S-mode may never
    // execute from a U=1 page (no SUM-style exception exists for fetches,
    // unlike data accesses) — discovered by this test's first RTL run.
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

    // ---- l2_table[VPN0(scratch)] = leaf PTE for the data page ----
    // No PTE_U here either, for the same reason (and mstatus.SUM is never
    // set, so an S-mode access to a U=1 data page would also fault).
    la   t0, scratch
    srli t0, t0, 12
    slli t0, t0, 10
    ori  t0, t0, (PTE_V | PTE_R | PTE_W | PTE_A | PTE_D)
    la   t1, scratch
    srli t2, t1, 12
    andi t2, t2, 0x3FF
    slli t2, t2, 2
    la   t3, l2_table
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
    // Store/load round-trip through the identity-mapped scratch page.
    li   t1, 0xCAFEBABE
    la   t0, scratch
    sw   t1, 0(t0)
    lw   t2, 0(t0)
    li   a0, 1
    beq  t1, t2, 1f
    li   a0, 0
1:  ecall
    j    fail                   // unreachable

m_trap_handler:
    csrr t0, mcause
    li   t1, CAUSE_SUPERVISOR_ECALL
    bne  t0, t1, fail
    li   t1, 1
    bne  a0, t1, fail
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
scratch:
    .word 0

.section .tohost
.align 3
.globl tohost
tohost:
    .word 0
    .word 0
