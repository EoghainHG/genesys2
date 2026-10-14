// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Eoghain Gray

// Minimal PLIC: single source (id 1 = UART RX), two contexts — context 0
// (M-mode, drives `meip`) and context 1 (S-mode, drives `seip`) (2026-07-22:
// context 1 added — Linux's stock irq-sifive-plic.c driver only registers a
// handler for a context whose parent hwirq is the Supervisor-external cause;
// a context-0-only PLIC left it with "0 handlers for 1 context" at boot,
// silently never enabling the UART's real interrupt at all. See
// rtl/core/cpu.sv's matching `irq_seip` input for the CPU side of this fix).
// Real SiFive/PLIC register offsets (priority/pending/enable/threshold/
// claim-complete) so a later Linux device-tree binding needs no rework,
// even though only source 1 / contexts 0-1 are ever populated.
//
// Gateway semantics: `pending1` latches on a rising raw level while not
// already in service; a claim read (from EITHER context) returns source id
// 1 (if pending && that context's own enable && priority>that context's own
// threshold) and moves it to in-service, clearing pending; a complete write
// (from either context) clears in-service, and if the raw level is still
// high, pending re-latches on the next cycle. `in_service1` is genuinely
// per-SOURCE (not per-context), matching real PLIC semantics — only one
// context can have a given source claimed at a time.
module plic #(
  parameter logic [31:0] BASE_ADDR = 32'h0C00_0000
)(
  input  logic        clk,
  input  logic        rst_n,

  input  logic [31:0] addr,
  input  logic [31:0] wdata,
  input  logic [3:0]  wmask,
  input  logic        wen,
  input  logic        ren,
  output logic [31:0] rdata,

  input  logic        irq_source1,  // raw level line, source id 1 (UART RX)
  output logic         meip,        // context 0 (M-mode) claimable
  output logic         seip         // context 1 (S-mode) claimable
);

  localparam logic [31:0] OFF_PRIORITY1      = 32'h0000_0004;
  localparam logic [31:0] OFF_PENDING0       = 32'h0000_1000;
  localparam logic [31:0] OFF_ENABLE0_CTX0   = 32'h0000_2000;
  localparam logic [31:0] OFF_ENABLE0_CTX1   = 32'h0000_2080;
  localparam logic [31:0] OFF_THRESHOLD_CTX0 = 32'h0020_0000;
  localparam logic [31:0] OFF_CLAIM_CTX0     = 32'h0020_0004;
  localparam logic [31:0] OFF_THRESHOLD_CTX1 = 32'h0020_1000;
  localparam logic [31:0] OFF_CLAIM_CTX1     = 32'h0020_1004;

  logic [31:0] off;
  assign off = addr - BASE_ADDR;

  logic [2:0] priority1;
  logic       enable1_ctx0, enable1_ctx1;
  logic [2:0] threshold0, threshold1;
  logic       pending1, in_service1;

  logic claimable_ctx0, claimable_ctx1;
  assign claimable_ctx0 = pending1 && enable1_ctx0 && (priority1 > threshold0);
  assign claimable_ctx1 = pending1 && enable1_ctx1 && (priority1 > threshold1);
  assign meip = claimable_ctx0;
  assign seip = claimable_ctx1;

  logic claim_fire_ctx0, complete_fire_ctx0;
  logic claim_fire_ctx1, complete_fire_ctx1;
  assign claim_fire_ctx0    = ren && (off == OFF_CLAIM_CTX0);
  assign complete_fire_ctx0 = wen && (off == OFF_CLAIM_CTX0);
  assign claim_fire_ctx1    = ren && (off == OFF_CLAIM_CTX1);
  assign complete_fire_ctx1 = wen && (off == OFF_CLAIM_CTX1);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      priority1    <= 3'h0;
      enable1_ctx0 <= 1'b0;
      enable1_ctx1 <= 1'b0;
      threshold0   <= 3'h0;
      threshold1   <= 3'h0;
      pending1     <= 1'b0;
      in_service1  <= 1'b0;
    end else begin
      if (irq_source1 && !in_service1) pending1 <= 1'b1;

      if (wen) begin
        case (off)
          OFF_PRIORITY1:      if (wmask[0]) priority1    <= wdata[2:0];
          OFF_ENABLE0_CTX0:   if (wmask[0]) enable1_ctx0 <= wdata[1];
          OFF_ENABLE0_CTX1:   if (wmask[0]) enable1_ctx1 <= wdata[1];
          OFF_THRESHOLD_CTX0: if (wmask[0]) threshold0   <= wdata[2:0];
          OFF_THRESHOLD_CTX1: if (wmask[0]) threshold1   <= wdata[2:0];
          default: ;
        endcase
      end

      if (claim_fire_ctx0 && claimable_ctx0) begin
        pending1    <= 1'b0;
        in_service1 <= 1'b1;
      end else if (claim_fire_ctx1 && claimable_ctx1) begin
        pending1    <= 1'b0;
        in_service1 <= 1'b1;
      end else if (complete_fire_ctx0 && (wdata == 32'd1)) begin
        in_service1 <= 1'b0;
      end else if (complete_fire_ctx1 && (wdata == 32'd1)) begin
        in_service1 <= 1'b0;
      end
    end
  end

  always_comb begin
    if (ren) begin
      case (off)
        OFF_PRIORITY1:      rdata = {29'h0, priority1};
        OFF_PENDING0:        rdata = {30'h0, pending1, 1'b0};
        OFF_ENABLE0_CTX0:   rdata = {30'h0, enable1_ctx0, 1'b0};
        OFF_ENABLE0_CTX1:   rdata = {30'h0, enable1_ctx1, 1'b0};
        OFF_THRESHOLD_CTX0: rdata = {29'h0, threshold0};
        OFF_THRESHOLD_CTX1: rdata = {29'h0, threshold1};
        OFF_CLAIM_CTX0:     rdata = claimable_ctx0 ? 32'd1 : 32'd0;
        OFF_CLAIM_CTX1:     rdata = claimable_ctx1 ? 32'd1 : 32'd0;
        default:            rdata = 32'h0;
      endcase
    end else begin
      rdata = 32'h0;
    end
  end

endmodule
