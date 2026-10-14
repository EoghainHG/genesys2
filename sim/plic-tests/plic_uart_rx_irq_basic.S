// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Eoghain Gray

// plic_uart_rx_irq_basic.S
//
// End-to-end external-interrupt-taking test: configures the PLIC
// (priority/enable/threshold), enables the UART's RX-data-available
// interrupt, enables mie.MEIE + mstatus.MIE, then injects an RX byte via
// the sim-only backdoor and spins on a single self-looping `j` (mepc is
// then deterministically the spin instruction's address whenever
// interrupted, same technique as clint_timer_irq_basic.S). The handler
// checks mcause, claims the PLIC interrupt (confirms source id 1), reads
// the UART's RBR (confirms the injected byte, which also clears LSR.DR),
// writes PLIC complete, then redirects mepc past the spin loop and mrets.

#include "plic_macros.h"

.section .text.init
.globl _start
.align 2
_start:
    la   t0, trap_handler
    csrw mtvec, t0

    li   t0, PLIC_PRIORITY1
    li   t1, 1
    sw   t1, 0(t0)
    li   t0, PLIC_ENABLE0_CTX0
    li   t1, 2                 // bit1 = source1 (UART RX)
    sw   t1, 0(t0)
    li   t0, PLIC_THRESHOLD_CTX0
    sw   zero, 0(t0)

    li   t0, UART_IER
    li   t1, IER_ERBFI
    sb   t1, 0(t0)

    li   t0, MIE_MEIE
    csrs mie, t0
    li   t0, MSTATUS_MIE
    csrs mstatus, t0

    li   t0, RX_INJECT_ADDR
    li   t1, 0x7E
    sw   t1, 0(t0)

spin:
    j    spin

after_spin:
    j    pass

trap_handler:
    csrr t0, mcause
    li   t1, CAUSE_MACHINE_EXTERNAL_INT
    bne  t0, t1, fail

    li   t0, PLIC_CLAIM_CTX0
    lw   t1, 0(t0)
    li   t2, 1
    bne  t1, t2, fail

    li   t0, UART_RBR
    lbu  t1, 0(t0)
    li   t2, 0x7E
    bne  t1, t2, fail

    li   t0, PLIC_CLAIM_CTX0
    li   t1, 1
    sw   t1, 0(t0)              // complete

    la   t0, after_spin
    csrw mepc, t0
    mret

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

.section .tohost
.align 3
.globl tohost
tohost:
    .word 0
    .word 0
