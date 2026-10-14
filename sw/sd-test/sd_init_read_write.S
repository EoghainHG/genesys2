// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Eoghain Gray

// sd_init_read_write.S -- bare-metal SD-card-in-SPI-mode driver, built and
// sim-verified 2026-09-06 BEFORE a physical SD card was available, against
// a behavioral card model (sim/spi-sd-tests/sd_card_model.sv) rather than
// real hardware. Runs the real
// SD-over-SPI initialization sequence (CMD0/CMD8/CMD55+ACMD41/CMD58) then
// a genuine write-then-read-back round trip (CMD24 then CMD17 twice) to
// confirm both directions actually work, not just one.
//
// Register-liveness note (no formal calling convention followed --
// this project's other hand-written .S tests don't either, e.g.
// sim/plic-tests/*.S use t0-t2 freely with no ABI compliance): spi_xfer
// clobbers a0/t0/t1/t2, so anything a CALLER needs to survive a `jal
// spi_xfer` (or anything that itself calls spi_xfer) must live in t3+ or
// an s-register instead -- get this wrong and a loop counter or saved
// byte silently corrupts mid-sequence. s0/s1 are used for values that must
// survive across MULTIPLE nested helper calls (ACMD41 retry count, the
// 512-byte transfer index); t3/t4 for a single helper's own internal state.
//
// No tohost hardware — this runs under sim/tb_riscv.sv (regression binary,
// not the LUTRAM-boot convention sw/uart-test uses), signaling pass/fail
// via the standard .tohost word like every other riscv-tests-style test.

#include "sd_test_macros.h"

.section .text.init
.globl _start
.align 2
_start:
    li   sp, 0x80020000

    li   t0, SPI_CLKDIV
    li   t1, SPI_CLKDIV_INIT
    sw   t1, 0(t0)

    // Power-on: CS high, >=74 clock pulses before ever asserting CS or
    // sending a real command (real SD spec requirement) -- 10 bytes = 80
    // clocks, comfortable margin.
    jal  spi_cs_high
    li   s0, 10
poweron_loop:
    li   a0, 0xFF
    jal  spi_xfer
    addi s0, s0, -1
    bnez s0, poweron_loop

    // ---- CMD0: GO_IDLE_STATE ----
    // Retried up to MAX_CMD0_TRIES times (2026-09-06, first real-hardware
    // attempt against a physical card): unlike the ACMD41 loop below (which
    // was ALREADY known to need retries, per sd_card_model.sv's own
    // deliberate 3-poll delay), this test originally sent CMD0 only once,
    // relying solely on spi_poll_response's inner byte-level polling. Real
    // hardware showed this isn't enough on its own -- confirmed run-to-run
    // inconsistent on the actual card (one clean run reached CMD17 with
    // zero CMD0 trouble; two immediately-following runs got no CMD0
    // response at all, ruling out a one-off glitch). A single failed CMD0
    // attempt right after power-on is a well-known real-SD-card behavior,
    // not unique to this driver -- most real reference SD-SPI drivers retry
    // CMD0 itself (not just poll one attempt's response bytes) for exactly
    // this reason.
    li   s0, 0
cmd0_try:
    jal  spi_cs_low
    la   a0, cmd0_bytes
    jal  spi_send_cmd6
    jal  spi_poll_response
    jal  spi_cs_high
    li   t0, 0x01
    beq  a0, t0, cmd0_ok
    addi s0, s0, 1
    li   t0, MAX_CMD0_TRIES
    bne  s0, t0, cmd0_try
    j    cmd0_fail
cmd0_ok:

    // ---- CMD8: SEND_IF_COND -- confirms SD v2+ and echoes the check pattern ----
    jal  spi_cs_low
    la   a0, cmd8_bytes
    jal  spi_send_cmd6
    jal  spi_poll_response
    li   t0, 0x01
    bne  a0, t0, cmd8_fail_cs
    li   a0, 0xFF
    jal  spi_xfer                // echoed voltage-range byte (unused)
    li   a0, 0xFF
    jal  spi_xfer                // reserved byte (unused)
    li   a0, 0xFF
    jal  spi_xfer                // reserved byte (unused)
    li   a0, 0xFF
    jal  spi_xfer                // echoed check-pattern byte -- must be 0xAA
    jal  spi_cs_high
    li   t0, 0xAA
    bne  a0, t0, cmd8_badecho_fail
    j    acmd41_loop
cmd0_fail:
    li   s2, 1
    j    fail
cmd8_fail_cs:
    jal  spi_cs_high
    li   s2, 2
    j    fail
cmd8_badecho_fail:
    li   s2, 3
    j    fail

    // ---- CMD55+ACMD41 loop: real cards don't leave idle on the first
    // poll, and neither does the model (deliberately, 3 polls) -- this
    // retry loop is exercised for real, not just present as boilerplate. ----
acmd41_loop:
    li   s0, 0
acmd41_try:
    jal  spi_cs_low
    la   a0, cmd55_bytes
    jal  spi_send_cmd6
    jal  spi_poll_response
    jal  spi_cs_high            // CMD55's own response isn't strictly
                                 // checked -- ACMD41's response below is
                                 // authoritative, matching real driver practice.

    jal  spi_cs_low
    la   a0, cmd41_bytes
    jal  spi_send_cmd6
    jal  spi_poll_response
    jal  spi_cs_high
    beqz a0, acmd41_ready
    addi s0, s0, 1
    li   t0, MAX_ACMD41_TRIES
    bne  s0, t0, acmd41_try
    li   s2, 4                  // never left idle -- a real failure, not a bug here
    j    fail
acmd41_ready:

    // ---- CMD58: READ_OCR -- confirm CCS (SDHC/block-addressed) ----
    jal  spi_cs_low
    la   a0, cmd58_bytes
    jal  spi_send_cmd6
    jal  spi_poll_response
    li   t0, 0x00
    bne  a0, t0, cmd58_fail_cs
    li   a0, 0xFF
    jal  spi_xfer
    mv   s0, a0                 // OCR byte 0 (power-up status | CCS)
    li   a0, 0xFF
    jal  spi_xfer
    li   a0, 0xFF
    jal  spi_xfer
    li   a0, 0xFF
    jal  spi_xfer
    jal  spi_cs_high
    andi t0, s0, 0x40
    beqz t0, cmd58_notccs_fail
    // ---- CMD16: SET_BLOCKLEN=512 (2026-09-07, real hardware) -- technically
    // optional for SDHC/SDXC cards (block length is fixed at 512 internally
    // per spec), but never sent by this driver before now, and a classic
    // real-world compatibility fix for cards that still expect it. Tried
    // after Nwr gap, dummy/real CRC16, clock rate, and a spurious-byte
    // false-stop were all ruled out for CMD24's persistent no-valid-token
    // result -- CMD24/CMD17 already worked fine without it
    // for the read path, but worth confirming it doesn't change the write
    // outcome before concluding this needs a different physical card.
    jal  spi_cs_low
    la   a0, cmd16_bytes
    jal  spi_send_cmd6
    jal  spi_poll_response
    jal  spi_cs_high
    li   t0, 0x00
    bne  a0, t0, cmd16_fail
    j    switch_fast_clock
cmd16_fail:
    li   s2, 14
    j    fail
cmd58_fail_cs:
    jal  spi_cs_high
    li   s2, 5
    j    fail
cmd58_notccs_fail:
    li   s2, 6
    j    fail

switch_fast_clock:
    li   t0, SPI_CLKDIV
    li   t1, SPI_CLKDIV_DATA
    sw   t1, 0(t0)
    li   s3, 0                    // do_write retry counter (see do_write's header)

    // ---- CMD17: READ_SINGLE_BLOCK -- pre-write read. In sim this checks the
    // model's initial pattern (block_mem[i] = i & 0xFF); on real hardware
    // that check is informational only (a real card's block contents are
    // whatever's there). The point that matters is draining the FULL block
    // so the read terminates cleanly -- see read1_next's comment. ----
    jal  spi_cs_low
    la   a0, cmd17_bytes
    jal  spi_send_cmd6
    jal  spi_poll_response
    li   t0, 0x00
    bne  a0, t0, cmd17a_noresp_fail
    jal  spi_poll_datatoken
    beqz a0, cmd17a_notoken_fail
    li   s1, 0
    li   s4, -1                   // first byte index where data != sim pattern; -1 = matched all
read1_loop:
    li   a0, 0xFF
    jal  spi_xfer
    andi t0, s1, 0xFF            // sim model has block_mem[i] = i & 0xFF; a real
                                 // card almost never holds this -- the check is
                                 // purely informational (see below).
    beq  a0, t0, read1_next
    bgez s4, read1_next          // keep only the FIRST divergence index
    mv   s4, s1
read1_next:
    // CRITICAL (2026-09-09, ILA-confirmed bug fix): ALWAYS clock out all 512
    // data bytes + 2 CRC bytes, even on a pattern mismatch. The old code
    // jumped out of this loop on the first mismatch (`bne ...
    // cmd17a_pattern_fail`), consuming only ~3 of the card's 514 queued bytes
    // before deasserting CS and moving to CMD24. A real card that does NOT
    // abort a single-block read on CS-deassert then stayed mid-stream and
    // clocked block data onto DAT0 for every subsequent SCLK -- ignoring the
    // CMD24 bytes on MOSI entirely (ILA: MISO byte value decrementing once
    // per SPI byte == this test's own 0xFF-(i&0xFF) write pattern left in
    // block 200000 by a prior successful run), and staying wedged until a
    // card power-cycle (the "must reseat every run" symptom). Draining the
    // whole block here lets the single-block read terminate cleanly.
    addi s1, s1, 1
    li   t0, 512
    bne  s1, t0, read1_loop
    li   a0, 0xFF
    jal  spi_xfer                // CRC16 hi (unchecked)
    li   a0, 0xFF
    jal  spi_xfer                // CRC16 lo (unchecked)
    jal  spi_cs_high
    la   t0, debug_byte_idx
    sw   s4, 0(t0)               // informational: first pattern-divergence index (-1 = none)
    j    do_write
cmd17a_noresp_fail:
    jal  spi_cs_high
    li   s2, 7
    j    fail
cmd17a_notoken_fail:
    jal  spi_cs_high
    li   s2, 10
    j    fail

    // ---- CMD24: WRITE_BLOCK -- write a pattern DIFFERENT from the
    // initial one (0xFF - (i & 0xFF)), so the read-back below can only
    // pass if the write genuinely took effect. ----
do_write:
    // Pure-timing experiment (2026-09-08): sd_write_pmon.S (this file's
    // I2C-instrumented sibling) passed 4/4 real-hardware runs right after
    // this file failed 5/5 in a row, same reseated card, same bitstream,
    // same busy_drain fix present in both. The only functional difference
    // is pmon's I2C bit-bang voltage sampling at 4 points per attempt --
    // testing here whether it's really about ELAPSED TIME between
    // operations (the card needing more settling time than this file's
    // tight back-to-back timing gives it) rather than the I2C activity
    // itself, by inserting an equivalent plain delay (no bus activity at
    // all) at the same 4 points pmon samples voltage. See delay_1ms's own
    // header for why it's safe to call from anywhere in this file.
    jal  delay_1ms
    jal  spi_cs_low
    la   a0, cmd24_bytes
    jal  spi_send_cmd6
    jal  spi_poll_response
    li   t0, 0x00
    bne  a0, t0, cmd24_noresp_fail
    jal  delay_1ms
    // Nwr turnaround gap (2026-09-06, real hardware): real SD-SPI drivers
    // insert at least one dummy byte between R1 and the start-block token
    // for a WRITE -- unlike CMD17's read path, where the CARD decides when
    // to emit its own token and the host just polls (self-correcting for
    // any card-side delay), here the HOST picks the moment to send 0xFE.
    // Sending it immediately, with zero gap after R1, was the one thing
    // this driver never did for write that it effectively always got for
    // free on read. Real hardware reached this exact point completely
    // reliably three runs in a row (CMD0-CMD17 all solid post sd_reset fix)
    // but never got a valid data-response token afterward -- consistent
    // with the card's own state machine not being ready yet.
    // Nwr gap widened 1->4 bytes (2026-09-07): the 1-byte gap didn't clear
    // cmd24_notoken_fail, and neither did the dummy-CRC-value nor
    // clock-speed theories tried afterward -- an ILA capture showed the
    // exact same 0xE0/0x9F byte pair right after CRC in all of those cases,
    // completely unchanged by clock rate or CRC content.
    // Trying more Nwr margin in case this card needs longer than 1 byte
    // to be ready for the start token, even though this is unlikely to
    // explain a fixed, content/clock-invariant artifact by itself.
    li   t4, 4
1:  li   a0, 0xFF
    jal  spi_xfer                 // Nwr turnaround byte
    addi t4, t4, -1
    bnez t4, 1b
    li   a0, 0xFE
    jal  spi_xfer                 // data start token
    li   s1, 0
    li   s2, 0                    // CRC16-CCITT accumulator (poly 0x1021, init 0)
write_loop:
    andi t0, s1, 0xFF
    li   t1, 0xFF
    sub  a1, t1, t0
    andi a1, a1, 0xFF              // a1 = tx byte, kept live across spi_xfer (clobbers a0 only)
    mv   a0, a1
    jal  spi_xfer
    // CRC16-CCITT (CRC-16/XMODEM) update over the byte just sent, bit-by-bit,
    // MSB first, no reflection, no final XOR -- 2026-09-07, real hardware:
    // two independent dummy-CRC values (0xFF, then 0x00) both left CMD24
    // stuck at cmd24_notoken_fail, and a direct ILA capture of the real bus
    // then caught the SAME two-byte value (0xE0, 0x9F)
    // appearing right after CRC at both ~14MHz and ~3.5MHz data-phase clock
    // rates -- bit-for-bit identical across a 4x clock change rules out a
    // signal-integrity/ringing explanation (that would look different at a
    // different clock rate) and points at a real, deterministic card
    // response: this card most likely validates the data block's CRC16 even
    // though SPI mode nominally makes that optional, and 0xE0/0x9F is its
    // rejection response to our dummy value -- a well-known real-world SD
    // card quirk (real drivers like FatFs/Arduino SD/Linux mmc_spi always
    // send a genuine computed CRC16 for exactly this reason).
    // andi can't take 0xFFFF/0x8000 as immediates (RV32I andi is a 12-bit
    // signed-immediate I-type op) -- masking to 16 bits isn't needed
    // functionally anyway: garbage above bit 15 just harmlessly shifts
    // further left each round and never affects the final srli-by-8/andi
    // 0xFF extraction below, and the bit-15 test uses srli+andi 1 instead.
    slli t0, a1, 8
    xor  s2, s2, t0
    li   t3, 8
1:  srli t0, s2, 15
    andi t0, t0, 1
    slli s2, s2, 1
    beqz t0, 2f
    li   t1, 0x1021
    xor  s2, s2, t1
2:  addi t3, t3, -1
    bnez t3, 1b
    addi s1, s1, 1
    li   t0, 512
    bne  s1, t0, write_loop
    srli a0, s2, 8
    andi a0, a0, 0xFF
    jal  spi_xfer                 // CRC16 hi (real)
    andi a0, s2, 0xFF
    jal  spi_xfer                 // CRC16 lo (real)
    jal  delay_1ms
    // ILA debug marker (2026-09-07): asserts led[5] the instant data+CRC
    // are fully sent and this driver is about to start polling for the
    // data-response token -- fpga/capture_cmd24_ila.tcl triggers on this,
    // not on the raw SPI bytes directly, since a full CMD24 transaction
    // (command+R1 poll+512 data bytes+CRC) already exceeds a Basic-tier
    // ILA's practical capture depth at the ~14MHz data-phase SCLK rate.
    // Clobbers t0,t1 -- both dead here (about to reinit t3 for the poll).
    li   t0, GPIO_ADDR
    li   t1, 0x20
    sw   t1, 0(t0)
    // Data-response token (2026-09-06, real hardware): originally a single
    // blind read, same "assumes instant response" mistake already found in
    // MAX_ACMD41_TRIES/MAX_DATATOKEN_POLLS above. First fix (poll until not
    // exactly 0xFF) wasn't strict enough -- real hardware caught 0xE0 (bit0
    // clear) passing that check, which is not a legal token shape at all
    // (real tokens are always ???0SSS1: bit4 clear, bit0 set) -- almost
    // certainly a transitional/glitchy sample right as the card starts
    // driving the line, at the ~14MHz data-phase clock, not a real
    // response. Poll for the actual token SHAPE (bit4 clear, bit0 set)
    // instead of merely "not idle-high" -- 0xFF itself also has bit0 set,
    // but bit4 set too, so it's still correctly rejected by this check.
    // Status-value filter (2026-09-07, real hardware): an ILA capture
    // proved the raw bytes seen right around here (0xE0/0x9F, or 0xF8/0x27
    // depending on Nwr gap length) are NOT the card reacting to our data or
    // CRC at all -- widening the Nwr gap from 1 to 4 bytes shifted the
    // exact byte position of this event by precisely the extra 96 core
    // cycles added, unchanged by CRC content (dummy vs. a verified-correct
    // real CRC16) and unchanged by a 4x SPI clock-rate change. That's a
    // fixed-cycle-count transient tied to something early in the CMD24
    // transaction (command/R1 phase), not the data-response token -- most
    // likely a brief card-internal blip on DAT0. The old coarse shape check
    // (bit4=0,bit0=1) isn't enough: 0x27's status bits (0b011) merely
    // COINCIDED with that shape while being a value the SD spec never
    // defines (only 010=accepted, 101=CRC error, 110=write error are real),
    // so a genuine token can never legitimately produce it -- treat any
    // shape-matching byte with a status outside those three as more of the
    // same transient and keep polling, rather than treating the first
    // shape-coincidence as gospel.
    li   t3, 0
dataresp_poll:
    li   a0, 0xFF
    jal  spi_xfer                 // data-response token
    andi t0, a0, 0x11             // bit4 | bit0
    li   t1, 0x01                 // want bit4=0, bit0=1
    bne  t0, t1, dataresp_next     // not even token-shaped -- keep polling
    andi t0, a0, 0x1E              // status bits, still with bit4(=0) included
    li   t1, 0x04                  // 0b0010_0 -> accepted
    beq  t0, t1, dataresp_got
    li   t1, 0x0A                  // 0b0101_0 -> CRC error
    beq  t0, t1, dataresp_got
    li   t1, 0x0C                  // 0b0110_0 -> write error
    beq  t0, t1, dataresp_got
    // shape matched but status isn't one of the three real SD values --
    // spurious/transient, not a token. Fall through and keep polling.
dataresp_next:
    addi t3, t3, 1
    li   t0, MAX_DATARESP_POLLS
    bne  t3, t0, dataresp_poll
    j    cmd24_notoken_fail        // never saw the card drive anything at all
dataresp_got:
    jal  delay_1ms
    mv   s1, a0                   // save raw token byte for diagnostics
    andi t0, a0, 0x1F
    li   t1, 0x05
    bne  t0, t1, cmd24_badtoken_fail
    li   s1, 0
busy_poll:
    li   a0, 0xFF
    jal  spi_xfer
    bnez a0, busy_done           // non-zero = card no longer busy
    addi s1, s1, 1
    li   t0, MAX_BUSY_POLLS
    bne  s1, t0, busy_poll
    j    cmd24_busy_fail
busy_done:
    jal  spi_cs_high
    j    verify_write
    // Write-attempt retry (2026-09-07, real hardware): Nwr gap, dummy/real
    // CRC16, clock rate, and CMD16 were all ruled out for CMD24's
    // persistent no-valid-token result without ever
    // testing whether this specific card simply needs a "warm-up" -- some
    // controllers behave oddly on their first write immediately after
    // leaving idle. Retry the WHOLE do_write attempt (fresh CMD24, fresh
    // R1, fresh data+CRC) up to MAX_WRITE_RETRIES times before giving up;
    // s3 (initialized once, before the first do_write attempt) survives
    // across attempts since nothing else in do_write touches it.
cmd24_noresp_fail:
    // Diagnostic (2026-09-09): checkpoint 8 has become the stable, repeatable
    // failure (read path 100% solid, only CMD24's R1 check fails) but never
    // recorded WHAT R1 was -- a spi_poll_response timeout (0xFF), a card
    // fallen back to idle (0x01), or a real error R1 (bit2 illegal-cmd, bit3
    // CRC, bit5 addr, bit6 param) all look identical from tohost alone.
    // spi_cs_high preserves a0 (the R1 byte from spi_poll_response above);
    // stash (retry_index << 8) | R1 into debug_byte_idx. Overwritten each
    // retry, so the reported value is the LAST (typically 10th) attempt's.
    jal  spi_cs_high
    la   t0, debug_byte_idx
    slli t1, s3, 8
    or   t1, t1, a0
    sw   t1, 0(t0)
    li   s2, 8
    j    write_check_retry
cmd24_notoken_fail:
    jal  delay_1ms
    jal  spi_cs_high
    li   s2, 13
    j    write_check_retry
cmd24_badtoken_fail:
    // s1 holds the raw data-response token byte received (saved above,
    // right after the check) -- real cards mask the low 5 bits for
    // ACCEPTED(0b010)/CRC_ERROR(0b101)/WRITE_ERROR(0b110); a completely
    // different byte here (e.g. 0xFF, meaning nothing was driven at all)
    // points at a different problem than a real rejected write.
    la   t0, debug_byte_idx
    sw   s1, 0(t0)
    jal  spi_cs_high
    li   s2, 11
    j    write_check_retry
cmd24_busy_fail:
    jal  spi_cs_high
    li   s2, 12
write_check_retry:
    // Busy drain (2026-09-08, real hardware): per the official SD spec's
    // SPI-mode chapter, deselecting CS does NOT stop the card's internal
    // programming if a write was actually accepted and is still busy (it
    // keeps running, DataOut just tri-states while deselected) -- and
    // separately, "resetting a card (CMD0) will terminate any pending or
    // active programming operation... it is in the responsibility of the
    // host to prevent it." A failed attempt here only means WE didn't see
    // a clean token/response -- it doesn't guarantee the card isn't still
    // mid-write internally (our own token detection could time out while
    // the card was legitimately still working). Without this drain, the
    // next retry -- or worse, a full reboot's fresh CMD0, e.g. from
    // pressing cpu_resetn to rerun the whole test -- could interrupt a
    // still-active write and corrupt the card's internal state. A
    // genuinely plausible explanation for why this project's own repeated
    // retries sometimes seemed to make later runs worse instead of
    // isolating consistent behavior.
    //
    // The checkpoint code lives in s2 (not a t-register) specifically
    // BECAUSE of that same class of bug already found once before in this
    // file (see spi_cs_high's own header): drain_busy calls spi_xfer
    // internally, which clobbers t0-t2 -- routing the checkpoint through
    // any t-register across this jal would silently destroy it exactly
    // the way spi_cs_high's old a0-clobber bug did. Confirmed the hard
    // way (2026-09-08): an earlier version of this fix used t2, and every
    // failure read back checkpoint=0 (t2 left at spi_xfer's own internal
    // busy-poll's final loop value, 0, not any real checkpoint) --
    // pattern-matches that older bug precisely.
    jal  drain_busy
    addi s3, s3, 1
    li   t0, MAX_WRITE_RETRIES
    bne  s3, t0, do_write
    j    fail

    // ---- CMD17 again: confirm the write really landed. ----
verify_write:
    li   s5, 0                    // 0 = every byte matched, 1 = at least one mismatch
    li   s4, -1                   // first mismatching byte index (-1 = none), for diagnostics
                                  // (init before the R1/token checks so a checkpoint-9 from
                                  //  those shows -1, not a stale read1 index)
    jal  spi_cs_low
    la   a0, cmd17_bytes
    jal  spi_send_cmd6
    jal  spi_poll_response
    li   t0, 0x00
    bne  a0, t0, cmd17b_fail_cs
    jal  spi_poll_datatoken
    beqz a0, cmd17b_fail_cs
    li   s1, 0
read2_loop:
    li   a0, 0xFF
    jal  spi_xfer
    andi t0, s1, 0xFF
    li   t1, 0xFF
    sub  t1, t1, t0
    andi t1, t1, 0xFF            // expected = 0xFF - (i & 0xFF), the pattern CMD24 wrote
    beq  a0, t1, read2_next
    li   s5, 1
    bgez s4, read2_next
    mv   s4, s1
read2_next:
    // Same ILA-confirmed rule as read1_loop (2026-09-09): drain ALL 512 data
    // + 2 CRC bytes before deciding pass/fail, so the single-block read
    // always terminates cleanly on the card. The old `bne a0,t1,
    // cmd17b_fail_cs` bailed mid-block, leaving the card streaming -- which
    // corrupted the following retry AND the next whole test run (next CMD0
    // got swallowed as read clocks -> checkpoint 1).
    addi s1, s1, 1
    li   t0, 512
    bne  s1, t0, read2_loop
    li   a0, 0xFF
    jal  spi_xfer                // CRC16 hi (unchecked)
    li   a0, 0xFF
    jal  spi_xfer                // CRC16 lo (unchecked)
    jal  spi_cs_high
    bnez s5, cmd17b_fail_cs
    j    pass
cmd17b_fail_cs:
    la   t0, debug_byte_idx
    sw   s4, 0(t0)               // first mismatching byte index in the verify read
    jal  spi_cs_high
    li   s2, 9
    j    fail

pass:
    li   t0, 1
    la   t1, tohost
    sw   t0, 0(t1)
    sw   zero, 4(t1)
1:  j    1b

// fail: writes a per-checkpoint code (set in s2 by each failure site above,
// 1-9 -- see each site's own comment for what it means) into tohost's
// UPPER 16 bits, with the low bits still the standard riscv-tests
// odd-value FAIL sentinel (so `(tohost>>1)&1`-style generic-fail checks
// elsewhere still see a fail). Real hardware has no sim harness to print
// through, so this is read back directly over JTAG-AXI
// (fpga/read_sd_test_result.tcl) after the fact instead.
fail:
    slli t0, s2, 16
    ori  t0, t0, 3
    la   t1, tohost
    sw   t0, 0(t1)
    sw   zero, 4(t1)
1:  j    1b

// -----------------------------------------------------------------------
// Helpers
// -----------------------------------------------------------------------

// Leaf. a0 = byte to send -> a0 = byte received. Clobbers a0,t0,t1,t2.
spi_xfer:
    li   t0, SPI_TXRX
    sb   a0, 0(t0)
1:  li   t1, SPI_STATUS
    lw   t2, 0(t1)
    andi t2, t2, 1
    bnez t2, 1b
    lw   a0, 0(t0)
    andi a0, a0, 0xFF
    ret

// Leaf. Asserts cs_n=0. Clobbers t0.
spi_cs_low:
    li   t0, SPI_CTRL
    sw   zero, 0(t0)
    ret

// Non-leaf (calls spi_xfer). Deasserts cs_n=1 + one dummy 0xFF byte.
// REAL BUG found and fixed 2026-09-06: this used to clobber the caller's
// a0 with its own dummy transfer's received byte -- since every call site
// in this file does `jal spi_poll_response` (result in a0) immediately
// followed by `jal spi_cs_high` before checking a0, every single such
// check was silently examining spi_cs_high's own dummy-byte result
// instead of the real response. A real hardware trace (spi_master.sv's
// own debug print) showed the correct response byte (0x01) actually
// arriving, while the software-visible a0 read back 0xFF -- the
// discrepancy between "hardware genuinely got it right" and "software
// still failed" pointed straight at this clobber. Fixed by saving/
// restoring the caller's a0 around this routine's own internal transfer,
// in t3 (already used internally by spi_poll_response/spi_poll_datatoken,
// but never live across a *separate* spi_cs_high call, so safe here).
// Clobbers t0,t1,t2,t3,ra -- NOT a0 anymore.
spi_cs_high:
    addi sp, sp, -16
    sw   ra, 12(sp)
    mv   t3, a0
    li   t0, SPI_CTRL
    li   t1, 1
    sw   t1, 0(t0)
    li   a0, 0xFF
    jal  spi_xfer
    mv   a0, t3
    lw   ra, 12(sp)
    addi sp, sp, 16
    ret

// Non-leaf. a0 = pointer to 6 command bytes. Sends all 6, discards
// responses. Clobbers a0,t0,t1,t2,t3,t4,ra.
spi_send_cmd6:
    addi sp, sp, -16
    sw   ra, 12(sp)
    mv   t3, a0
    li   t4, 0
1:  add  t0, t3, t4
    lbu  a0, 0(t0)
    jal  spi_xfer
    addi t4, t4, 1
    li   t0, 6
    bne  t4, t0, 1b
    lw   ra, 12(sp)
    addi sp, sp, 16
    ret

// Non-leaf. Polls up to MAX_RESPONSE_POLLS times sending 0xFF, returns the
// first byte with bit7 clear in a0 (a real R1 response always has bit7=0).
// Returns 0xFF (never a real R1 value) on timeout. Clobbers a0,t0,t3,ra.
spi_poll_response:
    addi sp, sp, -16
    sw   ra, 12(sp)
    li   t3, 0
1:  li   a0, 0xFF
    jal  spi_xfer
    andi t0, a0, 0x80
    beqz t0, 2f
    addi t3, t3, 1
    li   t0, MAX_RESPONSE_POLLS
    bne  t3, t0, 1b
    li   a0, 0xFF
2:  lw   ra, 12(sp)
    addi sp, sp, 16
    ret

// Non-leaf. Polls up to MAX_DATATOKEN_POLLS times for the 0xFE data start
// token. a0=1 if found, a0=0 on timeout. Clobbers a0,t0,t3,ra.
spi_poll_datatoken:
    addi sp, sp, -16
    sw   ra, 12(sp)
    li   t3, 0
1:  li   a0, 0xFF
    jal  spi_xfer
    li   t0, 0xFE
    beq  a0, t0, 2f
    addi t3, t3, 1
    li   t0, MAX_DATATOKEN_POLLS
    bne  t3, t0, 1b
    li   a0, 0
    j    3f
2:  li   a0, 1
3:  lw   ra, 12(sp)
    addi sp, sp, 16
    ret

// Leaf. Fixed ~1ms delay (roughly matching the total I2C bit-bang overhead
// sd_write_pmon.S's voltage sampling adds at each of the 4 points this is
// called from) -- 2026-09-08 pure-timing experiment, see do_write's own
// header comment for the full reasoning. Uses t6 exclusively, which
// nothing else in this file touches, so it's safe to call from anywhere
// (including right before a caller reads a0, unlike the I2C helpers this
// is standing in for) without clobbering anything. ~28000 iterations at
// ~2 cycles each / clk_core's real ~56.26MHz.
delay_1ms:
    li   t6, 28000
1:  addi t6, t6, -1
    bnez t6, 1b
    ret

// Non-leaf. Re-selects the card and polls up to MAX_BUSY_POLLS times for
// DataOut to release, then deselects again -- called from do_write's
// write_check_retry (see that label's own comment for why every failure
// path needs this, not just the success path busy_poll already had).
// Bounded the same way busy_poll is, so a card that's genuinely wedged
// can't hang this forever. Clobbers a0,t0,t1,t2,t3,ra.
drain_busy:
    addi sp, sp, -16
    sw   ra, 12(sp)
    jal  spi_cs_low
    li   t3, 0
drain_busy_poll:
    li   a0, 0xFF
    jal  spi_xfer
    bnez a0, drain_busy_done
    addi t3, t3, 1
    li   t0, MAX_BUSY_POLLS
    bne  t3, t0, drain_busy_poll
drain_busy_done:
    jal  spi_cs_high
    lw   ra, 12(sp)
    addi sp, sp, 16
    ret

.section .data
.align 2
// Real-hardware diagnostic scratch word (read back over JTAG-AXI after
// halt, since there's no sim harness to print through) -- see
// cmd17a_pattern_fail's own comment for what this holds.
.globl debug_byte_idx
debug_byte_idx: .word 0xFFFFFFFF

// Fixed command frames: {0x40|cmd_index, arg[31:24], arg[23:16], arg[15:8],
// arg[7:0], crc7<<1|1}. CMD0 (arg=0) and CMD8 (arg=0x1AA) need real,
// well-known CRC7 values (0x95, 0x87) -- the only two commands SPI mode
// checks CRC on by default; all others use 0xFF (don't-care CRC + stop bit)
// since sd_card_model.sv doesn't check CRC on them (see its own header).
cmd0_bytes:  .byte 0x40, 0x00, 0x00, 0x00, 0x00, 0x95
cmd8_bytes:  .byte 0x48, 0x00, 0x00, 0x01, 0xAA, 0x87
cmd55_bytes: .byte 0x77, 0x00, 0x00, 0x00, 0x00, 0xFF
cmd41_bytes: .byte 0x69, 0x40, 0x00, 0x00, 0x00, 0xFF
cmd58_bytes: .byte 0x7A, 0x00, 0x00, 0x00, 0x00, 0xFF
cmd16_bytes: .byte 0x50, 0x00, 0x00, 0x02, 0x00, 0xFF   // SET_BLOCKLEN, arg=512
// Full 32-bit block address, MSB first -- TEST_BLOCK_NUM used to be small
// enough (<=255) that hardcoding the upper 3 bytes to 0x00 happened to
// work, but that silently only supported block numbers 0-255. Fixed
// 2026-09-08 when raising TEST_BLOCK_NUM well past 255 to test whether the
// low-LBA MBR/partition-table region was ever the real issue.
cmd17_bytes: .byte 0x51, ((TEST_BLOCK_NUM>>24)&0xFF), ((TEST_BLOCK_NUM>>16)&0xFF), ((TEST_BLOCK_NUM>>8)&0xFF), (TEST_BLOCK_NUM&0xFF), 0xFF
cmd24_bytes: .byte 0x58, ((TEST_BLOCK_NUM>>24)&0xFF), ((TEST_BLOCK_NUM>>16)&0xFF), ((TEST_BLOCK_NUM>>8)&0xFF), (TEST_BLOCK_NUM&0xFF), 0xFF

.section .tohost
.align 3
.globl tohost
tohost:
    .word 0
    .word 0
