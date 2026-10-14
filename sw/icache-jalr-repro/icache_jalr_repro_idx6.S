// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Eoghain Gray

// icache_jalr_repro_idx6.S
//
// Variant of icache_jalr_repro.S, same jalr-mid-line mechanism, but with
// padding inserted so line_l lands on cache index 6 -- the exact same
// index the real production bug hits (req_addr==0x140058, RISC-V VA
// 0x80500160) -- instead of index 1, where the first jalr repro attempt
// landed. That attempt confirmed the causal race condition (held
// ex_redirect coinciding with an unrelated line's fill-completing
// stall-release) reproduces perfectly on demand, but did NOT reproduce
// the tag misread itself. This variant tests whether the misread needs
// something specific to index 6's own physical tag-array placement/
// routing, rather than being a general property of the race condition.
//
// As a bonus, this also puts line_fresh at index 7 -- matching the real
// bug's index 6->7 pair exactly, not just the timing mechanism.
//
// Pass/fail signal is the icacheidex ILA capture ONLY -- no LEDs.
// No OpenSBI, no MMU -- loaded directly at 0x80100000.

.section .text.init
.globl _start
.align 2
_start:
    li   t1, 0             // visit counter
    li   t2, 2             // t1==2 means "already redirected once -- exit"
    la   t0, line_l         // t0 = &line_l (jalr's own target)

    // Padding so line_l lands at offset 0x60 from _start (index 6),
    // instead of 0x10 (index 1) as in icache_jalr_repro.S. Exact word
    // count re-verified via disassembly before computing any trigger.
    .rept 20
    nop
    .endr

    .align 4
line_l:
    addi t1, t1, 1           // word0
    beq  t1, t2, done         // word1
    jr   t0                    // word2 (3rd word) -- jalr, rd=x0
    nop                          // word3 -- speculatively over-fetched

    .align 4
line_fresh:                     // genuinely fresh/never-touched line (index 7)
    nop
    nop
    nop
    nop

done:
    j done                       // spin -- ILA capture is the real verdict
