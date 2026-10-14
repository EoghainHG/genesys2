// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Eoghain Gray

// Generic SPI master (Mode 0: CPOL=0, CPHA=0 -- MISO/MOSI change on the
// falling edge, sampled on the rising edge), built for SD-card-in-SPI-mode
// access on the Genesys 2's native SD slot pins (sd_sclk/sd_cmd/sd_d0/
// sd_d3 as SCLK/MOSI/MISO/CS_N).
// Deliberately a CUSTOM minimal register interface, not a copy of a real
// existing chip's registers the way rtl/periph/uart.sv mimics a real
// ns16550 -- no single simple, widely-reused Linux SPI-master driver target
// exists the way ns16550/8250 does for UART, so there's nothing to gain by
// faithfully copying an existing part here. The SD CARD PROTOCOL ITSELF
// (CMD0/CMD8/ACMD41/CMD17/CMD24 framing, CRC7, retries) is deliberately
// NOT implemented in this RTL at all -- it lives entirely in software on
// top of this generic byte-at-a-time SPI transfer primitive, matching how
// Linux's own mmc_spi.c driver works on top of a generic spi_master
// controller. Keeps this RTL small and reusable for anything else that
// might need SPI later, and pushes the actually-complex protocol logic
// into software where it's far easier to iterate/debug/fix without a
// Vivado rebuild.
module spi_master #(
  parameter logic [31:0] BASE_ADDR = 32'h1000_2000
)(
  input  logic        clk,
  input  logic        rst_n,

  input  logic [31:0] addr,
  input  logic [31:0] wdata,
  input  logic [3:0]  wmask,
  input  logic        wen,
  input  logic        ren,
  output logic [31:0] rdata,

  output logic         spi_sclk,
  output logic         spi_mosi,
  input  logic         spi_miso,
  output logic         spi_cs_n
);

  // Register map (word-addressed, offsets relative to BASE_ADDR):
  //   0x0 SPI_TXRX   W: wdata[7:0] (via wmask[0]) starts an 8-bit transfer,
  //                     ignored while busy. R: last received byte.
  //   0x4 SPI_STATUS R: bit0 = busy (transfer in progress). RO.
  //   0x8 SPI_CTRL   W/R: bit0 = cs_n (software-controlled chip select --
  //                     the SD protocol needs precise CS timing around
  //                     command/response/data boundaries that a fixed
  //                     hardware-driven CS could not provide). Reset value
  //                     1 (deasserted) -- the SD spec requires CS high
  //                     during the power-on >=74 clock pulses.
  //   0xC SPI_CLKDIV W/R: [15:0] clock divider. SCLK toggles (one edge)
  //                     every (CLKDIV+1) core clocks, so SCLK period =
  //                     2*(CLKDIV+1) core clocks. Reset value chosen
  //                     conservatively slow (matches the <=400kHz the SD
  //                     spec requires during card identification) --
  //                     software must switch to a faster divider itself
  //                     once the card leaves idle state, same as any real
  //                     SD-over-SPI driver does. MUST be >= 2 (2026-09-07):
  //                     the MISO receive path now runs through a 2-FF
  //                     synchronizer (see spi_miso_sync1/2 below) that
  //                     needs a half-period of at least 3 core clocks to
  //                     resolve to the CURRENT bit rather than a stale one.
  logic [1:0] reg_sel;
  assign reg_sel = addr[3:2];

  logic [15:0] clkdiv, div_cnt;
  logic        cs_n;
  logic        busy;
  logic [3:0]  half_cnt;   // 0..15: 16 half-periods (8 rising + 8 falling) per byte
  logic [7:0]  shift_out, shift_in;
  logic        sclk_reg;

  // spi_miso synchronizer (2026-09-07, real hardware): spi_miso is a genuinely
  // asynchronous input (driven by the card, with no relationship to clk_core's
  // phase at all) -- sampling it directly into shift_in with a single register
  // is a real metastability risk, not just a timing-closure inconvenience. The
  // XDC's set_false_path on this port correctly tells the STA tool not to
  // compute setup/hold slack for an inherently asynchronous path, but that
  // constraint does nothing to protect against metastability itself -- only
  // an actual synchronizer does. Found real-hardware evidence consistent with
  // exactly this (CMD24 write investigation): a
  // reproducible single-byte glitch appearing only at the specific moment the
  // card's output stage first switches from idle/tri-stated to actively
  // driving, invariant to SPI clock rate (metastability risk is governed by
  // the SAMPLING clock, clk_core, which was never varied) and invariant to
  // data/CRC content, plus intermittent corruption of CMD0's own R1 response
  // (sampled via this exact same unsynchronized path). A free-running 2-FF
  // synchronizer feeding shift_in instead of the raw pin fixes this -- see
  // the sample-mux comment below for why CLKDIV must stay >=2 for this to
  // sample the CORRECT (not stale-by-one-bit) synchronized value.
  logic spi_miso_sync1, spi_miso_sync2;

  assign spi_sclk = sclk_reg;
  assign spi_mosi = shift_out[7];
  assign spi_cs_n = cs_n;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      clkdiv    <= 16'd100; // conservative default; see header comment
      div_cnt   <= 16'd0;
      cs_n      <= 1'b1;
      busy      <= 1'b0;
      half_cnt  <= 4'd0;
      shift_out <= 8'h00;
      shift_in  <= 8'h00;
      sclk_reg  <= 1'b0;
      spi_miso_sync1 <= 1'b0;
      spi_miso_sync2 <= 1'b0;
    end else begin
      // Free-running every cycle, independent of busy/cs_n -- a synchronizer
      // must always be sampling so its output is settled and ready whenever
      // the state machine below actually needs it, not just while a transfer
      // is in progress.
      spi_miso_sync1 <= spi_miso;
      spi_miso_sync2 <= spi_miso_sync1;

      if (wen) begin
        case (reg_sel)
          2'd0: if (wmask[0] && !busy) begin
                  shift_out <= wdata[7:0];
                  busy      <= 1'b1;
                  half_cnt  <= 4'd0;
                  div_cnt   <= 16'd0;
                end
          2'd2: if (wmask[0]) cs_n <= wdata[0];
          2'd3: begin
                  if (wmask[0]) clkdiv[7:0]  <= wdata[7:0];
                  if (wmask[1]) clkdiv[15:8] <= wdata[15:8];
                end
          default: ;
        endcase
      end

      if (busy) begin
        if (div_cnt == clkdiv) begin
          div_cnt <= 16'd0;
          if (half_cnt[0] == 1'b0) begin
            // Even half_cnt: rising edge -- sample MISO (the value it held
            // throughout the just-finished low phase), matching Mode 0.
            // Uses the SYNCHRONIZED value (spi_miso_sync2), not the raw pin
            // -- see this module's spi_miso_sync1/2 declaration for why.
            // Correctness depends on CLKDIV >= 2 (half-period >= 3 core
            // cycles): the slave updates MISO at the START of each low
            // half-period, so the synchronizer's 2-cycle delay must still
            // resolve to THIS half-period's value by the time it's sampled
            // here, not leak in a stale sample from the half-period before
            // it. At CLKDIV=1 (2-cycle half-periods) the delayed sample
            // would be exactly one half-period stale -- do not lower
            // SPI_CLKDIV_DATA/SPI_CLKDIV_INIT below 2 without redoing this
            // analysis.
            sclk_reg <= 1'b1;
            shift_in <= {shift_in[6:0], spi_miso_sync2};
          end else begin
            // Odd half_cnt: falling edge -- present the next output bit.
            sclk_reg  <= 1'b0;
            shift_out <= {shift_out[6:0], 1'b0};
          end
          if (half_cnt == 4'd15) begin
            busy     <= 1'b0;
            half_cnt <= 4'd0;
`ifdef SPI_MASTER_DEBUG
            $display("[spi_master] xfer done, shift_in=0x%02x", shift_in);
`endif
          end else begin
            half_cnt <= half_cnt + 4'd1;
          end
        end else begin
          div_cnt <= div_cnt + 16'd1;
        end
      end
    end
  end

  always_comb begin
    rdata = 32'h0;
    if (ren) begin
      case (reg_sel)
        2'd0: rdata = {24'h0, shift_in};
        2'd1: rdata = {31'h0, busy};
        2'd2: rdata = {31'h0, cs_n};
        2'd3: rdata = {16'h0, clkdiv};
        default: rdata = 32'h0;
      endcase
    end
  end

endmodule
