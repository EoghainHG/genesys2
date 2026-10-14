// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Eoghain Gray

// mmu_uart_translated_basic.S
//
// Minimal, isolated reproduction of "UART MMIO access through an active
// DTLB translation", stripped out of mmu_transition_test.S: that test
// conflates a two-phase satp switch, a high-VA-alias cross-mapping jump,
// AND a translated UART print all in one sequence,
// and hangs silently on real hardware for reasons not yet isolated to any
// one of those three mechanisms. This test does ONLY the third one: a
// single satp enable (one page table, no second table, no high-VA jump)
// followed immediately by a translated UART print -- both a translated
// status-register READ (LSR/THRE poll) and a translated data WRITE (THR),
// repeated across a short string so the read/write sequence exercises
// more than one iteration.
//
// Intended to be run through BOTH sim/tb_riscv.sv (no arbiter/bridge in
// the chain at all -- an arbiter/bridge-free control) and
// sim/full-chain-tests/tb_full_chain.sv (the real bridge-chain topology
// matching hardware) to triangulate whether a hang/fault reproduces here
// at all, and if so, in which layer.

#include "mmu_macros.h"

#define UART_BASE 0x10000000

// sim PC_RESET = 0x80000000 -> VPN1 = 0x200 (matches mmu_transition_test.S)
#define CODE_VPN1 0x200
#define UART_VPN1 0x040

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

    // ---- single table: code identity + UART identity, nothing else ----
    li   t0, (CODE_VPN1 << 20) | (PTE_V | PTE_R | PTE_W | PTE_X | PTE_A | PTE_D)
    la   t3, l1_table
    li   t2, CODE_VPN1 * 4
    add  t3, t3, t2
    sw   t0, 0(t3)

    li   t0, (UART_VPN1 << 20) | (PTE_V | PTE_R | PTE_W | PTE_A | PTE_D)
    la   t3, l1_table
    li   t2, UART_VPN1 * 4
    add  t3, t3, t2
    sw   t0, 0(t3)

    // ============ enable Sv32 via the single table, stay put ============
    la   t0, l1_table
    srli t0, t0, 12
    li   t1, SATP_MODE_SV32
    or   t0, t0, t1
    csrw satp, t0
    sfence.vma

    // Translation is now live. This is the exact mechanism under test:
    // a translated UART status READ (LSR/THRE poll) followed by a
    // translated data WRITE (THR), looped per character.
    la   a0, msg_ok
    jal  print_str
    j    pass

s_trap_handler:
    // Reached only if the translated access itself faults -- print via
    // the same already-established translated UART mapping (the code/UART
    // PTEs are already valid, so this print call itself should not fault).
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
1:  lbu  t3, 5(t2)          // translated READ of LSR
    andi t3, t3, 0x20       // THRE
    beqz t3, 1b
    sb   t1, 0(t2)          // translated WRITE of THR
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
l1_table:
    .space 4096

msg_ok:
    .asciz "UART_XLATE_OK\r\n"
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
