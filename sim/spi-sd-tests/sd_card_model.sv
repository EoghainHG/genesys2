// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Eoghain Gray

// Behavioral SPI-mode SD card model, simulation only (never synthesized).
// Reacts bit-accurately to the real spi_sclk/spi_mosi/spi_cs_n signals
// (does NOT peek at spi_master.sv's internal registers) so a real
// timing/protocol bug in the RTL would actually be caught here, not just a
// software-logic bug in the driver exercising it -- same "test at the real
// signal boundary" philosophy as sim/uart-phy-tests' external loopback.
//
// Models an SDHC-style (block-addressed, CCS=1) card in SPI mode: CMD0
// (GO_IDLE_STATE), CMD8 (SEND_IF_COND, echoes the check pattern), CMD55+
// ACMD41 (SD_SEND_OP_COND -- leaves idle after a few polls, not
// immediately, to exercise a real driver's retry loop), CMD58 (READ_OCR,
// CCS=1), CMD17 (READ_SINGLE_BLOCK), CMD24 (WRITE_BLOCK). Everything else
// responds with the R1 "illegal command" bit set.
//
// Deliberately does NOT check CRC7 on CMD0/CMD8 (real cards require a
// correct CRC7 for exactly these two commands, all others are unchecked by
// default in SPI mode) -- sw/sd-test's driver sends the well-known correct
// fixed CRC7 bytes for these two commands' fixed arguments (CMD0/arg=0 =>
// 0x95, CMD8/arg=0x1AA => 0x87) since only these two exact (command,
// argument) pairs are ever used, so there's no runtime CRC7 computation to
// get right in either direction -- but this means a transcription error in
// those hardcoded bytes would NOT be caught here, only later on real
// hardware (a real card does check them). Documented gap, not an oversight.
//
// Single 512-byte backing block (not one array per block number) --
// sw/sd-test's own test only ever addresses one block, so this is enough
// to prove a real write-then-read-back round trip without the complexity
// of a full multi-block backing store.
module sd_card_model (
  input  logic spi_sclk,
  input  logic spi_mosi,
  output logic spi_miso,
  input  logic spi_cs_n
);

  logic [7:0] block_mem [0:511];

  integer bi;
  initial begin
    spi_miso = 1'b1; // idle high, matches an undriven/pulled-up DO line
    for (bi = 0; bi < 512; bi = bi + 1) block_mem[bi] = bi[7:0];
  end

  // Full-duplex single-byte transfer: drives `tx` onto MISO while
  // simultaneously capturing MOSI into `rx`, MSB first, Mode 0 (sample on
  // rising edge, change on falling edge -- first bit set up immediately
  // since it must be valid before the first rising edge of this byte).
  task automatic transfer_byte(input logic [7:0] tx, output logic [7:0] rx);
    integer i;
    logic [7:0] r;
    begin
      r = 8'h00;
      for (i = 7; i >= 0; i = i - 1) begin
        spi_miso = tx[i];
        @(posedge spi_sclk);
        r = {r[6:0], spi_mosi};
        @(negedge spi_sclk);
      end
      rx = r;
    end
  endtask

  task automatic send_byte(input logic [7:0] tx);
    logic [7:0] discard;
    begin
      transfer_byte(tx, discard);
    end
  endtask

  logic [5:0]  cmd_index;
  logic [31:0] cmd_arg;
  logic [7:0]  cmd_byte;
  logic [7:0]  rx;
  integer      i;
  integer      acmd41_polls;
  logic        next_is_acmd;
  logic        card_ready;

  initial begin
    acmd41_polls = 0;
    next_is_acmd = 1'b0;
    card_ready   = 1'b0;

    forever begin
      wait (spi_cs_n == 1'b0);
      transfer_byte(8'hFF, cmd_byte);
      if (cmd_byte[7:6] == 2'b01) begin
        cmd_index = cmd_byte[5:0];
        transfer_byte(8'hFF, rx); cmd_arg[31:24] = rx;
        transfer_byte(8'hFF, rx); cmd_arg[23:16] = rx;
        transfer_byte(8'hFF, rx); cmd_arg[15:8]  = rx;
        transfer_byte(8'hFF, rx); cmd_arg[7:0]   = rx;
        transfer_byte(8'hFF, rx); // CRC7+stop byte, not checked (see header)

        case (cmd_index)
          6'd0: begin // GO_IDLE_STATE
            send_byte(8'h01);
            card_ready   = 1'b0;
            acmd41_polls = 0;
            next_is_acmd = 1'b0;
          end

          6'd8: begin // SEND_IF_COND -- echo voltage+check-pattern bytes
            send_byte(8'h01);
            send_byte(cmd_arg[31:24]);
            send_byte(cmd_arg[23:16]);
            send_byte(cmd_arg[15:8]);
            send_byte(cmd_arg[7:0]);
            next_is_acmd = 1'b0;
          end

          6'd55: begin // APP_CMD -- next command is an ACMD
            send_byte(card_ready ? 8'h00 : 8'h01);
            next_is_acmd = 1'b1;
          end

          6'd41: begin // ACMD41 (SD_SEND_OP_COND) if preceded by CMD55
            if (next_is_acmd) begin
              if (!card_ready) begin
                acmd41_polls = acmd41_polls + 1;
                // Leaves idle after a few polls, not instantly -- exercises
                // a real driver's retry loop instead of trivially passing
                // on the first attempt.
                if (acmd41_polls >= 3) card_ready = 1'b1;
              end
              send_byte(card_ready ? 8'h00 : 8'h01);
            end else begin
              send_byte(8'h05); // illegal command outside ACMD context
            end
            next_is_acmd = 1'b0;
          end

          6'd58: begin // READ_OCR -- CCS=1 (SDHC/block-addressed)
            send_byte(card_ready ? 8'h00 : 8'h01);
            send_byte(8'hC0); // bit31=power-up done, bit30=CCS
            send_byte(8'hFF);
            send_byte(8'h80);
            send_byte(8'h00);
            next_is_acmd = 1'b0;
          end

          6'd16: begin // SET_BLOCKLEN -- accept any request for 512 (the only
                       // length this model, or a real SDHC/SDXC card, uses)
            send_byte(card_ready ? 8'h00 : 8'h01);
            next_is_acmd = 1'b0;
          end

          6'd17: begin // READ_SINGLE_BLOCK
            send_byte(card_ready ? 8'h00 : 8'h01);
            if (card_ready) begin
              send_byte(8'hFE); // data start token
              for (i = 0; i < 512; i = i + 1) send_byte(block_mem[i]);
              send_byte(8'h00); // CRC16 hi (unchecked, SPI-mode default)
              send_byte(8'h00); // CRC16 lo
            end
            next_is_acmd = 1'b0;
          end

          6'd24: begin // WRITE_BLOCK
            send_byte(card_ready ? 8'h00 : 8'h01);
            if (card_ready) begin
              do begin
                transfer_byte(8'hFF, rx);
              end while (rx != 8'hFE); // wait for the host's start token
              for (i = 0; i < 512; i = i + 1) begin
                transfer_byte(8'hFF, rx);
                block_mem[i] = rx;
              end
              transfer_byte(8'hFF, rx); // CRC16 hi (ignored)
              transfer_byte(8'hFF, rx); // CRC16 lo (ignored)
              send_byte(8'h05);          // data response: accepted
              // Brief busy period (MISO low), matching real flash-program
              // latency the driver must poll through, not assume instant.
              spi_miso = 1'b0;
              repeat (8) @(posedge spi_sclk);
              spi_miso = 1'b1;
            end
            next_is_acmd = 1'b0;
          end

          default: begin
            send_byte(8'h05); // illegal command
            next_is_acmd = 1'b0;
          end
        endcase
      end
    end
  end

endmodule
