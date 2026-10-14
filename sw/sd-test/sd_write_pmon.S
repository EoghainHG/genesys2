// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Eoghain Gray

// sd_write_pmon.S -- real-hardware-only variant of sd_init_read_write.S
// (2026-09-07/08) that samples two of the Genesys 2's onboard INA219 power
// monitors over I2C -- VCC3V3 (the SD slot's own I/O rail) and VCC1V0
// (VCCINT, the FPGA's own core rail) -- at four safe points around a CMD24
// write attempt, to test the write-failure power-margin theory from
// this test without an oscilloscope. Not sim-tested (see Makefile's
// build-sd-write-pmon target header comment for why) -- everything through
// CMD16/CMD17/do_write's SD-SPI logic is otherwise IDENTICAL to
// sd_init_read_write.S, copied rather than shared/included, so this file's
// own edits never risk that file's already-hardware-proven behavior.
//
// 2026-09-08 update: VCC3V3 alone showed no meaningful variation across 10
// full write attempts (all readings within the INA219's own 4mV ADC
// quantization noise) -- ruling out a sag on the SD
// slot's own supply as the failure mechanism, at least at this sampling
// granularity. Added VCC1V0 as a different theory: internal FPGA switching
// activity during the tight write_loop could sag VCCINT itself (a much
// tighter-tolerance rail than 3.3V), which would explain both CMD24 and the
// CMD0 regressions as an FPGA-internal reliability issue, not an SD-card-
// side one. store_vcc3v3/store_vcc1v0 (see i2c_read_rail's own header)
// each keep their own separate sample array -- reconstruct which
// attempt/checkpoint a given index belongs to from its position (index
// MOD 4), not from any tag stored alongside it.
//
// The four sample points, each now TWO calls (store_vcc3v3 then
// store_vcc1v0):
//   P0 -- right as do_write starts, before CMD24 is even sent (baseline).
//   P1 -- right after CMD24's R1 confirms 0x00, before the Nwr gap.
//   P2 -- right after data+CRC are fully sent, before polling for the
//         data-response token (the same instant the ILA debug marker used
//         to fire in earlier sessions).
//   P3 -- right as the data-response poll concludes, whichever way (token
//         found, at dataresp_got; or timed out, at cmd24_notoken_fail).
// Deliberately NOT sampled from inside the write_loop or dataresp_poll
// loops themselves -- those are the one place in this driver where real
// protocol timing sensitivity has actually bitten before, and an I2C
// bit-bang read takes long enough (tens of microseconds each, now two per
// point) that inserting it mid-poll would meaningfully perturb the very
// thing being measured.

#include "sd_test_macros.h"

#define MAX_PMON_SAMPLES 48

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

    // ---- CMD55+ACMD41 loop ----
acmd41_loop:
    li   s0, 0
acmd41_try:
    jal  spi_cs_low
    la   a0, cmd55_bytes
    jal  spi_send_cmd6
    jal  spi_poll_response
    jal  spi_cs_high

    jal  spi_cs_low
    la   a0, cmd41_bytes
    jal  spi_send_cmd6
    jal  spi_poll_response
    jal  spi_cs_high
    beqz a0, acmd41_ready
    addi s0, s0, 1
    li   t0, MAX_ACMD41_TRIES
    bne  s0, t0, acmd41_try
    li   s2, 4
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
    // ---- CMD16: SET_BLOCKLEN=512 ----
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
    li   s3, 0                    // do_write retry counter

    // ---- CMD17: READ_SINGLE_BLOCK -- sanity check before ever writing. ----
    jal  spi_cs_low
    la   a0, cmd17_bytes
    jal  spi_send_cmd6
    jal  spi_poll_response
    li   t0, 0x00
    bne  a0, t0, cmd17a_noresp_fail
    jal  spi_poll_datatoken
    beqz a0, cmd17a_notoken_fail
    li   s1, 0
read1_loop:
    li   a0, 0xFF
    jal  spi_xfer
    addi s1, s1, 1
    li   t0, 512
    bne  s1, t0, read1_loop
    li   a0, 0xFF
    jal  spi_xfer                // CRC16 hi (unchecked)
    li   a0, 0xFF
    jal  spi_xfer                // CRC16 lo (unchecked)
    jal  spi_cs_high
    j    do_write
cmd17a_noresp_fail:
    jal  spi_cs_high
    li   s2, 7
    j    fail
cmd17a_notoken_fail:
    jal  spi_cs_high
    li   s2, 10
    j    fail

    // ---- CMD24: WRITE_BLOCK, instrumented with VCC3V3 voltage samples. ----
do_write:
    jal  store_vcc3v3              // P0: baseline, before CMD24 is even sent
    jal  store_vcc1v0
    jal  spi_cs_low
    la   a0, cmd24_bytes
    jal  spi_send_cmd6
    jal  spi_poll_response
    li   t0, 0x00
    bne  a0, t0, cmd24_noresp_fail
    jal  store_vcc3v3              // P1: right after R1 confirms 0x00
    jal  store_vcc1v0
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
    andi a1, a1, 0xFF
    mv   a0, a1
    jal  spi_xfer
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
    jal  store_vcc3v3              // P2: right after data+CRC, before polling
    jal  store_vcc1v0
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
dataresp_next:
    addi t3, t3, 1
    li   t0, MAX_DATARESP_POLLS
    bne  t3, t0, dataresp_poll
    j    cmd24_notoken_fail        // never saw the card drive anything at all
dataresp_got:
    // Save the real token byte and make the COMPLETE accept/reject
    // decision -- including the branch itself -- BEFORE taking any
    // voltage samples: store_vcc3v3/store_vcc1v0 both clobber a0,t0,t1
    // (same t0-t6 scratch as every other helper in this file), so calling
    // either of them between computing the comparison and branching on it
    // would silently corrupt the very values the branch depends on. REAL
    // BUG found and fixed 2026-09-08: an earlier version placed the P3
    // sample calls in between (or even before `mv s1,a0` entirely, an
    // even worse first attempt), and every subsequent real-hardware run's
    // badtoken_fail checkpoint ended up decided from leftover I2C state,
    // not the card's real response -- the exact same "clobbered-before-
    // use" class of bug as the t2/checkpoint issue in write_check_retry
    // above, just at a different call site. Fixed by finishing the
    // decision (and the branch) first, then sampling voltage separately
    // on each of the two resulting paths below.
    mv   s1, a0                   // save raw token byte for diagnostics
    andi t0, a0, 0x1F
    li   t1, 0x05
    bne  t0, t1, dataresp_rejected
    jal  store_vcc3v3              // P3: right as the poll concludes (accepted)
    jal  store_vcc1v0
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
cmd24_noresp_fail:
    jal  spi_cs_high
    li   s2, 8
    j    write_check_retry
cmd24_notoken_fail:
    jal  store_vcc3v3              // P3: right as the poll concludes (timeout)
    jal  store_vcc1v0
    jal  spi_cs_high
    li   s2, 13
    j    write_check_retry
dataresp_rejected:
    jal  store_vcc3v3              // P3: right as the poll concludes (rejected)
    jal  store_vcc1v0
cmd24_badtoken_fail:
    la   t0, debug_byte_idx
    sw   s1, 0(t0)
    jal  spi_cs_high
    li   s2, 11
    j    write_check_retry
cmd24_busy_fail:
    jal  spi_cs_high
    li   s2, 12
write_check_retry:
    // Busy drain (2026-09-08, mirrors sd_init_read_write.S -- see that
    // file's write_check_retry comment for the full spec-grounded
    // reasoning: a failed attempt doesn't guarantee the card isn't still
    // internally busy, and letting CMD0 interrupt an active write on the
    // next retry/reboot is a real, spec-warned corruption risk). Checkpoint
    // lives in s2 (not a t-register) -- drain_busy calls spi_xfer
    // internally, which clobbers t0-t2; an earlier version of this routed
    // the checkpoint through t2 and every failure read back checkpoint=0
    // as a result (confirmed on real hardware, 2026-09-08).
    jal  drain_busy
    addi s3, s3, 1
    li   t0, MAX_WRITE_RETRIES
    bne  s3, t0, do_write
    j    fail

    // ---- CMD17 again: confirm the write really landed. ----
verify_write:
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
    andi t1, t1, 0xFF
    bne  a0, t1, cmd17b_fail_cs
    addi s1, s1, 1
    li   t0, 512
    bne  s1, t0, read2_loop
    li   a0, 0xFF
    jal  spi_xfer
    li   a0, 0xFF
    jal  spi_xfer
    jal  spi_cs_high
    j    pass
cmd17b_fail_cs:
    jal  spi_cs_high
    li   s2, 9
    j    fail

pass:
    li   t0, 1
    la   t1, tohost
    sw   t0, 0(t1)
    sw   zero, 4(t1)
1:  j    1b

fail:
    slli t0, s2, 16
    ori  t0, t0, 3
    la   t1, tohost
    sw   t0, 0(t1)
    sw   zero, 4(t1)
1:  j    1b

// -----------------------------------------------------------------------
// SD-SPI helpers (identical to sd_init_read_write.S)
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

// Non-leaf. Deasserts cs_n=1 + one dummy 0xFF byte. Preserves caller's a0.
// Clobbers t0,t1,t2,t3,ra.
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
// first byte with bit7 clear in a0. Returns 0xFF on timeout.
// Clobbers a0,t0,t3,ra.
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

// Non-leaf. Re-selects the card and polls up to MAX_BUSY_POLLS times for
// DataOut to release, then deselects again -- see sd_init_read_write.S's
// copy of this routine (mirrored here) for the full reasoning. Clobbers
// a0,t0,t1,t2,t3,ra.
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

// -----------------------------------------------------------------------
// I2C bit-bang helpers (2026-09-07, new for this test) -- against
// rtl/periph/i2c_gpio.sv's bare open-drain register interface. Register
// usage deliberately avoids s0-s3 entirely (those hold do_write's own
// live state -- OCR byte, write index, retry counter -- across the points
// this file calls into these routines from), using only a0-a4 and t0-t6
// instead, all of which do_write's own SD-SPI logic never relies on
// surviving a call.
// -----------------------------------------------------------------------

// Leaf. Fixed delay for I2C timing margin -- only a minimum bus period is
// specified (Table 60-style budgets don't apply to a generic I2C slave the
// way they do to the SD card itself), so any comfortably-slow delay works.
// Clobbers t0.
i2c_delay:
    li   t0, 40
1:  addi t0, t0, -1
    bnez t0, 1b
    ret

// Leaf. a0 = value to write to I2C_REG (bit0=scl_out, bit1=sda_out, open-
// drain convention: 1=released/high, 0=driven low). Clobbers t0.
i2c_write_reg:
    li   t0, I2C_REG
    sw   a0, 0(t0)
    ret

// Leaf. Returns a0 = live I2C_REG read (bit0=scl, bit1=sda). Clobbers t0.
i2c_read_reg:
    li   t0, I2C_REG
    lw   a0, 0(t0)
    ret

// Non-leaf. Drives one SCL pulse while presenting bit0 of a0 on SDA
// (unchanged from before the call if the low bit was already what's
// needed -- callers pass 1 to release SDA when reading). Returns a0 = the
// SDA bit sampled while SCL was high (this IS the way both write-bit's
// don't-care sample and read-bit's/ACK's real sample are obtained -- one
// primitive covers both). Ends with SCL low, SDA released. Clobbers
// a0,a1,t0,ra.
i2c_clock_bit:
    addi sp, sp, -16
    sw   ra, 12(sp)
    andi a1, a0, 1
    li   a0, 0
    beqz a1, 1f
    ori  a0, a0, I2C_SDA_BIT
1:  jal  i2c_write_reg          // SCL=0, SDA=out_bit
    jal  i2c_delay
    ori  a0, a0, I2C_SCL_BIT    // raise SCL, SDA unchanged
    jal  i2c_write_reg
    jal  i2c_delay
    jal  i2c_read_reg           // a0 = live line state while SCL high
    andi a1, a0, I2C_SDA_BIT
    snez a1, a1                 // a1 = sampled SDA bit (0 or 1)
    li   a0, I2C_SDA_BIT        // lower SCL, release SDA (safe idle-ish default)
    jal  i2c_write_reg
    jal  i2c_delay
    mv   a0, a1
    lw   ra, 12(sp)
    addi sp, sp, 16
    ret

// Non-leaf. START condition: SDA falls while SCL is high, then SCL is
// lowered to prepare for the first bit. Assumes the bus was idle (both
// released) on entry -- true both at the very first call and after a
// preceding i2c_stop. Clobbers a0,t0,ra.
i2c_start:
    addi sp, sp, -16
    sw   ra, 12(sp)
    li   a0, I2C_IDLE
    jal  i2c_write_reg
    jal  i2c_delay
    li   a0, I2C_SCL_BIT        // SCL=1, SDA=0 -- the START condition itself
    jal  i2c_write_reg
    jal  i2c_delay
    li   a0, 0                  // SCL=0, SDA=0 -- ready for the first bit
    jal  i2c_write_reg
    jal  i2c_delay
    lw   ra, 12(sp)
    addi sp, sp, 16
    ret

// Non-leaf. STOP condition: SDA rises while SCL is high. Leaves the bus
// idle (both released). Clobbers a0,t0,ra.
i2c_stop:
    addi sp, sp, -16
    sw   ra, 12(sp)
    li   a0, 0                  // SCL=0, SDA=0
    jal  i2c_write_reg
    jal  i2c_delay
    li   a0, I2C_SCL_BIT        // SCL=1, SDA=0
    jal  i2c_write_reg
    jal  i2c_delay
    li   a0, I2C_IDLE           // SCL=1, SDA=1 -- the STOP condition itself
    jal  i2c_write_reg
    jal  i2c_delay
    lw   ra, 12(sp)
    addi sp, sp, 16
    ret

// Non-leaf. a0 = byte to send (MSB first). Returns a0 = 0 (ACK) or 1
// (NACK). Clobbers a0,a2,a3,t0,ra (plus whatever i2c_clock_bit clobbers).
i2c_write_byte:
    addi sp, sp, -16
    sw   ra, 12(sp)
    mv   a2, a0
    li   a3, 8
wb_loop:
    addi a3, a3, -1
    srl  a0, a2, a3
    andi a0, a0, 1
    jal  i2c_clock_bit
    bnez a3, wb_loop
    li   a0, 1                  // release SDA so the slave can drive ACK/NACK
    jal  i2c_clock_bit
    lw   ra, 12(sp)
    addi sp, sp, 16
    ret

// Non-leaf. a0 = 0 to send ACK after the byte, 1 for NACK (NACK on the
// last byte of a read, per I2C convention). Returns a0 = byte read (MSB
// first). Clobbers a0,a2,a3,a4,t0,ra.
i2c_read_byte:
    addi sp, sp, -16
    sw   ra, 12(sp)
    mv   a2, a0
    li   a3, 0
    li   a4, 8
rb_loop:
    li   a0, 1
    jal  i2c_clock_bit
    slli a3, a3, 1
    or   a3, a3, a0
    addi a4, a4, -1
    bnez a4, rb_loop
    mv   a0, a2
    jal  i2c_clock_bit
    mv   a0, a3
    lw   ra, 12(sp)
    addi sp, sp, 16
    ret

// Non-leaf. a0 = INA219 7-bit slave address. Returns a0 = that chip's
// bus-voltage register (0x02, a direct ADC value needing no prior
// calibration-register setup, unlike current/power) in millivolts. Doesn't
// store anywhere itself -- see store_vcc3v3/store_vcc1v0 below for the
// per-rail wrappers that append to each rail's own sample array. Uses
// t1-t3 for its own persistent state across the nested i2c_* calls above
// (none of which touch t1+) specifically so it never has to disturb
// s0-s3, which hold do_write's own live state at every call site this is
// used from (via the wrappers). Clobbers a0-a4,t0-t3,ra.
i2c_read_rail:
    addi sp, sp, -16
    sw   ra, 12(sp)
    slli t3, a0, 1                            // t3 = addr<<1, survives calls below

    jal  i2c_start
    mv   a0, t3                                // write mode (bit0=0)
    jal  i2c_write_byte
    li   a0, INA219_REG_BUSVOLTAGE
    jal  i2c_write_byte
    jal  i2c_start                             // repeated start
    ori  a0, t3, 1                             // read mode
    jal  i2c_write_byte
    li   a0, 0                                 // ACK after the high byte
    jal  i2c_read_byte
    mv   t1, a0                                // t1 = high byte
    li   a0, 1                                 // NACK after the low (last) byte
    jal  i2c_read_byte
    mv   t2, a0                                // t2 = low byte
    jal  i2c_stop

    slli t1, t1, 8
    or   t1, t1, t2               // t1 = raw 16-bit BUS_VOLTAGE register
    srli t1, t1, 3                // drop OVF/CNVR/reserved -- LSB now = 4mV
    slli t1, t1, 2                // t1 = millivolts
    mv   a0, t1

    lw   ra, 12(sp)
    addi sp, sp, 16
    ret

// Non-leaf. Reads VCC3V3 and appends to pmon_samples[pmon_idx++] (silently
// dropping the sample if the buffer is already full). Clobbers
// a0-a4,t0-t6,ra.
store_vcc3v3:
    addi sp, sp, -16
    sw   ra, 12(sp)
    li   a0, INA219_VCC3V3_ADDR
    jal  i2c_read_rail
    mv   t1, a0
    la   t3, pmon_idx
    lw   t4, 0(t3)
    li   t5, MAX_PMON_SAMPLES
    bge  t4, t5, sv3_done
    la   t5, pmon_samples
    slli t6, t4, 2
    add  t5, t5, t6
    sw   t1, 0(t5)
    addi t4, t4, 1
    sw   t4, 0(t3)
sv3_done:
    lw   ra, 12(sp)
    addi sp, sp, 16
    ret

// Non-leaf. Reads VCC1V0 (VCCINT) and appends to
// pmon_1v0_samples[pmon_1v0_idx++]. Clobbers a0-a4,t0-t6,ra.
store_vcc1v0:
    addi sp, sp, -16
    sw   ra, 12(sp)
    li   a0, INA219_VCC1V0_ADDR
    jal  i2c_read_rail
    mv   t1, a0
    la   t3, pmon_1v0_idx
    lw   t4, 0(t3)
    li   t5, MAX_PMON_SAMPLES
    bge  t4, t5, sv1_done
    la   t5, pmon_1v0_samples
    slli t6, t4, 2
    add  t5, t5, t6
    sw   t1, 0(t5)
    addi t4, t4, 1
    sw   t4, 0(t3)
sv1_done:
    lw   ra, 12(sp)
    addi sp, sp, 16
    ret

.section .data
.align 2
.globl debug_byte_idx
debug_byte_idx: .word 0xFFFFFFFF

// pmon_idx: count of valid entries in pmon_samples[] so far (also the next
// write index) -- fpga/read_pmon_result.tcl reads this first to know how
// many words of pmon_samples[]/pmon_1v0_samples[] are meaningful (both
// arrays are always kept in lockstep, one store_vcc3v3+store_vcc1v0 pair
// per sample point), then reads that many from each.
.globl pmon_idx
pmon_idx: .word 0
.globl pmon_samples
pmon_samples: .word 0
.rept MAX_PMON_SAMPLES - 1
    .word 0
.endr

.globl pmon_1v0_idx
pmon_1v0_idx: .word 0
.globl pmon_1v0_samples
pmon_1v0_samples: .word 0
.rept MAX_PMON_SAMPLES - 1
    .word 0
.endr

cmd0_bytes:  .byte 0x40, 0x00, 0x00, 0x00, 0x00, 0x95
cmd8_bytes:  .byte 0x48, 0x00, 0x00, 0x01, 0xAA, 0x87
cmd55_bytes: .byte 0x77, 0x00, 0x00, 0x00, 0x00, 0xFF
cmd41_bytes: .byte 0x69, 0x40, 0x00, 0x00, 0x00, 0xFF
cmd58_bytes: .byte 0x7A, 0x00, 0x00, 0x00, 0x00, 0xFF
cmd16_bytes: .byte 0x50, 0x00, 0x00, 0x02, 0x00, 0xFF
// Full 32-bit block address, MSB first -- see sd_init_read_write.S's copy
// of this fix for why (TEST_BLOCK_NUM used to fit in a single byte; no
// longer does now that it's testing blocks well past the low-LBA
// MBR/partition-table region).
cmd17_bytes: .byte 0x51, ((TEST_BLOCK_NUM>>24)&0xFF), ((TEST_BLOCK_NUM>>16)&0xFF), ((TEST_BLOCK_NUM>>8)&0xFF), (TEST_BLOCK_NUM&0xFF), 0xFF
cmd24_bytes: .byte 0x58, ((TEST_BLOCK_NUM>>24)&0xFF), ((TEST_BLOCK_NUM>>16)&0xFF), ((TEST_BLOCK_NUM>>8)&0xFF), (TEST_BLOCK_NUM&0xFF), 0xFF

.section .tohost
.align 3
.globl tohost
tohost:
    .word 0
    .word 0
