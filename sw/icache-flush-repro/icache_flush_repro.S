// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Eoghain Gray

// icache_flush_repro.S — minimal, OpenSBI-free attempt to reproduce the
// multi-week ST_RRESP icache tag-mismatch hang outside
// OpenSBI's ~200KB boot path.
//
// Background (2026-08-08 sessions): the fatal event, captured live on real
// hardware, is a one-cycle-separated coincidence: a branch mispredicted
// not-taken by the BTB resolves TAKEN in EX while a DIFFERENT, unrelated
// cache line (the branch's own speculative fall-through target) is
// mid-fill; the moment that fill completes and the pipeline unstalls,
// flush_if_id fires (a genuine ~101-flip-flop simultaneous switching event,
// see cpu.sv), and the very next cycle the icache's read of a THIRD,
// already-validly-cached line (the branch's target) reads its tag as a
// mismatch, sending a real AXI read out that never completes.
//
// This test deliberately re-engineers that exact structural coincidence
// with the smallest possible program, so it can be reached in a handful of
// cycles after reset instead of ~2420 icache misses into a real boot.
// Real hardware is icache #(.SETS(16), .WORDS_PER_LINE(4)) -- 16-byte
// (4-word) lines -- so precise 16-byte alignment of line_v/line_d below is
// load-bearing, not cosmetic.
//
// Loaded directly at this build's PC_RESET (0x8010_0000, a
// cpu #(.PC_RESET(32'h8010_0000)) override) -- no OpenSBI,
// no MMU, no traps needed for this experiment. LEDs are the pass/fail
// signal, same convention as sw/ddr-test/ddr_test.S:
//   GREEN (both LEDs) = loop completed normally -- did NOT reproduce.
//   total silence / no LEDs ever light = hung exactly like the real bug --
//     REPRODUCED. (There is no real "FAIL/red" outcome for this test --
//     data isn't being compared, only whether the loop can complete.)

#include "../ddr-test/ddr_test_macros.h"

.section .text.init
.globl _start
.align 2
_start:
    li   t3, GPIO_ADDR
    li   t0, 2              // loop counter: guarantees exactly one taken
                             // pass through the branch below before exit

    // --- line_v ("victim"): plain, content-irrelevant filler. Fetched
    // once here (first-ever visit, genuine cold miss + fill, exactly like
    // the real bug's index-6 line), then revisited via the branch below
    // once it's already validly cached -- mirrors the real bug's structure
    // exactly.
    .align 4
line_v:
    nop
    nop
    nop
    nop

    // --- line_d ("distractor"): the branch is deliberately the LAST word
    // of this 16-byte-aligned line, so its speculative not-taken
    // fall-through is guaranteed to cross straight into a fresh,
    // never-touched line (line_e) on the very next fetch -- the real bug's
    // index-7 role exactly. This line itself also fills fresh on first
    // visit (like every line here); by the time bnez is actually fetched
    // (a hit, since line_d's own fill already completed to reach this
    // point), the fall-through into line_e is a brand new miss landing
    // right as bnez resolves in EX -- the coincidence under test.
    .align 4
line_d:
    nop
    nop
    addi t0, t0, -1
    bnez t0, line_v          // taken on the first (only) pass -- t0 was 2,
                              // now 1 -- jumps back into the already-cached
                              // line_v while line_e's fresh miss is in
                              // flight from the speculative fall-through

    // --- line_e: reached for real once the loop actually exits (t0==0,
    // branch not taken) on the second pass through line_d. If the bug
    // reproduces, execution never gets here at all -- the hang happens
    // during the revisit of line_v above.
line_e:
    li   t4, LED_GREEN_BOTH
    sw   t4, 0(t3)
1:  j 1b
