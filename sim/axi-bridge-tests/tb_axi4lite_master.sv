// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Eoghain Gray

// Directed test for axi4lite_master.sv: drives the cache-facing side
// through a sequence of writes/reads (including a partial-byte-strobe
// write) against axi4lite_slave_bfm's deliberately variable, multi-cycle,
// AW/W-never-aligned latency, and checks read-back data integrity.
//
// No CPU involved — mem_addr/mem_wen/mem_ren are driven directly by this
// testbench's own step sequencer, mirroring the exact request contract
// dcache.sv/icache.sv already use (hold request stable, wait for
// mem_ready) — see rtl/bridge/axi4lite_master.sv's header.
module tb_axi4lite_master (
  input  logic clk,
  input  logic rst_n,
  output logic test_done,
  output logic test_pass
);

  logic [31:0] axi_awaddr, axi_wdata, axi_araddr, axi_rdata;
  logic [3:0]  axi_wstrb;
  logic        axi_awvalid, axi_awready, axi_wvalid, axi_wready;
  logic [1:0]  axi_bresp;
  logic        axi_bvalid, axi_bready;
  logic        axi_arvalid, axi_arready;
  logic [1:0]  axi_rresp;
  logic        axi_rvalid, axi_rready;

  logic [31:0] mem_addr, mem_wdata, mem_rdata;
  logic [3:0]  mem_wmask;
  logic        mem_wen, mem_ren, mem_ready;

  axi4lite_master #(.ADDR_WIDTH(32), .DATA_WIDTH(32)) u_dut (
    .clk        (clk),
    .rst_n      (rst_n),
    .mem_addr   (mem_addr),
    .mem_wdata  (mem_wdata),
    .mem_wmask  (mem_wmask),
    .mem_wen    (mem_wen),
    .mem_ren    (mem_ren),
    .mem_rdata  (mem_rdata),
    .mem_ready  (mem_ready),
    .m_axi_awaddr (axi_awaddr), .m_axi_awprot (), .m_axi_awvalid (axi_awvalid), .m_axi_awready (axi_awready),
    .m_axi_wdata  (axi_wdata),  .m_axi_wstrb  (axi_wstrb),  .m_axi_wvalid (axi_wvalid), .m_axi_wready (axi_wready),
    .m_axi_bresp  (axi_bresp),  .m_axi_bvalid (axi_bvalid), .m_axi_bready (axi_bready),
    .m_axi_araddr (axi_araddr), .m_axi_arprot (), .m_axi_arvalid (axi_arvalid), .m_axi_arready (axi_arready),
    .m_axi_rdata  (axi_rdata),  .m_axi_rresp  (axi_rresp),  .m_axi_rvalid (axi_rvalid), .m_axi_rready (axi_rready)
  );

  axi4lite_slave_bfm #(.ADDR_WIDTH(32), .DATA_WIDTH(32), .MEM_WORDS(256)) u_bfm (
    .clk (clk), .rst_n (rst_n),
    .s_axi_awaddr (axi_awaddr), .s_axi_awvalid (axi_awvalid), .s_axi_awready (axi_awready),
    .s_axi_wdata  (axi_wdata),  .s_axi_wstrb  (axi_wstrb),  .s_axi_wvalid (axi_wvalid), .s_axi_wready (axi_wready),
    .s_axi_bresp  (axi_bresp),  .s_axi_bvalid (axi_bvalid), .s_axi_bready (axi_bready),
    .s_axi_araddr (axi_araddr), .s_axi_arvalid (axi_arvalid), .s_axi_arready (axi_arready),
    .s_axi_rdata  (axi_rdata),  .s_axi_rresp  (axi_rresp),  .s_axi_rvalid (axi_rvalid), .s_axi_rready (axi_rready)
  );

  typedef enum logic [4:0] {
    S_START,
    S_WR1_ISSUE, S_WR1_WAIT,
    S_RD1_ISSUE, S_RD1_WAIT, S_RD1_CHECK,
    S_WR2_ISSUE, S_WR2_WAIT,
    S_WR3_ISSUE, S_WR3_WAIT,
    S_RD2_ISSUE, S_RD2_WAIT, S_RD2_CHECK,
    S_RD3_ISSUE, S_RD3_WAIT, S_RD3_CHECK,
    S_WR4_ISSUE, S_WR4_WAIT,
    S_WR5_ISSUE, S_WR5_WAIT,
    S_RD4_ISSUE, S_RD4_WAIT, S_RD4_CHECK,
    S_DONE
  } step_t;
  step_t step;

  logic [31:0] rd_capture;
  logic        any_mismatch;

  localparam logic [31:0] ADDR_A = 32'h0000_0000;
  localparam logic [31:0] ADDR_B = 32'h0000_0010;
  localparam logic [31:0] ADDR_C = 32'h0000_0020;
  localparam logic [31:0] ADDR_D = 32'h0000_0030;

  localparam logic [31:0] DATA_A = 32'hDEAD_BEEF;
  localparam logic [31:0] DATA_B = 32'hCAFE_F00D;
  localparam logic [31:0] DATA_C = 32'h1234_5678;
  localparam logic [31:0] DATA_D_BASE   = 32'hFFFF_FFFF;
  localparam logic [31:0] DATA_D_HALF   = 32'h0000_ABCD;
  localparam logic [31:0] DATA_D_EXPECT = 32'hFFFF_ABCD;  // lower halfword replaced only

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      step         <= S_START;
      mem_wen      <= 1'b0;
      mem_ren      <= 1'b0;
      mem_addr     <= '0;
      mem_wdata    <= '0;
      mem_wmask    <= '0;
      rd_capture   <= '0;
      any_mismatch <= 1'b0;
      test_done    <= 1'b0;
      test_pass    <= 1'b0;
    end else begin
      mem_wen <= 1'b0;  // pulse defaults: deasserted unless a step below re-asserts
      mem_ren <= 1'b0;

      case (step)
        S_START: step <= S_WR1_ISSUE;

        S_WR1_ISSUE: begin
          mem_addr <= ADDR_A; mem_wdata <= DATA_A; mem_wmask <= 4'hF; mem_wen <= 1'b1;
          step <= S_WR1_WAIT;
        end
        S_WR1_WAIT: if (mem_ready) step <= S_RD1_ISSUE;

        S_RD1_ISSUE: begin
          mem_addr <= ADDR_A; mem_ren <= 1'b1;
          step <= S_RD1_WAIT;
        end
        S_RD1_WAIT: if (mem_ready) begin rd_capture <= mem_rdata; step <= S_RD1_CHECK; end
        S_RD1_CHECK: begin
          if (rd_capture !== DATA_A) any_mismatch <= 1'b1;
          step <= S_WR2_ISSUE;
        end

        S_WR2_ISSUE: begin
          mem_addr <= ADDR_B; mem_wdata <= DATA_B; mem_wmask <= 4'hF; mem_wen <= 1'b1;
          step <= S_WR2_WAIT;
        end
        S_WR2_WAIT: if (mem_ready) step <= S_WR3_ISSUE;

        S_WR3_ISSUE: begin
          mem_addr <= ADDR_C; mem_wdata <= DATA_C; mem_wmask <= 4'hF; mem_wen <= 1'b1;
          step <= S_WR3_WAIT;
        end
        S_WR3_WAIT: if (mem_ready) step <= S_RD2_ISSUE;

        S_RD2_ISSUE: begin
          mem_addr <= ADDR_B; mem_ren <= 1'b1;
          step <= S_RD2_WAIT;
        end
        S_RD2_WAIT: if (mem_ready) begin rd_capture <= mem_rdata; step <= S_RD2_CHECK; end
        S_RD2_CHECK: begin
          if (rd_capture !== DATA_B) any_mismatch <= 1'b1;
          step <= S_RD3_ISSUE;
        end

        S_RD3_ISSUE: begin
          mem_addr <= ADDR_C; mem_ren <= 1'b1;
          step <= S_RD3_WAIT;
        end
        S_RD3_WAIT: if (mem_ready) begin rd_capture <= mem_rdata; step <= S_RD3_CHECK; end
        S_RD3_CHECK: begin
          if (rd_capture !== DATA_C) any_mismatch <= 1'b1;
          step <= S_WR4_ISSUE;
        end

        S_WR4_ISSUE: begin
          mem_addr <= ADDR_D; mem_wdata <= DATA_D_BASE; mem_wmask <= 4'hF; mem_wen <= 1'b1;
          step <= S_WR4_WAIT;
        end
        S_WR4_WAIT: if (mem_ready) step <= S_WR5_ISSUE;

        S_WR5_ISSUE: begin
          // Partial write: only the lower halfword's strobe bits set.
          mem_addr <= ADDR_D; mem_wdata <= DATA_D_HALF; mem_wmask <= 4'b0011; mem_wen <= 1'b1;
          step <= S_WR5_WAIT;
        end
        S_WR5_WAIT: if (mem_ready) step <= S_RD4_ISSUE;

        S_RD4_ISSUE: begin
          mem_addr <= ADDR_D; mem_ren <= 1'b1;
          step <= S_RD4_WAIT;
        end
        S_RD4_WAIT: if (mem_ready) begin rd_capture <= mem_rdata; step <= S_RD4_CHECK; end
        S_RD4_CHECK: begin
          if (rd_capture !== DATA_D_EXPECT) any_mismatch <= 1'b1;
          step <= S_DONE;
        end

        S_DONE: begin
          test_done <= 1'b1;
          test_pass <= !any_mismatch;
        end

        default: step <= S_START;
      endcase
    end
  end

endmodule
