// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Eoghain Gray

// mmu_sfence_flush.S
//
// Proves the DTLB actually caches (a deliberate negative case) and that
// sfence.vma actually flushes it (the positive case), using MPRV (MPP=S)
// as before to avoid needing S-mode-executable code pages. No fault is
// ever expected in this test — if the trap handler is ever reached, that's
// itself a failure.
//
//   1. Map TEST_VA -> PA1 (page1). Load through TEST_VA: must read V1.
//   2. WITHOUT sfence.vma, remap TEST_VA's leaf PTE to PA2 (page2, holding
//      a different value V2). Load through TEST_VA again: must STILL read
//      V1 (the stale cached DTLB entry) — proves the DTLB is really
//      caching, not re-walking on every access.
//   3. sfence.vma, then (via a taken jump, not straight-line fallthrough —
//      sfence.vma doesn't retroactively flush already-fetched instructions,
//      so reaching the next check through a jump sidesteps that entirely)
//      load through TEST_VA a third time: must now read V2, proving the
//      flush actually took effect.

#include "mmu_macros.h"

#define TEST_VA 0xC0002000

.section .text.init
.globl _start
.align 2
_start:
    la   t0, m_trap_handler
    csrw mtvec, t0
    csrw medeleg, zero

    li   t0, 0x11111111
    la   t1, page1
    sw   t0, 0(t1)
    li   t0, 0x22222222
    la   t1, page2
    sw   t0, 0(t1)

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

    // l2_table[VPN0(TEST_VA)] -> page1 (initial mapping)
    la   t0, page1
    srli t0, t0, 12
    slli t0, t0, 10
    ori  t0, t0, (PTE_V | PTE_R | PTE_W | PTE_A | PTE_D)
    li   t1, TEST_VA
    srli t2, t1, 12
    andi t2, t2, 0x3FF
    slli t2, t2, 2
    la   t4, l2_table
    add  s2, t4, t2               // s2 = &l2_table[VPN0(TEST_VA)], reused below

    sw   t0, 0(s2)

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

    // ---- Access 1: fresh mapping -> V1, also populates the DTLB ----
    li   t0, TEST_VA
    lw   t1, 0(t0)
    li   t2, 0x11111111
    bne  t1, t2, fail

    // ---- Remap TEST_VA -> page2, WITHOUT sfence.vma ----
    li   t0, (1 << 17)
    csrc mstatus, t0              // drop MPRV for the untranslated PTE write

    la   t0, page2
    srli t0, t0, 12
    slli t0, t0, 10
    ori  t0, t0, (PTE_V | PTE_R | PTE_W | PTE_A | PTE_D)
    sw   t0, 0(s2)

    li   t0, MSTATUS_MPP
    csrc mstatus, t0
    li   t0, MPP_S
    csrs mstatus, t0
    li   t0, (1 << 17)
    csrs mstatus, t0

    // ---- Access 2: stale DTLB entry -> must STILL read V1 ----
    li   t0, TEST_VA
    lw   t1, 0(t0)
    li   t2, 0x11111111
    bne  t1, t2, fail

    // ---- Now actually flush, then jump (not fallthrough) to access 3 ----
    li   t0, (1 << 17)
    csrc mstatus, t0
    sfence.vma
    li   t0, MSTATUS_MPP
    csrc mstatus, t0
    li   t0, MPP_S
    csrs mstatus, t0
    li   t0, (1 << 17)
    csrs mstatus, t0
    j    access3

access3:
    // ---- Access 3: fresh DTLB walk after flush -> must read V2 ----
    li   t0, TEST_VA
    lw   t1, 0(t0)
    li   t2, 0x22222222
    bne  t1, t2, fail
    j    pass

m_trap_handler:
    j    fail                      // no fault is ever expected in this test

pass:
    // MPRV(+MPP=S) is still set here (left on from the access-3 setup) --
    // clear it before touching tohost, or this write itself takes an
    // S-mode DTLB walk against an address the test's page tables never
    // mapped and page-faults. (fail: doesn't need the same guard: it's
    // also reachable via m_trap_handler, and a trap into M-mode forces
    // mstatus.MPP <- M, which turns off MPRV's translation-borrowing
    // regardless of the MPRV bit itself -- so only this direct, non-trap
    // path actually needs the explicit clear.)
    li   t0, (1 << 17)
    csrc mstatus, t0

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
page1:
    .space 4096
.align 12
page2:
    .space 4096

.section .tohost
.align 3
.globl tohost
tohost:
    .word 0
    .word 0
