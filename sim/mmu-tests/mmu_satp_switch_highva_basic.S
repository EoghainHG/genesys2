// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Eoghain Gray

// mmu_satp_switch_highva_basic.S
//
// Second half of isolating sw/mmu-transition-test/mmu_transition_test.S's
// silent real-hardware hang (found 2026-07-24).
// mmu_uart_translated_basic.S isolated and cleared "a single translated
// UART access" (found and fixed an unrelated, general dmem_wen repeated-
// write bug, but the UART-under-translation mechanism itself works). This
// test isolates the OTHER mechanism mmu_transition_test.S exercises: the
// two-phase satp switch (table_a -> table_b) and the cross-mapping jump
// to a high-VA alias of the SAME physical code page -- with NO UART
// access anywhere in this test at all. Pass/fail and fault diagnosis are
// reported purely via tohost and plain memory markers (all within the
// same identity-mapped 4MB code superpage, so no separate data PTE is
// needed), deliberately avoiding any peripheral interaction so a
// hang/fault here can only be attributed to the satp-switch/high-VA-jump
// mechanism itself.

#include "mmu_macros.h"

// sim PC_RESET = 0x80000000 -> VPN1 = 0x200 (matches mmu_transition_test.S)
#define CODE_VPN1 0x200
#define VA_OFFSET 0x40000000
// (0x80000000 + VA_OFFSET) >> 22 = 0x300
#define CODE_HIGH_VPN1 0x300

.section .text.init
.globl _start
.align 2
_start:
    la   t0, m_trap_handler
    csrw mtvec, t0
    // Delegate page faults to S-mode, mirroring real OpenSBI's actual
    // MEDELEG so a table bug here traps to s_trap_handler exactly as it
    // would on real hardware, not straight to M-mode.
    li   t0, (1 << CAUSE_INSTR_PAGE_FAULT) | (1 << CAUSE_LOAD_PAGE_FAULT) | \
             (1 << CAUSE_STORE_PAGE_FAULT)
    csrw medeleg, t0

    li   t0, MSTATUS_MPP
    csrc mstatus, t0
    li   t0, MPP_S
    csrs mstatus, t0
    la   t0, s_mode_entry
    csrw mepc, t0
    mret

m_trap_handler:
    // Any M-mode trap here (i.e. NOT delegated to S-mode) is unexpected --
    // report and fail loudly rather than hang silently.
    j    fail

s_mode_entry:
    la   t0, s_trap_handler
    csrw stvec, t0

    // ---- table_a: identity-only (phase-1 trampoline), no UART entry ----
    li   t0, (CODE_VPN1 << 20) | (PTE_V | PTE_R | PTE_W | PTE_X | PTE_A | PTE_D)
    la   t3, table_a
    li   t2, CODE_VPN1 * 4
    add  t3, t3, t2
    sw   t0, 0(t3)

    // ---- table_b: identity + high-VA alias, no UART entry ----
    li   t0, (CODE_VPN1 << 20) | (PTE_V | PTE_R | PTE_W | PTE_X | PTE_A | PTE_D)
    la   t3, table_b
    li   t2, CODE_VPN1 * 4
    add  t3, t3, t2
    sw   t0, 0(t3)

    li   t0, (CODE_VPN1 << 20) | (PTE_V | PTE_R | PTE_W | PTE_X | PTE_A | PTE_D)
    la   t3, table_b
    li   t2, CODE_HIGH_VPN1 * 4
    add  t3, t3, t2
    sw   t0, 0(t3)

    // ============ PHASE 1: enable Sv32 via table_a ============
    la   t0, table_a
    srli t0, t0, 12
    li   t1, SATP_MODE_SV32
    or   t0, t0, t1
    csrw satp, t0
    sfence.vma

    li   t0, 1
    la   t1, phase1_result
    sw   t0, 0(t1)

    // ============ PHASE 2: switch satp to table_b, jump to high-VA alias ============
    la   t0, table_b
    srli t0, t0, 12
    li   t1, SATP_MODE_SV32
    or   t0, t0, t1
    csrw satp, t0
    sfence.vma

    la   t0, phase2_continue
    li   t1, VA_OFFSET
    add  t0, t0, t1
    jr   t0

phase2_continue:
    li   t0, 1
    la   t1, phase2_result
    sw   t0, 0(t1)
    j    pass

s_trap_handler:
    // Record fault info directly to memory (no UART involved at all),
    // then fail.
    csrr t0, scause
    la   t1, fault_scause
    sw   t0, 0(t1)
    csrr t0, sepc
    la   t1, fault_sepc
    sw   t0, 0(t1)
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
table_a:
    .space 4096
.align 12
table_b:
    .space 4096
phase1_result:
    .word 0
phase2_result:
    .word 0
fault_scause:
    .word 0
fault_sepc:
    .word 0

.section .tohost
.align 3
.globl tohost
tohost:
    .word 0
    .word 0
