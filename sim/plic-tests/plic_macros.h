// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Eoghain Gray

// Shared constants for the hand-written Phase 2 PLIC tests. Values match
// rtl/periph/plic.sv's register map (single source id 1 = UART RX, single
// M-mode context 0) plus the UART bits these tests also need to touch.
// Copied by hand rather than shared via a common header, matching
// sim/priv-tests/priv_macros.h's and sim/mmu-tests/mmu_macros.h's existing
// rationale (and avoiding a cross-test-tier include path).

#define PLIC_BASE           0x0C000000
#define PLIC_PRIORITY1      (PLIC_BASE + 0x000004)
#define PLIC_PENDING0       (PLIC_BASE + 0x001000)
#define PLIC_ENABLE0_CTX0   (PLIC_BASE + 0x002000)
#define PLIC_THRESHOLD_CTX0 (PLIC_BASE + 0x200000)
#define PLIC_CLAIM_CTX0     (PLIC_BASE + 0x200004)

#define MIE_MEIE    (1 << 11)
#define MSTATUS_MIE (1 << 3)
#define CAUSE_MACHINE_EXTERNAL_INT 0x8000000B

#define UART_BASE 0x10000000
#define UART_RBR  (UART_BASE + 0x0)
#define UART_IER  (UART_BASE + 0x1)
#define IER_ERBFI (1 << 0)

// Sim-only backdoor (NOT a real 16550 register) — a store here pulses the
// UART's rx_inject_valid/data one cycle later.
#define RX_INJECT_ADDR 0x10001000
