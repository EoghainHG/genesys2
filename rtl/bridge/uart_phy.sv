// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Eoghain Gray

// Real UART PHY (baud-rate generator + TX serializer + RX deserializer) --
// bridges rtl/periph/uart.sv's byte-level 16550 register model to a real
// physical async serial pin pair. Genesys 2 has no hard UART IP, so this
// project provides its own PHY rather than relying on board hard IP.
// Sim-verified in sim/uart-phy-tests/ (loopback: TX drives a byte, the
// same waveform is fed back into RX, confirm the byte round-trips) before
// ever touching real hardware. Wired into fpga/genesys2_top_uart.sv,
// fpga/genesys2_top_ddr.sv, and fpga/genesys2_top_sd.sv;
// fpga/genesys2_top_min.sv deliberately leaves uart.sv's phy ports tied
// off since it predates this module.
//
// RX requires a clock-domain-crossing synchronizer on the genuinely
// asynchronous external RX pin -- a 2-flop synchronizer on uart_rx_pin
// below.
//
// TX: simple 4-state shift-out (IDLE/START/DATA/STOP) at one bit per
// CLKS_PER_BIT clocks, LSB-first, 1 start + 8 data + 1 stop, no parity --
// matches uart.sv's own 16550 subset (8N1). Idle-high.
//
// RX: 16x-oversampled deserializer. Detects a falling edge in IDLE, waits
// half a bit period to confirm a real start bit (not a glitch) at its
// center, then samples each subsequent bit at its center (every OSR ticks).
// After 8 data bits + a stop-bit slot, queues the received byte into a real
// 16-entry FIFO (2026-09-12, matching the DTS's `fifosize=16` and the new
// TX FIFO in rtl/periph/uart.sv), drained one byte at a time into uart.sv's
// single-byte RBR/DR holding register via rx_inject_valid/rx_inject_data the
// moment uart.sv's `dr_status` (RBR-occupied flag) goes low -- honoring the
// same backpressure contract uart.sv's own header documents ("without this,
// injecting faster than the guest reads silently overwrites rbr, dropping
// characters"), just with 16 bytes of headroom now instead of 1. A byte
// arriving while the FIFO is already full (16 unread bytes backed up) is
// still dropped -- real hardware RX-FIFO overrun, not modeled as an OE flag,
// same minimalism as the rest of this file/uart.sv.
module uart_phy #(
  parameter int CLK_FREQ_HZ = 20_000_000,
  parameter int BAUD_RATE   = 115_200
)(
  input  logic       clk,
  input  logic       rst_n,

  // uart.sv side
  input  logic       tx_valid,
  input  logic [7:0] tx_data,
  output logic       tx_busy,
  output logic       rx_inject_valid,
  output logic [7:0] rx_inject_data,
  input  logic       dr_status,

  // physical pins
  output logic       uart_tx_pin,
  input  logic       uart_rx_pin
);

  localparam int CLKS_PER_BIT = CLK_FREQ_HZ / BAUD_RATE;
  localparam int OSR          = 16;
  localparam int CLKS_PER_OSR = CLKS_PER_BIT / OSR;

  // ===========================================================================
  // TX
  // ===========================================================================
  typedef enum logic [1:0] {TX_IDLE, TX_START, TX_DATA, TX_STOP} tx_state_t;
  tx_state_t tx_state;

  logic [$clog2(CLKS_PER_BIT+1)-1:0] tx_bit_cnt;
  logic [2:0] tx_bit_idx;
  logic [7:0] tx_shift;

  assign tx_busy = (tx_state != TX_IDLE);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      tx_state    <= TX_IDLE;
      uart_tx_pin <= 1'b1;
      tx_bit_cnt  <= '0;
      tx_bit_idx  <= '0;
      tx_shift    <= '0;
    end else begin
      case (tx_state)
        TX_IDLE: begin
          uart_tx_pin <= 1'b1;
          if (tx_valid) begin
            tx_shift   <= tx_data;
            tx_bit_cnt <= '0;
            tx_state   <= TX_START;
          end
        end
        TX_START: begin
          uart_tx_pin <= 1'b0;
          if (tx_bit_cnt == CLKS_PER_BIT-1) begin
            tx_bit_cnt <= '0;
            tx_bit_idx <= '0;
            tx_state   <= TX_DATA;
          end else tx_bit_cnt <= tx_bit_cnt + 1'b1;
        end
        TX_DATA: begin
          uart_tx_pin <= tx_shift[0];
          if (tx_bit_cnt == CLKS_PER_BIT-1) begin
            tx_bit_cnt <= '0;
            tx_shift   <= {1'b0, tx_shift[7:1]};
            if (tx_bit_idx == 3'd7) tx_state <= TX_STOP;
            else                    tx_bit_idx <= tx_bit_idx + 1'b1;
          end else tx_bit_cnt <= tx_bit_cnt + 1'b1;
        end
        TX_STOP: begin
          uart_tx_pin <= 1'b1;
          if (tx_bit_cnt == CLKS_PER_BIT-1) begin
            tx_bit_cnt <= '0;
            tx_state   <= TX_IDLE;
          end else tx_bit_cnt <= tx_bit_cnt + 1'b1;
        end
        default: tx_state <= TX_IDLE;
      endcase
    end
  end

  // ===========================================================================
  // RX
  // ===========================================================================
  logic [1:0] rx_sync;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) rx_sync <= 2'b11;
    else        rx_sync <= {rx_sync[0], uart_rx_pin};
  end
  logic rx_line;
  assign rx_line = rx_sync[1];

  typedef enum logic [1:0] {RX_IDLE, RX_START, RX_DATA, RX_HOLD} rx_state_t;
  rx_state_t rx_state;

  logic [$clog2(CLKS_PER_OSR+1)-1:0] osr_clk_cnt;
  logic [$clog2(OSR+1)-1:0]          osr_tick_cnt;
  logic [3:0]                        rx_bit_idx;   // 0..7 data, 8 = stop slot
  logic [7:0]                        rx_shift;

  // RX FIFO (2026-09-12): replaces the old single-slot rx_held/rx_held_valid
  // register -- see this file's header comment. 16 deep, fixed-width
  // literals throughout (not $clog2-derived) per this project's own
  // clock-divider lesson.
  logic [7:0] rx_fifo [0:15];
  logic [3:0] rx_fifo_head, rx_fifo_tail;
  logic [4:0] rx_fifo_count;
  logic       rx_byte_complete, rx_fifo_push, rx_fifo_pop;

  logic osr_tick;
  assign osr_tick = (osr_clk_cnt == CLKS_PER_OSR-1);

  // Mirrors the RX_DATA "stop-bit slot reached" condition below exactly --
  // kept as its own signal so the FIFO push/pop bookkeeping can live in one
  // place instead of being split across the state machine.
  assign rx_byte_complete = (rx_state == RX_DATA) && (osr_clk_cnt == CLKS_PER_OSR-1) &&
                             (osr_tick_cnt == OSR-1) && (rx_bit_idx == 4'd8);
  assign rx_fifo_push = rx_byte_complete && (rx_fifo_count != 5'd16);
  // `!rx_inject_valid` (2026-09-12, same class of bug as uart.sv's
  // tx_fifo_pop, found by sim/uart-fifo-tests): dr_status is a registered
  // output of a DIFFERENT module (uart.sv), one full cycle behind a
  // rx_inject_valid pulse. Without this term, every queued byte past the
  // first got popped in that one-cycle window (dr_status still stale-0,
  // fifo still non-empty), overwriting rx_inject_data before uart.sv ever
  // latched the previous byte into rbr -- silently skipping bytes under a
  // real multi-byte backlog (a single queued byte was always safe, same
  // reasoning as the TX side).
  assign rx_fifo_pop  = (rx_fifo_count != 5'd0) && !dr_status && !rx_inject_valid;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rx_state        <= RX_IDLE;
      osr_clk_cnt      <= '0;
      osr_tick_cnt     <= '0;
      rx_bit_idx       <= '0;
      rx_shift         <= '0;
      rx_fifo_head     <= 4'h0;
      rx_fifo_tail     <= 4'h0;
      rx_fifo_count    <= 5'h0;
      rx_inject_valid  <= 1'b0;
      rx_inject_data   <= '0;
    end else begin
      rx_inject_valid <= 1'b0; // default: one-cycle pulse only

      // Drain: hand the oldest queued byte to uart.sv the moment RBR frees.
      if (rx_fifo_pop) begin
        rx_inject_valid <= 1'b1;
        rx_inject_data  <= rx_fifo[rx_fifo_head];
        rx_fifo_head    <= rx_fifo_head + 4'd1;
      end

      // Fill: a byte just finished arriving from the wire.
      if (rx_fifo_push) begin
        rx_fifo[rx_fifo_tail] <= rx_shift;
        rx_fifo_tail          <= rx_fifo_tail + 4'd1;
      end

      case ({rx_fifo_push, rx_fifo_pop})
        2'b10:   rx_fifo_count <= rx_fifo_count + 5'd1;
        2'b01:   rx_fifo_count <= rx_fifo_count - 5'd1;
        default: rx_fifo_count <= rx_fifo_count; // 00 or 11 (same-cycle push+pop): unchanged
      endcase

      case (rx_state)
        RX_IDLE: begin
          osr_clk_cnt  <= '0;
          osr_tick_cnt <= '0;
          if (rx_line == 1'b0) rx_state <= RX_START; // falling edge -> possible start bit
        end

        RX_START: begin
          if (osr_clk_cnt == CLKS_PER_OSR-1) begin
            osr_clk_cnt <= '0;
            if (osr_tick_cnt == OSR/2-1) begin
              // mid-bit of the start bit: confirm it's real, not a glitch
              if (rx_line == 1'b0) begin
                osr_tick_cnt <= '0;
                rx_bit_idx   <= '0;
                rx_state     <= RX_DATA;
              end else begin
                rx_state <= RX_IDLE; // glitch, not a real start bit
              end
            end else begin
              osr_tick_cnt <= osr_tick_cnt + 1'b1;
            end
          end else begin
            osr_clk_cnt <= osr_clk_cnt + 1'b1;
          end
        end

        RX_DATA: begin
          if (osr_clk_cnt == CLKS_PER_OSR-1) begin
            osr_clk_cnt <= '0;
            if (osr_tick_cnt == OSR-1) begin
              // one full bit period since the last sample -> sample now
              osr_tick_cnt <= '0;
              if (rx_bit_idx == 4'd8) begin
                // this was the stop-bit slot (not strictly checked) -- done;
                // rx_fifo_push (above) already queued rx_shift if there was
                // room in the FIFO.
                rx_state <= RX_IDLE;
              end else begin
                rx_shift   <= {rx_line, rx_shift[7:1]}; // LSB first
                rx_bit_idx <= rx_bit_idx + 1'b1;
              end
            end else begin
              osr_tick_cnt <= osr_tick_cnt + 1'b1;
            end
          end else begin
            osr_clk_cnt <= osr_clk_cnt + 1'b1;
          end
        end

        default: rx_state <= RX_IDLE;
      endcase
    end
  end

endmodule
