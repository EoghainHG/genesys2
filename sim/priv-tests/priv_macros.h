// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Eoghain Gray

// Shared constants for the hand-written Phase 0 privilege/delegation tests.
// Deliberately not using riscv-tests/env/p/riscv_test.h here: its
// RVTEST_CODE_BEGIN boilerplate pulls in RNMI/mnstatus/vectored-interrupt
// setup that's irrelevant to Phase 0 and would obscure what these tests
// are actually exercising.

#define CAUSE_USER_ECALL       8
#define CAUSE_SUPERVISOR_ECALL 9
#define CAUSE_MACHINE_ECALL    11

#define MSTATUS_MPP  (3 << 11)
#define MPP_S        (1 << 11)
