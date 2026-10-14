// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Eoghain Gray

// Shared constants for the hand-written Phase 1 Sv32 MMU tests. Values
// copied from riscv-tests/env/encoding.h rather than #include'd, matching
// sim/priv-tests/priv_macros.h's existing rationale: pulling in the real
// header brings unrelated RVTEST_* boilerplate we don't want here.

#define PTE_V 0x001
#define PTE_R 0x002
#define PTE_W 0x004
#define PTE_X 0x008
#define PTE_U 0x010
#define PTE_G 0x020
#define PTE_A 0x040
#define PTE_D 0x080

#define SATP_MODE_SV32 0x80000000

#define CAUSE_INSTR_PAGE_FAULT 12
#define CAUSE_LOAD_PAGE_FAULT  13
#define CAUSE_STORE_PAGE_FAULT 15

#define CAUSE_USER_ECALL       8
#define CAUSE_SUPERVISOR_ECALL 9
#define CAUSE_MACHINE_ECALL    11

#define MSTATUS_MPP  (3 << 11)
#define MSTATUS_SUM  (1 << 18)
#define MPP_S        (1 << 11)
