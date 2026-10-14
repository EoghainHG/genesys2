// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Eoghain Gray

// Directed loopback test for rtl/periph/spi_master.sv: spi_mosi wired
// directly to spi_miso (external loopback, no CPU/SD-card model involved --
// same "test at the right protocol boundary" philosophy as
// sim/uart-phy-tests/tb_uart_phy.sv). Drives the register interface exactly
// as a CPU would (addr/wdata/wmask/wen/ren) and checks each transferred
// byte comes back bit-identical, proving the Mode-0 shift/sample timing is
// self-consistent before ever involving the (much more complex) SD card
// protocol logic in software.
module tb_spi_master (
  input  logic clk,
  input  logic rst_n,
  output logic test_done,
  output logic test_pass,
  output logic [4:0] dbg_step
);

  logic [31:0] addr, wdata, rdata;
  logic [3:0]  wmask;
  logic        wen, ren;

  logic spi_sclk, spi_mosi, spi_miso, spi_cs_n;
  assign spi_miso = spi_mosi; // external loopback

  spi_master u_dut (
    .clk      (clk),
    .rst_n    (rst_n),
    .addr     (addr),
    .wdata    (wdata),
    .wmask    (wmask),
    .wen      (wen),
    .ren      (ren),
    .rdata    (rdata),
    .spi_sclk (spi_sclk),
    .spi_mosi (spi_mosi),
    .spi_miso (spi_miso),
    .spi_cs_n (spi_cs_n)
  );

  localparam logic [31:0] REG_TXRX   = 32'h0;
  localparam logic [31:0] REG_STATUS = 32'h4;
  localparam logic [31:0] REG_CTRL   = 32'h8;
  localparam logic [31:0] REG_CLKDIV = 32'hC;

  logic [7:0] test_bytes [0:3];
  assign test_bytes[0] = 8'h00;
  assign test_bytes[1] = 8'hFF;
  assign test_bytes[2] = 8'hA5;
  assign test_bytes[3] = 8'h5A;

  typedef enum logic [4:0] {
    ST_RESET_WAIT,
    ST_SET_CLKDIV, ST_SET_CS,
    ST_SEND0, ST_WAIT_BUSY0, ST_WAIT_DONE0, ST_CHECK0,
    ST_SEND1, ST_WAIT_BUSY1, ST_WAIT_DONE1, ST_CHECK1,
    ST_SEND2, ST_WAIT_BUSY2, ST_WAIT_DONE2, ST_CHECK2,
    ST_SEND3, ST_WAIT_BUSY3, ST_WAIT_DONE3, ST_CHECK3,
    ST_PASS, ST_FAIL
  } state_t;

  state_t state;
  logic [1:0] byte_idx;

  // One-cycle-pulse register-write helper state (addr/wdata/wmask/wen held
  // for exactly one cycle, matching how the real CPU/mmio_decoder drives
  // this interface).
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state     <= ST_RESET_WAIT;
      addr      <= 32'h0;
      wdata     <= 32'h0;
      wmask     <= 4'h0;
      wen       <= 1'b0;
      ren       <= 1'b0;
      test_done <= 1'b0;
      test_pass <= 1'b0;
      byte_idx  <= 2'd0;
    end else begin
      wen <= 1'b0;
      ren <= 1'b0;

      case (state)
        ST_RESET_WAIT: state <= ST_SET_CLKDIV;

        // Small divider -- fast sim, same "scale down, keep the ratio"
        // philosophy as tb_uart_phy.sv's tiny CLK_FREQ_HZ/BAUD_RATE.
        ST_SET_CLKDIV: begin
          addr  <= REG_CLKDIV; wdata <= 32'd2; wmask <= 4'hF; wen <= 1'b1;
          state <= ST_SET_CS;
        end
        ST_SET_CS: begin
          addr  <= REG_CTRL; wdata <= 32'd0; wmask <= 4'hF; wen <= 1'b1; // assert cs_n=0
          state <= ST_SEND0;
        end

        ST_SEND0: begin
          addr <= REG_TXRX; wdata <= {24'h0, test_bytes[0]}; wmask <= 4'h1; wen <= 1'b1;
          state <= ST_WAIT_BUSY0;
        end
        ST_WAIT_BUSY0: begin addr <= REG_STATUS; ren <= 1'b1; state <= ST_WAIT_DONE0; end
        ST_WAIT_DONE0: begin
          ren <= 1'b1;
          if (rdata[0] == 1'b0) begin addr <= REG_TXRX; ren <= 1'b1; state <= ST_CHECK0; end
        end
        ST_CHECK0: begin
          if (rdata[7:0] == test_bytes[0]) begin byte_idx <= 2'd1; state <= ST_SEND1; end
          else state <= ST_FAIL;
        end

        ST_SEND1: begin
          addr <= REG_TXRX; wdata <= {24'h0, test_bytes[1]}; wmask <= 4'h1; wen <= 1'b1;
          state <= ST_WAIT_BUSY1;
        end
        ST_WAIT_BUSY1: begin addr <= REG_STATUS; ren <= 1'b1; state <= ST_WAIT_DONE1; end
        ST_WAIT_DONE1: begin
          ren <= 1'b1;
          if (rdata[0] == 1'b0) begin addr <= REG_TXRX; ren <= 1'b1; state <= ST_CHECK1; end
        end
        ST_CHECK1: begin
          if (rdata[7:0] == test_bytes[1]) state <= ST_SEND2;
          else state <= ST_FAIL;
        end

        ST_SEND2: begin
          addr <= REG_TXRX; wdata <= {24'h0, test_bytes[2]}; wmask <= 4'h1; wen <= 1'b1;
          state <= ST_WAIT_BUSY2;
        end
        ST_WAIT_BUSY2: begin addr <= REG_STATUS; ren <= 1'b1; state <= ST_WAIT_DONE2; end
        ST_WAIT_DONE2: begin
          ren <= 1'b1;
          if (rdata[0] == 1'b0) begin addr <= REG_TXRX; ren <= 1'b1; state <= ST_CHECK2; end
        end
        ST_CHECK2: begin
          if (rdata[7:0] == test_bytes[2]) state <= ST_SEND3;
          else state <= ST_FAIL;
        end

        ST_SEND3: begin
          addr <= REG_TXRX; wdata <= {24'h0, test_bytes[3]}; wmask <= 4'h1; wen <= 1'b1;
          state <= ST_WAIT_BUSY3;
        end
        ST_WAIT_BUSY3: begin addr <= REG_STATUS; ren <= 1'b1; state <= ST_WAIT_DONE3; end
        ST_WAIT_DONE3: begin
          ren <= 1'b1;
          if (rdata[0] == 1'b0) begin addr <= REG_TXRX; ren <= 1'b1; state <= ST_CHECK3; end
        end
        ST_CHECK3: begin
          if (rdata[7:0] == test_bytes[3]) state <= ST_PASS;
          else state <= ST_FAIL;
        end

        ST_PASS: begin test_done <= 1'b1; test_pass <= 1'b1; end
        ST_FAIL: begin test_done <= 1'b1; test_pass <= 1'b0; end
        default: state <= ST_FAIL;
      endcase
    end
  end

  assign dbg_step = state;

endmodule
