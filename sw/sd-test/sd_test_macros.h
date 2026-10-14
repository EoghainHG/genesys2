// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Eoghain Gray

// Shared constants for sd_init_read_write.S -- SD-card-over-SPI storage
// effort (2026-09-06). Register offsets match rtl/periph/spi_master.sv's
// own register map exactly (see that file's header comment).

#define SPI_BASE   0x10002000
#define SPI_TXRX   (SPI_BASE + 0x0)  // W: start an 8-bit transfer. R: last received byte.
#define SPI_STATUS (SPI_BASE + 0x4)  // R: bit0 = busy.
#define SPI_CTRL   (SPI_BASE + 0x8)  // W/R: bit0 = cs_n (1=deasserted).
#define SPI_CLKDIV (SPI_BASE + 0xC)  // W/R: SCLK toggles every (CLKDIV+1) core clocks.

// I2C_REG (2026-09-07): rtl/periph/i2c_gpio.sv's single register. W: bit0 =
// scl_out, bit1 = sda_out (open-drain convention -- 1 = release/high via
// board pull-up, 0 = actively drive low). R: bit0 = live SCL state, bit1 =
// live SDA state. Used to bit-bang I2C in software against the Genesys 2's
// onboard INA219 power-monitor chips (six chips, one per main rail, shared
// bus, different slave addresses -- see the Genesys 2 Reference Manual's
// "Power Monitoring" section). VCC3V3 is the rail of interest here: it also
// feeds the LVCMOS33 I/O banks the SD pins belong to, so a sag there is a
// direct, real-data test of the write-failure power-margin theory
// without needing an oscilloscope.
#define I2C_BASE 0x10003000
#define I2C_REG  (I2C_BASE + 0x0)
#define I2C_SCL_BIT 0x1
#define I2C_SDA_BIT 0x2
#define I2C_IDLE (I2C_SCL_BIT | I2C_SDA_BIT)   // both released -- bus idle high

// INA219 7-bit slave addresses, from the Reference Manual's Table 3.
// Shifted left 1 + R/W bit gives the actual first byte on the wire (e.g.
// VCC3V3: 0x88 for write, 0x89 for read).
#define INA219_VCC3V3_ADDR 0x44
// VCC1V0 (2026-09-08): VCCINT, the FPGA's OWN core rail -- added to test
// a different theory than "SD slot supply sags under write current":
// internal switching activity during the tight write_loop could sag
// VCCINT itself, which has a much tighter tolerance than 3.3V and would
// explain both CMD24 and the CMD0 regressions as an FPGA-internal
// reliability issue rather than anything SD-card-side.
#define INA219_VCC1V0_ADDR 0x45
#define INA219_REG_BUSVOLTAGE 0x02

// Small dividers -- this test runs against sim/spi-sd-tests/sd_card_model.sv,
// which reacts to real edges regardless of their absolute rate, so there's
// no reason to simulate real SPI timing scale (same "same ratio, different
// absolute scale" philosophy as sim/uart-phy-tests' tiny CLK_FREQ_HZ). On
// REAL hardware this needs real values: at clk_core's real ~56.26MHz,
// CLKDIV=70 gives SCLK~=396kHz (under the SD spec's <=400kHz
// card-identification-phase limit) and CLKDIV=1 gives SCLK~=14MHz for the
// post-init data phase -- recompute both if clk_core's frequency ever
// changes again.
#define SPI_CLKDIV_INIT 70
// SPI_CLKDIV_DATA: raised 1->3 (2026-09-07, real root cause found). The
// clock-rate-invariant glitch (0xE0/0x9F right after CRC, bit-for-bit
// identical at ~14MHz and ~3.5MHz) turned out to point at spi_miso having
// no synchronizer in spi_master.sv -- a real metastability risk, not card
// behavior (see that file's spi_miso_sync1/2 for the full
// reasoning: clock-rate invariance makes sense once you realize
// metastability risk depends on the SAMPLING clock, clk_core, which was
// never varied by changing this divider). The new synchronizer needs
// CLKDIV >= 2 (half-period >= 3 core cycles) to sample the correct,
// current bit instead of a stale one -- 3 gives a full cycle of margin
// beyond that minimum. ~7.03MHz at clk_core's real ~56.26MHz.
#define SPI_CLKDIV_DATA 3

#define CS_ASSERTED   0
#define CS_DEASSERTED 1

#define MAX_CMD0_TRIES 10
// MAX_ACMD41_TRIES (2026-09-06, first real-hardware attempt): the original
// value of 64 was tuned against sim/spi-sd-tests/sd_card_model.sv, which
// deliberately leaves idle after exactly 3 polls -- fast by design, not
// representative of real timing. At the real ~396kHz init-phase SCLK, each
// ACMD41 (CMD55+ACMD41, each poll_response'd) try costs roughly 280-900us,
// so 64 tries only spans ~20-60ms of real elapsed time. The SD spec allows
// a card up to ~1 second to complete its internal initialization after
// ACMD41 first starts it -- real hardware showed 64 tries genuinely isn't
// enough (never left idle after all 64), consistent with this being a
// retry-count-vs-real-time mismatch, not a protocol/wiring problem (CMD0
// and CMD8 both already succeeded by this point). 10000 gives roughly
// 3-9 seconds of real polling headroom, comfortably past the spec's ~1s
// budget, while still finite (a genuinely dead card/link won't hang
// forever).
#define MAX_ACMD41_TRIES 10000
#define MAX_RESPONSE_POLLS 16
// MAX_DATATOKEN_POLLS (2026-09-06, first real-hardware attempt): same
// retry-count-vs-real-time mismatch as MAX_ACMD41_TRIES above -- 16 polls
// at the ~14MHz data-phase SCLK is only ~9us of real timeout, nowhere near
// a real card's actual read/write access latency. Real hardware confirmed
// this: CMD0/CMD8/ACMD41/CMD58 all succeeded (card fully initialized,
// confirmed SDHC) but the 0xFE start-of-data token was never seen within
// 16 polls after CMD17. 50000 gives ~28.6ms of real polling headroom at
// 14MHz, comfortably past typical real access-time figures.
#define MAX_DATATOKEN_POLLS 50000
// MAX_DATARESP_POLLS: the write-side counterpart of MAX_DATATOKEN_POLLS --
// polls for the card to actually drive the post-write data-response token
// instead of reading it once. Same real-hardware justification.
#define MAX_DATARESP_POLLS 50000
// MAX_BUSY_POLLS (2026-09-06): bounds the post-write busy-wait loop, which
// previously had NO limit at all (a genuinely wedged card would hang the
// CPU forever, indistinguishable from any other hang). A real card's
// single-block write busy time is typically a few ms, occasionally up to
// ~250ms on a slow card. Each poll is one byte (~0.57us at the ~14MHz
// data-phase SCLK), so 200000 polls is ~114ms of real headroom -- generous
// but still finite.
#define MAX_BUSY_POLLS 200000
// MAX_WRITE_RETRIES (2026-09-07): retries the whole CMD24 attempt (fresh
// command, fresh R1, fresh data+CRC) this many times before giving up.
// Raised 3->10 after real hardware showed genuine run-to-run variability
// even with a reseated card: one run PASSED on retry, another couldn't
// even get CMD24's own R1 response across all 3 attempts -- consistent
// with a marginal power-delivery margin specifically under write current
// draw (flash program/erase draws much more instantaneous current than a
// read), separate from the general sd_reset power-sequencing issue already
// fixed for the read path. More retries costs little (each attempt is a
// small fraction of a second) and directly tests whether the card recovers
// given enough tries.
#define MAX_WRITE_RETRIES 10

// TEST_BLOCK_NUM: raised from 5 to 200000 (2026-09-08). Block 5 sits well
// within the MBR/partition-table/filesystem-reserved region a
// factory-formatted card typically has at its very start -- some real card
// controllers are known to treat that low-LBA region specially (caching,
// wear-leveling, even soft write protection) regardless of what's actually
// stored there. Never tested until now (every other write-path theory --
// CRC, Nwr, clock rate, CMD16, busy-drain, power sag, spi_miso
// synchronization -- was tried first). 200000 is safely into the user-data
// area of even the smallest real SDHC card (2GB = ~4.19M blocks) and far
// past any plausible reserved region.
#define TEST_BLOCK_NUM 200000

// GPIO_ADDR: same address/led_reg convention as sw/ddr-test, sw/ddr-verify,
// sw/uart-test (see fpga/genesys2_top_sd.sv's GPIO_ADDR parameter, default
// 0xFFFF_FFF0). Unused by this test's normal pass/fail path -- added
// 2026-09-07 solely as a debug marker for fpga/capture_cmd24_ila.tcl's ILA
// trigger (GENESYS2_ILA_DEBUG builds only; the write itself is harmless on
// a plain build too, just an inert LED toggle).
#define GPIO_ADDR 0xFFFFFFF0
