// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Eoghain Gray

// mmu_transition_test.S
//
// Minimal S-mode-native reproduction of Linux's relocate_enable_mmu
// transition (arch/riscv/kernel/head.S), built to test the leading
// hypothesis from a 2026-07-23 real-hardware attempt: the kernel
// produces zero console output on real hardware
// despite booting cleanly in Verilator sim with the byte-identical Image
// (confirmed via JTAG readback -- see fpga/opensbi_load_verify.tcl), and
// RISC-V Linux enables Sv32 paging before its first printk, so a hang
// there would look exactly like what's been observed.
//
// Entered directly in S-mode (a0=hartid, a1=fdt addr, both ignored here)
// via the same OpenSBI fw_payload mechanism as the real kernel -- linked
// at the same address (0x80500000 = FW_TEXT_START+FW_PAYLOAD_OFFSET for
// the current hw build, see link.ld) so this exercises identical real
// DDR/AXI timing, not a different code path.
//
// Real head.S doesn't just enable translation once -- it does it in TWO
// fragile steps, and this test reproduces both:
//   Phase 1: satp -> table_a, a table with ONLY an identity mapping
//            (VA==PA) for this program's own code+data superpage and the
//            UART superpage (mirrors the "early_pg_dir" trampoline).
//            sfence.vma, then the very next fetch is served through the
//            fresh translation -- the first fragile transition.
//   Phase 2: satp -> table_b, a DIFFERENT table (mirrors the switch to
//            "swapper_pg_dir"). table_b keeps the same identity entry
//            (needed since a few more instructions execute at the old
//            low PC before the jump below -- real head.S has this same
//            constraint) PLUS a second entry mapping the same physical
//            superpage to a high virtual alias (PA + VA_OFFSET, mirroring
//            a real kernel's high-half VA mapping). sfence.vma, then an
//            explicit computed absolute jump to the high-VA alias of
//            phase2_continue -- the second, more notorious transition
//            (satp now points to a genuinely different table than the one
//            that translated the immediately-preceding instructions).
//
// Both phase1_continue and phase2_continue, and everything they call
// (print_str/print_hex32/message strings), live in the same 4MB
// superpage as _start, so PC-relative (auipc-based, -mcmodel=medany)
// addressing naturally resolves to the correct address under either
// mapping without any manual fixup.
//
// Three possible outcomes, each distinguishable over the serial console:
//   - Both "PHASE1_..." and "PHASE2_..." OK lines printed: neither
//     transition is the bug -- look further into the kernel's own boot
//     sequence (e.g. something specific to its much larger page table,
//     or something after MMU-enable entirely).
//   - PHASE1 OK but then silence, or a FAULT line: the second
//     (table-switch + cross-mapping jump) transition is implicated --
//     the more historically fragile of the two in real RISC-V Linux
//     ports generally.
//   - Total silence from the very start, matching the kernel's own
//     symptom exactly: a true silent hardware hang with no trap taken at
//     all, the strongest confirmation of the MMU-transition hypothesis
//     and the hardest to localize further without real trace visibility.
//   - A FAULT line (scause/sepc printed): a concrete, localized,
//     debuggable page-table/PTW bug -- by far the best outcome for
//     finding a fix quickly.

#define PTE_V 0x001
#define PTE_R 0x002
#define PTE_W 0x004
#define PTE_X 0x008
#define PTE_A 0x040
#define PTE_D 0x080
#define SATP_MODE_SV32 0x80000000

#define UART_BASE 0x10000000

// _start links at 0x80500000 (see link.ld) -> VPN1 = 0x80500000>>22 = 0x201
#define CODE_VPN1 0x201
// UART at 0x10000000 -> VPN1 = 0x10000000>>22 = 0x040
#define UART_VPN1 0x040
// High-VA alias offset for phase 2, mirroring a real kernel's high-half
// mapping. (0x80500000 + VA_OFFSET) >> 22 = 0x301.
#define VA_OFFSET 0x40000000
#define CODE_HIGH_VPN1 0x301

// This build's LED GPIO register (2026-07-27 checkpoint addition):
// identity-mapped so a store right after Phase 1's satp switch can signal
// success WITHOUT depending on print_str's own, separate UART-page DTLB
// translation -- isolates "did the code-page ITLB refill even work" from
// "does this specific UART-page DTLB access hang", since real hardware has
// never printed PHASE1_IDENTITY_MMU_OK and both are still open questions.
#define GPIO_ADDR 0xFFFFFFF0
// 0xFFFFFFF0 -> VPN1 = 0x3FF
#define GPIO_VPN1 0x3FF

.section .text.init
.globl _start
.align 2
_start:
    // Checkpoint (2026-08-02): raw, untranslated LED/GPIO write, literally
    // the first instruction this payload executes -- confirms OpenSBI's
    // S-mode handoff reaches _start at all, independent of the ENTRY_OK
    // UART checkpoint below (never observed since a NEW, earlier
    // real-hardware hang appeared 2026-08-01/02). GPIO_ADDR's decode is on the physical/cmem
    // address, and satp is still Bare (identity) here,
    // so this needs no translation setup at all -- if OpenSBI's mret
    // landed here successfully, this write cannot fail to reach the LEDs.
    li   t0, 0x3F
    li   t1, GPIO_ADDR
    sw   t0, 0(t1)

    la   t0, s_trap_handler
    csrw stvec, t0

    // Checkpoint (2026-07-27): confirms OpenSBI's S-mode handoff actually
    // reached this payload at all -- real hardware's Phase 1 message has
    // never once printed, so this narrows whether the hang is before this
    // point (handoff itself) or somewhere in the table-setup/satp-enable
    // work below. Runs under Bare translation (identity), same UART access
    // pattern OpenSBI's own banner already proves reliable.
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

    li   t0, (GPIO_VPN1 << 20) | (PTE_V | PTE_R | PTE_W | PTE_A | PTE_D)
    la   t3, table_a
    li   t2, GPIO_VPN1 * 4
    add  t3, t3, t2
    sw   t0, 0(t3)

    // ---- table_b: identity (still needed, see header) + high-VA alias + UART ----
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

    li   t0, (GPIO_VPN1 << 20) | (PTE_V | PTE_R | PTE_W | PTE_A | PTE_D)
    la   t3, table_b
    li   t2, GPIO_VPN1 * 4
    add  t3, t3, t2
    sw   t0, 0(t3)

    // Checkpoint (2026-07-27): confirms all page-table stores above landed
    // (still untranslated DDR writes -- same class of access OpenSBI/kernel
    // already do constantly) before the first, historically-fragile satp
    // write below.
    la   a0, msg_tables_ok
    jal  print_str

    // ============ PHASE 1: enable Sv32 via table_a ============
    la   t0, table_a
    srli t0, t0, 12
    li   t1, SATP_MODE_SV32
    or   t0, t0, t1
    csrw satp, t0
    sfence.vma
    // Next fetch is served through the fresh identity translation.

    // Checkpoint (2026-07-27): light the board LEDs via a translated store
    // to GPIO_ADDR BEFORE attempting the UART print below. This needs only
    // the code-page ITLB refill (already required just to fetch these
    // instructions) plus a DTLB refill for the NEW GPIO mapping -- entirely
    // independent of the UART page's own DTLB entry. If the LEDs light but
    // PHASE1_IDENTITY_MMU_OK still never prints, the problem is specific to
    // the UART-page translated access, not the Sv32 PTW/ITLB/DTLB mechanism
    // generally.
    li   t0, 0x3F
    li   t1, GPIO_ADDR
    sw   t0, 0(t1)

    la   a0, msg_phase1_ok
    jal  print_str

    // ============ PHASE 2: switch satp to table_b, jump to high-VA alias ============
    la   t0, table_b
    srli t0, t0, 12
    li   t1, SATP_MODE_SV32
    or   t0, t0, t1
    csrw satp, t0
    sfence.vma
    // satp now points at a different table root than the one that just
    // translated this fetch. table_b's own identity entry keeps the next
    // few instructions (up to and including the jump below) valid.

    la   t0, phase2_continue
    li   t1, VA_OFFSET
    add  t0, t0, t1
    jr   t0

phase2_continue:
    la   a0, msg_phase2_ok
    jal  print_str
1:  j    1b

// ---- S-mode trap handler: report scause/sepc, then halt ----
// Reachable via its low/identity address under both table_a and table_b.
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
1:  j    1b

// ---- print_str: a0 = pointer to NUL-terminated string ----
print_str:
    lbu  t1, 0(a0)
    beqz t1, 2f
    li   t2, UART_BASE
1:  lbu  t3, 5(t2)          // LSR
    andi t3, t3, 0x20       // THRE
    beqz t3, 1b
    sb   t1, 0(t2)          // THR
    addi a0, a0, 1
    lbu  t1, 0(a0)
    bnez t1, 1b
2:  ret

// ---- print_hex32: t0 = value to print as 8 hex digits ----
print_hex32:
    li   t4, 28
    li   t2, UART_BASE
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

.section .data
.align 12
table_a:
    .space 4096
.align 12
table_b:
    .space 4096

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
