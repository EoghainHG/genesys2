// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Eoghain Gray

// icache_jalr_repro.S
//
// Corrected icache-flush-repro test (real mechanism identified 2026-08-08:
// a jalr sitting at word index 2 of a cache line, not a conditional
// branch at the last word). Supersedes
// sw/icache-flush-repro/ (kept unmodified -- documented negative/
// inconclusive result, see its own header).
//
// Mechanism under test: jalr gets no IF-stage early redirect (unlike
// jal), so IF's normal PC+4 over-fetch continues past it into word3, then
// into the next (fresh, never-touched) line, before EX resolves the
// jalr's target. That over-fetch is a real icache miss -> imem_stall.
// flush_if_id is gated on !any_stall, so the jalr's already-known
// redirect is held pending for the whole fill; the instant the fill
// completes, flush_if_id fires that same cycle, redirecting fetch back
// into the jalr's own target -- an already-fully-cached line. Real
// hardware has been observed (via ILA) to spuriously misread that line's
// tag on the very next cycle despite no intervening write.
//
// Pass/fail signal is the icacheidex ILA capture ONLY -- no LEDs. See
// fpga/icache_jalr_repro_load.tcl / fpga/arm_icacheidex_jalrrepro.tcl.
//
// No OpenSBI, no MMU -- loaded directly at 0x80100000 (matches
// a cpu #(.PC_RESET(32'h8010_0000)) override used for this test).

.section .text.init
.globl _start
.align 2
_start:
    li   t1, 0             // visit counter
    li   t2, 2             // t1==2 means "already redirected once -- exit"
    la   t0, line_l         // t0 = &line_l (jalr's own target)

    .align 4
line_l:
    addi t1, t1, 1           // word0 -- pass1: t1 0->1; pass2 (post-redirect): t1 1->2
    beq  t1, t2, done         // word1 -- not taken pass1 (1!=2); taken pass2 (2==2)
    jr   t0                    // word2 (3rd word) -- jalr, rd=x0 (== jalr x0,0(t0)).
                                 // Deliberately NOT the one-operand `jalr t0` pseudo-op --
                                 // that expands to jalr x1,0(t0) (links ra), a different thing.
    nop                          // word3 -- speculatively over-fetched, never retires

    .align 4
line_fresh:                     // genuinely fresh/never-touched line
    nop
    nop
    nop
    nop

done:
    j done                       // spin -- ILA capture is the real verdict
