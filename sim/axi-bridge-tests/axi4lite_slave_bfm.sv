// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Eoghain Gray

// Behavioral AXI4-Lite slave, for exercising axi4lite_master.sv against
// something that behaves like real DDR-through-an-interconnect: variable,
// multi-cycle response latency, and — deliberately, since this is the one
// case the adapter's aw_done/w_done tracking exists for — AWREADY and
// WREADY are never forced to arrive on the same cycle.
//
// Backed by a small word-addressed memory (MEM_WORDS words) for read/write
// data-integrity checking. Not a general AXI4-Lite compliance model (no
// exhaustive protocol checking) — just enough behavior to prove the master
// adapter's FSM handles real asynchronous, multi-cycle handshakes correctly.
module axi4lite_slave_bfm #(
  parameter int ADDR_WIDTH = 32,
  parameter int DATA_WIDTH = 32,
  parameter int MEM_WORDS  = 256,
  // Per-channel response delay, in cycles. Defaults match this BFM's
  // original hardcoded values (small, just enough to force AW/W onto
  // different cycles) — every existing caller is unaffected. Widened from
  // the original 3-bit locals (capped at 7) to a full int so callers can
  // request realistic multi-ten-cycle real-DDR-like latency — added
  // 2026-07-23 for sim/full-chain-tests' real-hardware-hang reproduction.
  parameter int AW_DELAY   = 2,
  parameter int W_DELAY    = 0,
  parameter int B_DELAY    = 1,
  parameter int AR_DELAY   = 3,
  parameter int R_DELAY    = 2,
  // RANDOM_EXTRA_MAX (2026-07-27): opt-in variable-latency mode, added to
  // test whether NON-uniform latency (as opposed to a fixed value, however
  // large -- already swept 1-300 cycles with no hang) can reproduce the
  // real-hardware Sv32-enable hang. Default 0 makes every existing caller
  // byte-for-byte unaffected ($urandom_range(0,0) is always 0). When
  // nonzero, each channel draws a fresh random extra delay (0..MAX) at the
  // start of every transaction, added on top of its own fixed *_DELAY.
  parameter int RANDOM_EXTRA_MAX = 0
)(
  input  logic                    clk,
  input  logic                    rst_n,

  input  logic [ADDR_WIDTH-1:0]   s_axi_awaddr,
  input  logic                    s_axi_awvalid,
  output logic                    s_axi_awready,

  input  logic [DATA_WIDTH-1:0]   s_axi_wdata,
  input  logic [DATA_WIDTH/8-1:0] s_axi_wstrb,
  input  logic                    s_axi_wvalid,
  output logic                    s_axi_wready,

  output logic [1:0]              s_axi_bresp,
  output logic                    s_axi_bvalid,
  input  logic                    s_axi_bready,

  input  logic [ADDR_WIDTH-1:0]   s_axi_araddr,
  input  logic                    s_axi_arvalid,
  output logic                    s_axi_arready,

  output logic [DATA_WIDTH-1:0]   s_axi_rdata,
  output logic [1:0]              s_axi_rresp,
  output logic                    s_axi_rvalid,
  input  logic                    s_axi_rready
);

  // Associative (not flat-array) memory, indexed by the FULL word address
  // -- added 2026-07-23. A flat `mem[MEM_WORDS]` array necessarily masks
  // the address down to $clog2(MEM_WORDS) bits, which silently ALIASES any
  // two real addresses that share those low bits (e.g. a real DDR address
  // like 0x80500000 and a completely unrelated fake-peripheral address
  // like 0xE000002C can land on the very same array slot). Found the hard
  // way in sim/full-chain-tests/tb_full_chain.sv: rtl/bridge/
  // ps_uart0_bridge.sv's own CSR-register poll (a fake PS-UART0 address,
  // never meaningfully modeled by this BFM) aliased onto real program
  // bytes, reading back a value that happened to look like "TX FIFO full"
  // forever -- a testbench artifact, not a real RTL bug.
  // An associative array indexed by the complete address has no such
  // collision possible, defaults every never-written address to 0 (SystemVerilog's
  // own associative-array read semantics), and needs no size parameter at
  // all -- MEM_WORDS is kept only so existing callers that still pass it
  // don't need updating, but no longer affects indexing.
  logic [DATA_WIDTH-1:0] mem [bit [ADDR_WIDTH-1:2]];  // keyed by word address (byte addr >> 2)

  // Free-running delay counters, deliberately different periods per channel
  // so AWREADY/WREADY/ARREADY/BVALID/RVALID delays are mutually
  // out-of-phase — this is what forces AW and W to land on different
  // cycles across the test sequence, not just occasionally.
  logic [31:0] aw_delay_ctr, w_delay_ctr, b_delay_ctr, ar_delay_ctr, r_delay_ctr;
  // Per-transaction random extra delay (see RANDOM_EXTRA_MAX above) --
  // latched once when each channel starts waiting, held for that
  // transaction's whole duration (not re-rolled every cycle).
  logic [31:0] aw_extra, w_extra, b_extra, ar_extra, r_extra;

  // -------------------------------------------------------------------------
  // Write address channel
  // -------------------------------------------------------------------------
  typedef enum logic [1:0] { AW_IDLE, AW_WAIT, AW_DONE_ST } aw_state_t;
  aw_state_t aw_state;
  logic [ADDR_WIDTH-1:0] awaddr_latched;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      aw_state       <= AW_IDLE;
      aw_delay_ctr   <= '0;
      aw_extra       <= '0;
      awaddr_latched <= '0;
    end else begin
      case (aw_state)
        AW_IDLE: begin
          if (s_axi_awvalid) begin
            awaddr_latched <= s_axi_awaddr;
            aw_delay_ctr   <= '0;
            aw_extra       <= $urandom_range(0, RANDOM_EXTRA_MAX);
            aw_state       <= AW_WAIT;
          end
        end
        AW_WAIT: begin
          if (aw_delay_ctr >= AW_DELAY + aw_extra) aw_state <= AW_DONE_ST;
          else aw_delay_ctr <= aw_delay_ctr + 32'd1;
        end
        AW_DONE_ST: aw_state <= AW_IDLE;  // ready pulses exactly 1 cycle
        default: aw_state <= AW_IDLE;
      endcase
    end
  end
  assign s_axi_awready = (aw_state == AW_DONE_ST);

  // -------------------------------------------------------------------------
  // Write data channel
  // -------------------------------------------------------------------------
  typedef enum logic [1:0] { W_IDLE, W_WAIT, W_DONE_ST } w_state_t;
  w_state_t w_state;
  logic [DATA_WIDTH-1:0]   wdata_latched;
  logic [DATA_WIDTH/8-1:0] wstrb_latched;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      w_state       <= W_IDLE;
      w_delay_ctr   <= '0;
      w_extra       <= '0;
      wdata_latched <= '0;
      wstrb_latched <= '0;
    end else begin
      case (w_state)
        W_IDLE: begin
          if (s_axi_wvalid) begin
            wdata_latched <= s_axi_wdata;
            wstrb_latched <= s_axi_wstrb;
            w_delay_ctr   <= '0;
            w_extra       <= $urandom_range(0, RANDOM_EXTRA_MAX);
            w_state       <= W_WAIT;
          end
        end
        W_WAIT: begin
          if (w_delay_ctr >= W_DELAY + w_extra) w_state <= W_DONE_ST;
          else w_delay_ctr <= w_delay_ctr + 32'd1;
        end
        W_DONE_ST: w_state <= W_IDLE;
        default: w_state <= W_IDLE;
      endcase
    end
  end
  assign s_axi_wready = (w_state == W_DONE_ST);

  // -------------------------------------------------------------------------
  // Write response channel — fires once BOTH AW and W have each completed
  // their own handshake (tracked independently, matching the two channels
  // above never being forced to align).
  // -------------------------------------------------------------------------
  typedef enum logic [1:0] { B_IDLE, B_WAIT, B_VALID_ST } b_state_t;
  b_state_t b_state;
  logic aw_seen, w_seen;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      b_state      <= B_IDLE;
      b_delay_ctr  <= '0;
      b_extra      <= '0;
      aw_seen      <= 1'b0;
      w_seen       <= 1'b0;
    end else begin
      if (s_axi_awready) aw_seen <= 1'b1;
      if (s_axi_wready)  w_seen  <= 1'b1;
      case (b_state)
        B_IDLE: begin
          if ((aw_seen || s_axi_awready) && (w_seen || s_axi_wready)) begin
            b_delay_ctr <= '0;
            b_extra     <= $urandom_range(0, RANDOM_EXTRA_MAX);
            b_state     <= B_WAIT;
          end
        end
        B_WAIT: begin
          if (b_delay_ctr >= B_DELAY + b_extra) b_state <= B_VALID_ST;
          else b_delay_ctr <= b_delay_ctr + 32'd1;
        end
        B_VALID_ST: begin
          if (s_axi_bready) begin
            // Commit the write to memory only once the full handshake
            // (AW+W+B) has genuinely completed.
            for (int i = 0; i < DATA_WIDTH/8; i++)
              if (wstrb_latched[i])
                mem[awaddr_latched[ADDR_WIDTH-1:2]][i*8 +: 8] <= wdata_latched[i*8 +: 8];
            aw_seen <= 1'b0;
            w_seen  <= 1'b0;
            b_state <= B_IDLE;
          end
        end
        default: b_state <= B_IDLE;
      endcase
    end
  end
  assign s_axi_bresp  = 2'b00;  // OKAY
  assign s_axi_bvalid = (b_state == B_VALID_ST);

  // -------------------------------------------------------------------------
  // Read address channel
  // -------------------------------------------------------------------------
  typedef enum logic [1:0] { AR_IDLE, AR_WAIT, AR_DONE_ST } ar_state_t;
  ar_state_t ar_state;
  logic [ADDR_WIDTH-1:0] araddr_latched;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ar_state       <= AR_IDLE;
      ar_delay_ctr   <= '0;
      ar_extra       <= '0;
      araddr_latched <= '0;
    end else begin
      case (ar_state)
        AR_IDLE: begin
          if (s_axi_arvalid) begin
            araddr_latched <= s_axi_araddr;
            ar_delay_ctr   <= '0;
            ar_extra       <= $urandom_range(0, RANDOM_EXTRA_MAX);
            ar_state       <= AR_WAIT;
          end
        end
        AR_WAIT: begin
          if (ar_delay_ctr >= AR_DELAY + ar_extra) ar_state <= AR_DONE_ST;
          else ar_delay_ctr <= ar_delay_ctr + 32'd1;
        end
        AR_DONE_ST: ar_state <= AR_IDLE;
        default: ar_state <= AR_IDLE;
      endcase
    end
  end
  assign s_axi_arready = (ar_state == AR_DONE_ST);

  // -------------------------------------------------------------------------
  // Read data channel
  // -------------------------------------------------------------------------
  typedef enum logic [1:0] { R_IDLE, R_WAIT, R_VALID_ST } r_state_t;
  r_state_t r_state;
  logic [DATA_WIDTH-1:0] rdata_reg;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      r_state     <= R_IDLE;
      r_delay_ctr <= '0;
      r_extra     <= '0;
      rdata_reg   <= '0;
    end else begin
      case (r_state)
        R_IDLE: begin
          if (s_axi_arready) begin
            rdata_reg   <= mem[araddr_latched[ADDR_WIDTH-1:2]];
            r_delay_ctr <= '0;
            r_extra     <= $urandom_range(0, RANDOM_EXTRA_MAX);
            r_state     <= R_WAIT;
          end
        end
        R_WAIT: begin
          if (r_delay_ctr >= R_DELAY + r_extra) r_state <= R_VALID_ST;
          else r_delay_ctr <= r_delay_ctr + 32'd1;
        end
        R_VALID_ST: begin
          if (s_axi_rready) r_state <= R_IDLE;
        end
        default: r_state <= R_IDLE;
      endcase
    end
  end
  assign s_axi_rdata  = rdata_reg;
  assign s_axi_rresp  = 2'b00;  // OKAY
  assign s_axi_rvalid = (r_state == R_VALID_ST);

endmodule
