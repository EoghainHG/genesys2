// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Eoghain Gray

// mmu_transition_test.S (sim variant)
//
// Sim-side reproduction of sw/mmu-transition-test/mmu_transition_test.S,
// which hangs silently on real hardware (2026-07-23 real-hardware
// attempt). The phase1/phase2 body
// below is otherwise IDENTICAL to the hardware version -- only the entry
// sequence differs (M-mode prologue + MRET to S-mode, matching this
// project's other mmu-tests/tb_riscv.sv reset convention of starting in
// M-mode, whereas real hardware's OpenSBI hands the kernel/this test
// straight to S-mode -- M-mode never honors satp regardless, so a
// same-shape MRET-to-S-mode drop is required to exercise the same S-mode
// PTW/ITLB path here) and PASS/FAIL reporting (tohost, matching this
// project's other directed tests, instead of raw UART prints, though the
// UART prints are kept too for a +MEMTRACE cross-check if needed).
//
// Purpose: if this passes cleanly in Verilator sim (as expected, given
// mmu_superpage_basic.S already does), while the byte-identical logic
// hangs on real hardware, that's strong confirmation the bug is
// specifically about REAL DDR/AXI timing diverging from sim's memory
// model, not a logic bug reachable by RTL inspection alone -- and if it
// unexpectedly FAILS here too, that's an even better outcome: a
// sim-reproducible, waveform-debuggable instance of the same bug.

#include "mmu_macros.h"

#define UART_BASE 0x10000000

// sim PC_RESET = 0x80000000 -> VPN1 = 0x200 (vs. hw's 0x201 at 0x80500000)
#define CODE_VPN1 0x200
#define UART_VPN1 0x040
#define VA_OFFSET 0x40000000
// (0x80000000 + VA_OFFSET) >> 22 = 0x300 (vs. hw's 0x301)
#define CODE_HIGH_VPN1 0x300

.section .text.init
.globl _start
.align 2
_start:
    la   t0, m_trap_handler
    csrw mtvec, t0
    // Delegate page faults to S-mode, mirroring real OpenSBI's actual
    // MEDELEG (0x0000b109) so a table bug here traps to s_trap_handler
    // exactly as it would on real hardware, not straight to M-mode.
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
    // report and fail loudly rather than hang silently, unlike the real
    // hardware symptom this test exists to investigate.
    j    fail

s_mode_entry:
    la   t0, s_trap_handler
    csrw stvec, t0

    // Checkpoint (2026-07-27, mirrors the hw variant): kept here too so
    // this sim variant stays byte-for-byte comparable in structure, even
    // though sim's own MRET-based entry into s_mode_entry is already known
    // to work (this checkpoint's real value is on the hw side).
    la   a0, msg_entry_ok
    jal  print_str

    // ---- table_a: identity-only (phase-1 trampoline) ----
    li   t0, (CODE_VPN1 << 20) | (PTE_V | PTE_R | PTE_W | PTE_X | PTE_A | PTE_D)
    la   t3, table_a
    li   t2, CODE_VPN1 * 4
    add  t3, t3, t2
    sw   t0, 0(t3)

    li   t0, (UART_VPN1 << 20) | (PTE_V | PTE_R | PTE_W | PTE_A | PTE_D)
    la   t3, table_a
    li   t2, UART_VPN1 * 4
    add  t3, t3, t2
    sw   t0, 0(t3)

    // ---- table_b: identity (still needed) + high-VA alias + UART ----
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

    li   t0, (UART_VPN1 << 20) | (PTE_V | PTE_R | PTE_W | PTE_A | PTE_D)
    la   t3, table_b
    li   t2, UART_VPN1 * 4
    add  t3, t3, t2
    sw   t0, 0(t3)

    // Checkpoint (2026-07-27, mirrors the hw variant).
    la   a0, msg_tables_ok
    jal  print_str

    // ============ PHASE 1: enable Sv32 via table_a ============
    la   t0, table_a
    srli t0, t0, 12
    li   t1, SATP_MODE_SV32
    or   t0, t0, t1
    csrw satp, t0
    sfence.vma

    la   a0, msg_phase1_ok
    jal  print_str

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
    la   a0, msg_phase2_ok
    jal  print_str
    j    pass

s_trap_handler:
    la   a0, msg_fault
    jal  print_str
    csrr t0, scause
    jal  print_hex32
    la   a0, msg_epc
    jal  print_str
    csrr t0, sepc
    jal  print_hex32
    la   a0, msg_nl
    jal  print_str
    j    fail

print_str:
    lbu  t1, 0(a0)
    beqz t1, 2f
    li   t2, UART_BASE
1:  lbu  t3, 5(t2)
    andi t3, t3, 0x20
    beqz t3, 1b
    sb   t1, 0(t2)
    addi a0, a0, 1
    lbu  t1, 0(a0)
    bnez t1, 1b
2:  ret

print_hex32:
    li   t4, 28
1:  srl  t5, t0, t4
    andi t5, t5, 0xF
    li   t6, 10
    blt  t5, t6, 2f
    addi t5, t5, ('A' - 10)
    j    3f
2:  addi t5, t5, '0'
3:  li   t6, UART_BASE
4:  lbu  t3, 5(t6)
    andi t3, t3, 0x20
    beqz t3, 4b
    sb   t5, 0(t6)
    addi t4, t4, -4
    bgez t4, 1b
    ret

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

msg_entry_ok:
    .asciz "ENTRY_OK\r\n"
msg_tables_ok:
    .asciz "TABLES_OK\r\n"
msg_phase1_ok:
    .asciz "PHASE1_IDENTITY_MMU_OK\r\n"
msg_phase2_ok:
    .asciz "PHASE2_HIGHVA_MMU_OK\r\n"
msg_fault:
    .asciz "MMU_FAULT scause=0x"
msg_epc:
    .asciz " sepc=0x"
msg_nl:
    .asciz "\r\n"

.section .tohost
.align 3
.globl tohost
tohost:
    .word 0
    .word 0
