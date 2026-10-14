// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Eoghain Gray

// Directed loopback test for rtl/bridge/uart_phy.sv: uart_tx_pin is wired
// directly to uart_rx_pin (external loopback, no CPU/uart.sv involved --
// same "test at the right protocol boundary" philosophy as
// sim/ps-uart0-bridge-tests). Sends 4 bytes through TX and checks each one
// round-trips correctly via rx_inject_valid/rx_inject_data, including a
// dedicated check that dr_status backpressure is honored (a byte is held,
// not delivered, while dr_status is asserted, and released the moment it
// clears).
//
// CLK_FREQ_HZ/BAUD_RATE are deliberately tiny (not real UART numbers) --
// same RTL, same state-machine timing relationships, just scaled down for
// fast simulation. The real board-rate parameters (20 MHz/115200) are
// exercised for the first time on real hardware, not in this testbench --
// acceptable since only the *ratio* (CLKS_PER_BIT, and OSR=16 always)
// matters to the logic being checked here.
module tb_uart_phy (
  input  logic clk,
  input  logic rst_n,
  output logic test_done,
  output logic test_pass,
  output logic [4:0] dbg_state,
  output logic dbg_tx_busy,
  output logic dbg_rx_inject_valid,
  output logic [7:0] dbg_rx_bit_idx
);

  localparam int CLK_FREQ_HZ = 3200;
  localparam int BAUD_RATE   = 100;   // CLKS_PER_BIT = 32

  logic       tx_valid;
  logic [7:0] tx_data;
  logic       tx_busy;
  logic       rx_inject_valid;
  logic [7:0] rx_inject_data;
  logic       dr_status;
  logic       loop_wire;

  uart_phy #(.CLK_FREQ_HZ(CLK_FREQ_HZ), .BAUD_RATE(BAUD_RATE)) u_dut (
    .clk             (clk),
    .rst_n           (rst_n),
    .tx_valid        (tx_valid),
    .tx_data         (tx_data),
    .tx_busy         (tx_busy),
    .rx_inject_valid (rx_inject_valid),
    .rx_inject_data  (rx_inject_data),
    .dr_status       (dr_status),
    .uart_tx_pin     (loop_wire),
    .uart_rx_pin     (loop_wire)
  );

  assign dbg_tx_busy          = tx_busy;
  assign dbg_rx_inject_valid  = rx_inject_valid;
  assign dbg_rx_bit_idx       = {4'b0, u_dut.rx_bit_idx};

  logic [7:0] test_bytes [0:3];
  assign test_bytes[0] = 8'h00;
  assign test_bytes[1] = 8'hFF;
  assign test_bytes[2] = 8'hA5;
  assign test_bytes[3] = 8'h48;

  typedef enum logic [4:0] {
    ST_RESET_WAIT,
    ST_SEND0, ST_WAIT_BUSY0, ST_WAIT_RX0, ST_CHECK0,
    ST_SEND1, ST_WAIT_BUSY1, ST_WAIT_RX1, ST_CHECK1,
    // byte 2 exercises dr_status backpressure: hold dr_status high through
    // RX completion, confirm no delivery, then release and confirm delivery.
    ST_SEND2, ST_WAIT_BUSY2, ST_HOLD_BUSY2, ST_HOLD_SETTLE2, ST_RELEASE2, ST_WAIT_RX2, ST_CHECK2,
    ST_SEND3, ST_WAIT_BUSY3, ST_WAIT_RX3, ST_CHECK3,
    ST_PASS, ST_FAIL
  } state_t;

  state_t     state;
  logic [15:0] hold_cnt;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state      <= ST_RESET_WAIT;
      tx_valid   <= 1'b0;
      tx_data    <= 8'h0;
      dr_status  <= 1'b0;
      test_done  <= 1'b0;
      test_pass  <= 1'b0;
      hold_cnt   <= '0;
    end else begin
      tx_valid <= 1'b0; // default: one-cycle pulse only

      case (state)
        ST_RESET_WAIT: state <= ST_SEND0;

        // ---- byte 0 ----
        ST_SEND0: begin tx_valid <= 1'b1; tx_data <= test_bytes[0]; state <= ST_WAIT_BUSY0; end
        ST_WAIT_BUSY0: if (tx_busy) state <= ST_WAIT_RX0;
        ST_WAIT_RX0:   if (rx_inject_valid) state <= ST_CHECK0;
        ST_CHECK0: begin
          if (rx_inject_data === test_bytes[0]) state <= ST_SEND1;
          else state <= ST_FAIL;
        end

        // ---- byte 1 ----
        // Gate on !tx_busy: RX finishing (mid-stop-bit) races ahead of TX's
        // own return to idle (end-of-stop-bit) for the SAME byte. Pulsing
        // tx_valid before the DUT is really back in TX_IDLE gets silently
        // dropped (TX_IDLE is the only state that looks at tx_valid), and
        // without this guard the testbench would falsely see the PREVIOUS
        // byte's still-lingering tx_busy=1 and wrongly advance as if the
        // new byte had been sent -- found the hard way (this exact bug
        // caused a real TIMEOUT the first time this test ran).
        ST_SEND1: if (!tx_busy) begin tx_valid <= 1'b1; tx_data <= test_bytes[1]; state <= ST_WAIT_BUSY1; end
        ST_WAIT_BUSY1: if (tx_busy) state <= ST_WAIT_RX1;
        ST_WAIT_RX1:   if (rx_inject_valid) state <= ST_CHECK1;
        ST_CHECK1: begin
          if (rx_inject_data === test_bytes[1]) state <= ST_SEND2;
          else state <= ST_FAIL;
        end

        // ---- byte 2: dr_status backpressure ----
        ST_SEND2: if (!tx_busy) begin
          dr_status <= 1'b1; // RBR "occupied" before this byte even arrives
          tx_valid  <= 1'b1;
          tx_data   <= test_bytes[2];
          state     <= ST_WAIT_BUSY2;
        end
        ST_WAIT_BUSY2: if (tx_busy) state <= ST_HOLD_BUSY2;
        // Give the DUT well past a full byte time to (wrongly) deliver
        // while dr_status is still asserted -- must NOT see rx_inject_valid.
        ST_HOLD_BUSY2: begin
          if (rx_inject_valid) state <= ST_FAIL; // delivered despite dr_status=1: bug
          else if (hold_cnt == 16'd500) begin
            hold_cnt <= '0;
            state    <= ST_HOLD_SETTLE2;
          end else hold_cnt <= hold_cnt + 1'b1;
        end
        ST_HOLD_SETTLE2: state <= ST_RELEASE2;
        ST_RELEASE2: begin dr_status <= 1'b0; state <= ST_WAIT_RX2; end
        ST_WAIT_RX2: if (rx_inject_valid) state <= ST_CHECK2;
        ST_CHECK2: begin
          if (rx_inject_data === test_bytes[2]) state <= ST_SEND3;
          else state <= ST_FAIL;
        end

        // ---- byte 3 ----
        ST_SEND3: if (!tx_busy) begin tx_valid <= 1'b1; tx_data <= test_bytes[3]; state <= ST_WAIT_BUSY3; end
        ST_WAIT_BUSY3: if (tx_busy) state <= ST_WAIT_RX3;
        ST_WAIT_RX3:   if (rx_inject_valid) state <= ST_CHECK3;
        ST_CHECK3: begin
          if (rx_inject_data === test_bytes[3]) state <= ST_PASS;
          else state <= ST_FAIL;
        end

        ST_PASS: begin test_done <= 1'b1; test_pass <= 1'b1; end
        ST_FAIL: begin test_done <= 1'b1; test_pass <= 1'b0; end
        default: state <= ST_FAIL;
      endcase
    end
  end

  assign dbg_state = state;

endmodule
