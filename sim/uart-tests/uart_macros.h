// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Eoghain Gray

// Shared constants for the hand-written Phase 2 UART tests. Values match
// rtl/periph/uart.sv's register map (byte-addressed, reg-shift=0) and the
// sim-only RX-inject backdoor address in sim/tb_riscv.sv. Copied by hand
// rather than shared via a common header, matching sim/priv-tests/
// priv_macros.h's and sim/mmu-tests/mmu_macros.h's existing rationale.

#define UART_BASE 0x10000000
#define UART_THR  (UART_BASE + 0x0)
#define UART_RBR  (UART_BASE + 0x0)
#define UART_IER  (UART_BASE + 0x1)
#define UART_LSR  (UART_BASE + 0x5)

#define LSR_DR    (1 << 0)
#define LSR_THRE  (1 << 5)
#define LSR_TEMT  (1 << 6)
#define IER_ERBFI (1 << 0)
#define IER_ETBEI (1 << 1)

// Sim-only backdoor (NOT a real 16550 register) — a store here pulses the
// UART's rx_inject_valid/data one cycle later.
#define RX_INJECT_ADDR 0x10001000
