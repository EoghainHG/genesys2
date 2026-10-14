// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Eoghain Gray

// Bring-up smoke test: walks a single lit LED across the board's 8 plain
// LEDs by storing to the memory-mapped LED register at GPIO_ADDR. Proves
// the CPU is fetching, branching, and storing correctly on real hardware.
// Runs forever; no return.
.section .text
.global _start

_start:
    li      x2, -16            // x2 = 0xFFFFFFF0 (GPIO_ADDR)
    li      x1, 1               // x1 = LED pattern, one-hot, starts at bit 0

loop:
    sw      x1, 0(x2)           // drive LEDs

    li      x3, 0x1FFFFF        // ~84 ms delay at 50 MHz
delay:
    addi    x3, x3, -1
    bnez    x3, delay

    slli    x1, x1, 1           // advance to next LED
    li      x4, 0x40            // 1 << 6 == past the last of the 6 LED bits
    bne     x1, x4, loop
    li      x1, 1               // wrap back to bit 0
    j       loop
