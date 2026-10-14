// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Eoghain Gray

// Minimal I2C bit-bang GPIO peripheral (2026-09-07) -- built to read the
// Genesys 2's onboard INA219 power-monitor chips (VCC3V3 rail specifically)
// during a CMD24 SD write attempt, as a real-data alternative to an external
// oscilloscope for testing the power-sag theory behind the SD-over-SPI
// write investigation. Same philosophy as spi_master.sv: this
// RTL is a bare open-drain register interface, nothing I2C-protocol-aware at
// all (no START/STOP/ACK state machine) -- the actual I2C bit-banging
// (start/stop conditions, byte shifting, ACK/NACK checking) lives entirely
// in software, same "push complexity into software, iterate without a
// Vivado rebuild" reasoning already used for the SD driver.
//
// scl/sda are true bidirectional (inout) ports, matching real open-drain I2C
// electrical behavior -- board-level pull-ups (present on any bus with
// permanently-attached slave chips like this one) pull the line high
// whenever nothing is actively driving it low.
module i2c_gpio #(
  parameter logic [31:0] BASE_ADDR = 32'h1000_3000
)(
  input  logic clk,
  input  logic rst_n,

  input  logic [31:0] addr,
  input  logic [31:0] wdata,
  input  logic [3:0]  wmask,
  input  logic        wen,
  input  logic        ren,
  output logic [31:0] rdata,

  inout  wire scl,
  inout  wire sda
);

  // Register map (single word, offset 0 relative to BASE_ADDR -- addr isn't
  // even decoded beyond BASE/SIZE at the mmio_decoder level, so any offset
  // within the window hits this same register):
  //   W: bit0 = scl_out, bit1 = sda_out. Open-drain convention -- '1' means
  //      "release" (line floats high via the board's pull-up), '0' means
  //      "actively drive low". Reset value 2'b11 (both released) so the bus
  //      idles high, matching an idle I2C bus, the instant this comes out
  //      of reset.
  //   R: bit0 = live SCL line state, bit1 = live SDA line state -- software
  //      reads these to sample ACK/NACK bits and data bits driven back by
  //      the slave, and (defensively, though INA219 doesn't clock-stretch)
  //      to check for clock stretching.
  logic scl_out, sda_out;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      scl_out <= 1'b1;
      sda_out <= 1'b1;
    end else if (wen && wmask[0]) begin
      scl_out <= wdata[0];
      sda_out <= wdata[1];
    end
  end

  assign scl = scl_out ? 1'bz : 1'b0;
  assign sda = sda_out ? 1'bz : 1'b0;

  always_comb begin
    rdata = 32'h0;
    if (ren) rdata = {30'h0, sda, scl};
  end

endmodule
