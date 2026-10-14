// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Eoghain Gray

// Directed test for the 2026-09-12 TX/RX FIFO addition (rtl/periph/uart.sv's
// new tx_fifo, rtl/bridge/uart_phy.sv's new rx_fifo) -- the actual fix for
// the vi/top interactive-console livelock: a real 8250 driver bursts up to
// `fifosize` THR writes in a row after seeing THRE=1, WITHOUT re-checking
// THRE between each byte. The old single-register TX handoff silently
// dropped any byte written while the phy was still busy shifting a prior
// one -- this test reproduces exactly that access pattern (unlike
// sim/uart-phy-tests/tb_uart_phy.sv, which only ever sends one byte at a
// time and explicitly waits for !tx_busy before the next write) and
// confirms all 16 bytes survive, in order, at the real MMIO register
// boundary (uart.sv's THR/LSR/RBR), not via a hierarchical peek.
//
// Both uart.sv and uart_phy.sv are instantiated together with uart_tx_pin
// looped directly to uart_rx_pin (self-loopback, same methodology as
// tb_uart_phy.sv) -- so this test exercises the new RX FIFO too: all 16
// transmitted bytes loop back and queue up in rx_fifo well before the test
// starts reading RBR, since nothing drains RX during the write-burst phase.
//
// CLK_FREQ_HZ/BAUD_RATE are the same tiny scaled-down values tb_uart_phy.sv
// uses -- only the CLKS_PER_BIT/OSR *ratio* matters to the logic under test.
module tb_uart_fifo (
  input  logic clk,
  input  logic rst_n,
  output logic test_done,
  output logic test_pass,
  output logic [4:0] dbg_state,
  output logic [4:0] dbg_write_idx,
  output logic [4:0] dbg_read_idx,
  output logic [7:0] dbg_got_byte
);

  localparam int CLK_FREQ_HZ = 3200;
  localparam int BAUD_RATE   = 100;   // CLKS_PER_BIT = 32

  // ---- uart.sv <-> testbench MMIO bus ----
  logic [31:0] addr, wdata;
  logic [3:0]  wmask;
  logic        wen, ren;
  logic [31:0] rdata;
  logic        irq, dr_status;

  // ---- uart.sv <-> uart_phy.sv ----
  logic       tx_valid, tx_busy;
  logic [7:0] tx_data;
  logic       rx_inject_valid;
  logic [7:0] rx_inject_data;
  logic       loop_wire;

  localparam logic [31:0] UART_THR = 32'h0;
  localparam logic [31:0] UART_LSR = 32'h5;
  localparam bit [7:0]    LSR_DR   = 8'h01;
  localparam bit [7:0]    LSR_TEMT = 8'h40;

  uart #(.BASE_ADDR(32'h0)) u_uart (
    .clk             (clk),
    .rst_n           (rst_n),
    .addr            (addr),
    .wdata           (wdata),
    .wmask           (wmask),
    .wen             (wen),
    .ren             (ren),
    .rdata           (rdata),
    .tx_valid        (tx_valid),
    .tx_data         (tx_data),
    .tx_busy         (tx_busy),
    .rx_inject_valid (rx_inject_valid),
    .rx_inject_data  (rx_inject_data),
    .irq             (irq),
    .dr_status       (dr_status)
  );

  uart_phy #(.CLK_FREQ_HZ(CLK_FREQ_HZ), .BAUD_RATE(BAUD_RATE)) u_phy (
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

  // Pattern: byte i's value is simply i (0..15) -- easy to check, and
  // distinct enough to catch a reorder or drop.
  function automatic logic [7:0] pattern(input logic [4:0] i);
    pattern = {3'b000, i};
  endfunction

  typedef enum logic [4:0] {
    ST_RESET_WAIT,
    // Burst-write all 16 bytes back-to-back, NOT waiting for THRE/tx_busy
    // between any of them -- this is the exact access pattern
    // serial8250_tx_chars() uses, and the one the old single-register
    // handoff could not survive.
    ST_BURST_WRITE,
    // Wait for the whole FIFO to actually drain out over the wire (real
    // 16550A semantics: THRE means FIFO empty, TEMT means FIFO empty AND
    // the shift register is done too) via a real LSR read, not a peek.
    ST_WAIT_TEMT,
    // Drain RBR one byte at a time, waiting for LSR.DR each time -- checks
    // both that nothing was dropped and that order was preserved.
    // ST_READ_RBR_ISSUE/_CAPTURE are deliberately split into two cycles:
    // rdata is combinational on addr/ren, which only settle to their new
    // value in the cycle *after* a state changes them (nonblocking-assign
    // semantics) -- capturing in the same cycle that first sets a new addr
    // would read back the *previous* state's still-settling value (bit
    // this test itself found the hard way while being written; ST_WAIT_TEMT
    // and ST_WAIT_DR are naturally immune since they loop on the *same*
    // address every cycle until their condition is met).
    ST_WAIT_DR, ST_READ_RBR_ISSUE, ST_READ_RBR_CAPTURE, ST_CHECK,
    ST_PASS, ST_FAIL
  } state_t;

  state_t      state;
  logic [4:0]  write_idx; // 0..16 (16 = burst done)
  logic [4:0]  read_idx;  // 0..16 (16 = all read back)
  logic [31:0] lsr_rd;
  logic [7:0]  got_byte;

  assign dbg_state     = state;
  assign dbg_write_idx = write_idx;
  assign dbg_read_idx  = read_idx;
  assign dbg_got_byte  = got_byte;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state     <= ST_RESET_WAIT;
      write_idx <= '0;
      read_idx  <= '0;
      addr      <= '0;
      wdata     <= '0;
      wmask     <= '0;
      wen       <= 1'b0;
      ren       <= 1'b0;
      test_done <= 1'b0;
      test_pass <= 1'b0;
      lsr_rd    <= '0;
      got_byte  <= '0;
    end else begin
      // Defaults: exactly one of wen/ren is asserted per state below.
      wen <= 1'b0;
      ren <= 1'b0;

      case (state)
        ST_RESET_WAIT: state <= ST_BURST_WRITE;

        ST_BURST_WRITE: begin
          // One THR write per cycle, unconditionally -- no wait on
          // tx_busy/THRE at all, for all 16 bytes.
          addr  <= UART_THR;
          wdata <= {24'h0, pattern(write_idx)};
          wmask <= 4'b0001;
          wen   <= 1'b1;
          if (write_idx == 5'd15) begin
            write_idx <= '0;
            state     <= ST_WAIT_TEMT;
          end else begin
            write_idx <= write_idx + 5'd1;
          end
        end

        // UART_LSR (offset 5) lands in byte_lane 1 (addr[1:0] == 2'd1), i.e.
        // rdata[15:8] -- NOT rdata[7:0] (that lane is only correct for
        // offset-0 reads like RBR below). A real CPU's lbu/AXI-lite path
        // does this byte-lane extraction transparently; this bare-metal
        // testbench has to do it explicitly.
        ST_WAIT_TEMT: begin
          addr <= UART_LSR;
          ren  <= 1'b1;
          lsr_rd <= rdata; // captures the PREVIOUS cycle's ren/addr request
          if ((lsr_rd[15:8] & LSR_TEMT) != 8'h0) state <= ST_WAIT_DR;
        end

        ST_WAIT_DR: begin
          addr <= UART_LSR;
          ren  <= 1'b1;
          lsr_rd <= rdata;
          if ((lsr_rd[15:8] & LSR_DR) != 8'h0) state <= ST_READ_RBR_ISSUE;
        end

        // Issue the RBR read (addr changes from LSR to THR here) -- do NOT
        // capture rdata yet, it still reflects ST_WAIT_DR's LSR read for
        // this whole cycle.
        ST_READ_RBR_ISSUE: begin
          addr  <= UART_THR; // RBR shares THR's offset (0x0)
          ren   <= 1'b1;
          state <= ST_READ_RBR_CAPTURE;
        end

        // Now addr/ren have held UART_THR/1 for a full cycle -- rdata is
        // the real RBR value.
        ST_READ_RBR_CAPTURE: begin
          got_byte <= rdata[7:0];
          state    <= ST_CHECK;
        end

        ST_CHECK: begin
          if (got_byte !== pattern(read_idx)) begin
            state <= ST_FAIL;
          end else if (read_idx == 5'd15) begin
            state <= ST_PASS;
          end else begin
            read_idx <= read_idx + 5'd1;
            state    <= ST_WAIT_DR;
            // lsr_rd must NOT carry the previous byte's "DR set" value into
            // the next ST_WAIT_DR loop -- ST_WAIT_DR's own first iteration
            // checks lsr_rd *before* re-capturing it fresh (same one-cycle
            // NBA lag as every other addr-changing transition in this FSM),
            // so a stale nonzero DR bit here would let it "detect" a byte
            // that hasn't actually arrived yet. Found the hard way: this
            // exact bug read the last real byte twice instead of ever
            // timing out on the genuinely-never-delivered 17th write.
            lsr_rd   <= '0;
          end
        end

        ST_PASS: begin test_done <= 1'b1; test_pass <= 1'b1; end
        ST_FAIL: begin test_done <= 1'b1; test_pass <= 1'b0; end
        default: state <= ST_FAIL;
      endcase
    end
  end

endmodule
