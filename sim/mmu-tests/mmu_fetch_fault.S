// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Eoghain Gray

// mmu_fetch_fault.S
//
// Regression test for the 2026-08-29 "silent kernel hang" root cause: a
// PTW fault for an INSTRUCTION FETCH (ptw_acc == PTW_ACC_FETCH ->
// PTW_FAULT) self-deadlocked against the icache's req_hold (fix #2,
// 2026-08-28). itlb_miss=1 -> imem_req_hold=1 -> icache asserts
// cache_stall forever -> imem_stall -> any_stall=1 -> both stall_if
// (freezes pc_if at the faulting VA) and PTW_FAULT's `if (!any_stall)`
// exit are blocked -> pc_if never reaches stvec -> itlb_miss never
// clears. Circular, permanent freeze -- captured on real hardware
// (build/kernelhang_capture.csv: id_ex_pc=0x80500098, ptw_state=PTW_FAULT,
// ptw_acc=PTW_ACC_FETCH, any_stall=1, icache held).
//
// EVERY other hand-written MMU fault test (mmu_perm_fault / mmu_invalid_pte
// / mmu_a_bit_fault) deliberately keeps instruction fetch untranslated
// ("instruction fetch must stay untranslated throughout") and only ever
// exercises CAUSE_LOAD/STORE_PAGE_FAULT -- so the ptw_acc==FETCH ->
// PTW_FAULT path had zero coverage. This test closes that gap.
//
// Two cases, both with Sv32 paging ON and running translated in S-mode:
//   Case A: jr into a VA whose L1 PTE is invalid (V=0). Expect a clean
//           trap to stvec with scause == CAUSE_INSTR_PAGE_FAULT, sepc and
//           stval == the faulting VA. Against the buggy RTL this HANGS
//           (sim TIMEOUT -> FAIL); with the fix it traps.
//   Case B: relocate_enable_mmu analog -- the trap handler installs the
//           missing mapping, sfence.vma, and sret's back to the (now
//           mapped) high-VA alias. Execution must resume and reach `pass`.
//           Proves the fetch-fault trap not only fires but that forward
//           progress through a freshly-installed translation works.
//
// Pass/fail via tohost only (all code/data lives in one identity-mapped
// 4MB superpage; no peripherals). Fail codes (tohost = (n<<1)|1):
//   3  a non-delegated M-mode trap fired (unexpected)
//   5  executed the "unmapped" fall-through target (fault never taken)
//   7  scause != CAUSE_INSTR_PAGE_FAULT in the S trap handler
//   9  sepc  != faulting VA
//   11 stval != faulting VA
//   13 handler saw an unexpected case tag
//   15 Case A resumed but the "fault taken" marker was never set

#include "mmu_macros.h"

// sim PC_RESET = 0x80000000 -> VPN1 = 0x200 (matches the other MMU tests)
#define CODE_VPN1      0x200
#define VA_OFFSET      0x40000000
// (0x80000000 + VA_OFFSET) >> 22 = 0x300
#define CODE_HIGH_VPN1 0x300

#define CASE_A 0xA
#define CASE_B 0xB

.section .text.init
.globl _start
.align 2
_start:
    la   t0, m_trap_handler
    csrw mtvec, t0
    // Delegate page faults to S-mode, mirroring real OpenSBI's MEDELEG so
    // an instruction page fault vectors to s_trap_handler exactly as it
    // would under Linux -- not straight to M-mode.
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
    // Any M-mode trap here means a page fault was NOT delegated (or an
    // entirely different, unexpected trap) -- fail loudly, never hang.
    li   t0, 3
    j    fail

s_mode_entry:
    la   t0, s_trap_handler
    csrw stvec, t0

    // ---- page table: identity 4MB superpage for the code region only ----
    // table[CODE_VPN1] = leaf, V|R|W|X|A|D. table[CODE_HIGH_VPN1] stays 0
    // (V=0) -- that is Case A's fault target.
    li   t0, (CODE_VPN1 << 20) | (PTE_V | PTE_R | PTE_W | PTE_X | PTE_A | PTE_D)
    la   t3, pgtable
    li   t2, CODE_VPN1 * 4
    add  t3, t3, t2
    sw   t0, 0(t3)

    la   t0, pgtable
    srli t0, t0, 12
    li   t1, SATP_MODE_SV32
    or   t0, t0, t1
    csrw satp, t0
    sfence.vma

    // Confirm translated fetch works at all before provoking the fault.
    li   t0, 1
    la   t1, reached_s_translated
    sw   t0, 0(t1)

    // ================= CASE A: jr into an unmapped VA =================
    li   t0, CASE_A
    la   t1, case_tag
    sw   t0, 0(t1)

    la   t0, caseA_fault_target
    li   t1, VA_OFFSET               // -> VPN1 0x300, L1 PTE still V=0
    add  t0, t0, t1
    la   t1, expect_fault_va
    sw   t0, 0(t1)

    jr   t0                          // <-- instruction page fault here

caseA_fault_target:
    // Reaching here means the faulting fetch was NOT trapped (e.g. it
    // fell through untranslated). That is a bug on its own.
    li   t0, 5
    j    fail

// Case A's handler sret's here (low identity address -- always mapped).
caseA_resumed:
    la   t1, fault_taken
    lw   t1, 0(t1)
    li   t2, 1
    bne  t1, t2, 1f
    j    caseB_start
1:
    li   t0, 15
    j    fail

    // ================= CASE B: relocate_enable_mmu analog =================
    // Handler will install table[CODE_HIGH_VPN1] and sret us to the high
    // alias of caseB_target; execution must resume there.
caseB_start:
    li   t0, CASE_B
    la   t1, case_tag
    sw   t0, 0(t1)

    la   t0, caseB_target
    li   t1, VA_OFFSET
    add  t0, t0, t1
    la   t1, expect_fault_va
    sw   t0, 0(t1)

    jr   t0                          // <-- instruction page fault #2

caseB_target:
    // Executed via the freshly-installed high-VA mapping (PA aliases back
    // here). Forward progress through a new translation works.
    j    pass

s_trap_handler:
    // Common checks: this must be an instruction page fault at the VA we
    // were about to jump to.
    csrr t0, scause
    li   t1, CAUSE_INSTR_PAGE_FAULT
    bne  t0, t1, 7f

    la   t1, expect_fault_va
    lw   t1, 0(t1)

    csrr t0, sepc
    bne  t0, t1, 9f
    csrr t0, stval
    bne  t0, t1, 11f

    // Dispatch on the active case.
    la   t0, case_tag
    lw   t0, 0(t0)
    li   t1, CASE_A
    beq  t0, t1, handle_caseA
    li   t1, CASE_B
    beq  t0, t1, handle_caseB
    li   t0, 13
    j    fail

handle_caseA:
    // Just record that the fault was delivered, then sret to the low
    // identity address caseA_resumed (no new mapping needed).
    li   t0, 1
    la   t1, fault_taken
    sw   t0, 0(t1)
    la   t0, caseA_resumed
    csrw sepc, t0
    sret

handle_caseB:
    // Install the missing L1 leaf: VPN CODE_HIGH_VPN1 -> PPN of the code
    // superpage (CODE_VPN1), so the high alias maps back onto real code.
    li   t0, (CODE_VPN1 << 20) | (PTE_V | PTE_R | PTE_W | PTE_X | PTE_A | PTE_D)
    la   t3, pgtable
    li   t2, CODE_HIGH_VPN1 * 4
    add  t3, t3, t2
    sw   t0, 0(t3)
    sfence.vma
    // sret to the high alias of caseB_target -- resume via the new PTE.
    la   t0, caseB_target
    li   t1, VA_OFFSET
    add  t0, t0, t1
    csrw sepc, t0
    sret

7:  li   t0, 7
    j    fail
9:  li   t0, 9
    j    fail
11: li   t0, 11
    j    fail

pass:
    li   t0, 1
    la   t1, tohost
    sw   t0, 0(t1)
    sw   zero, 4(t1)
1:  j    1b

fail:
    // t0 already holds the fail code (an even number); form (code|1) so
    // tohost's low bit marks "done, failed" and (code>>1) is the test id.
    ori  t0, t0, 1
    la   t1, tohost
    sw   t0, 0(t1)
    sw   zero, 4(t1)
1:  j    1b

.section .data
.align 12
pgtable:
    .space 4096
reached_s_translated:
    .word 0
case_tag:
    .word 0
expect_fault_va:
    .word 0
fault_taken:
    .word 0

.section .tohost
.align 3
.globl tohost
tohost:
    .word 0
    .word 0
