// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Eoghain Gray

// Minimal single-hart CLINT (Core-Local Interruptor), SiFive/qemu-virt
// register layout: msip @ +0x0000, mtimecmp @ +0x4000/+0x4004, mtime @
// +0xBFF8/+0xBFFC. mtime is free-running (increments every clock — no
// real-vs-sim timebase divider modeled). mtimecmp resets to all-1s so mtip
// can never spuriously assert before software programs it.
module clint #(
  parameter logic [31:0] BASE_ADDR = 32'h0200_0000
)(
  input  logic        clk,
  input  logic        rst_n,

  input  logic [31:0] addr,
  input  logic [31:0] wdata,
  input  logic [3:0]  wmask,
  input  logic        wen,
  input  logic        ren,
  output logic [31:0] rdata,

  output logic         mtip,
  output logic         msip_irq
);

  localparam logic [15:0] OFF_MSIP      = 16'h0000;
  localparam logic [15:0] OFF_MTIMECMP_LO = 16'h4000;
  localparam logic [15:0] OFF_MTIMECMP_HI = 16'h4004;
  localparam logic [15:0] OFF_MTIME_LO  = 16'hBFF8;
  localparam logic [15:0] OFF_MTIME_HI  = 16'hBFFC;

  logic [15:0] off;
  assign off = addr[15:0] - BASE_ADDR[15:0];

  logic [63:0] mtime, mtimecmp;
  logic        msip;

  assign mtip     = (mtime >= mtimecmp);
  assign msip_irq = msip;

  function automatic logic [31:0] apply_wmask(
    input logic [31:0] cur, input logic [31:0] wd, input logic [3:0] wm
  );
    apply_wmask = { wm[3] ? wd[31:24] : cur[31:24],
                     wm[2] ? wd[23:16] : cur[23:16],
                     wm[1] ? wd[15:8]  : cur[15:8],
                     wm[0] ? wd[7:0]   : cur[7:0] };
  endfunction

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      mtime    <= 64'h0;
      mtimecmp <= 64'hFFFF_FFFF_FFFF_FFFF;
      msip     <= 1'b0;
    end else begin
      mtime <= mtime + 64'h1;
      if (wen) begin
        case (off)
          OFF_MSIP:         msip                <= wmask[0] ? wdata[0] : msip;
          OFF_MTIMECMP_LO:  mtimecmp[31:0]       <= apply_wmask(mtimecmp[31:0],  wdata, wmask);
          OFF_MTIMECMP_HI:  mtimecmp[63:32]      <= apply_wmask(mtimecmp[63:32], wdata, wmask);
          OFF_MTIME_LO:     mtime[31:0]          <= apply_wmask(mtime[31:0],  wdata, wmask);
          OFF_MTIME_HI:     mtime[63:32]         <= apply_wmask(mtime[63:32], wdata, wmask);
          default: ;
        endcase
      end
    end
  end

  always_comb begin
    if (ren) begin
      case (off)
        OFF_MSIP:        rdata = {31'h0, msip};
        OFF_MTIMECMP_LO: rdata = mtimecmp[31:0];
        OFF_MTIMECMP_HI: rdata = mtimecmp[63:32];
        OFF_MTIME_LO:    rdata = mtime[31:0];
        OFF_MTIME_HI:    rdata = mtime[63:32];
        default:         rdata = 32'h0;
      endcase
    end else begin
      rdata = 32'h0;
    end
  end

endmodule
