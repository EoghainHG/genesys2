// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Eoghain Gray

// Shared constants for the hand-written Phase 2 CLINT tests. Values match
// rtl/periph/clint.sv's register map and rtl/core/riscv_pkg.sv's mip/mie bit
// positions and interrupt cause codes — copied by hand rather than shared
// via a common header, matching sim/priv-tests/priv_macros.h's and
// sim/mmu-tests/mmu_macros.h's existing rationale (avoids upstream RVTEST_*
// boilerplate we don't want here).

#define CLINT_BASE       0x02000000
#define CLINT_MSIP       (CLINT_BASE + 0x0000)
#define CLINT_MTIMECMP_LO (CLINT_BASE + 0x4000)
#define CLINT_MTIMECMP_HI (CLINT_BASE + 0x4004)
#define CLINT_MTIME_LO   (CLINT_BASE + 0xBFF8)
#define CLINT_MTIME_HI   (CLINT_BASE + 0xBFFC)

#define MIP_MTIP (1 << 7)
#define MIE_MTIE (1 << 7)

#define MSTATUS_MIE (1 << 3)

#define CAUSE_MACHINE_TIMER_INT 0x80000007
