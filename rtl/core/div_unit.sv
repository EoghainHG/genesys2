// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Eoghain Gray

// 32-cycle restoring integer divider.
//
// Latency: start → done = 34 clock cycles (1 setup + 32 shift-subtract + 1 output).
// busy is asserted from start until the cycle after done.
//
// RISC-V corner cases:
//   divide-by-zero : quotient = 0xFFFFFFFF, remainder = dividend
//   INT_MIN / -1   : quotient = 0x80000000, remainder = 0
//
// is_signed=1 → DIV / REM; is_rem=1 → select remainder output.
// Per-cycle path (running): FF → 1-bit shift + 33-bit sub → FF (~6 ns TT).
//
// abort: synchronous "the instruction that started me was flushed" — forces the FSM
// back to idle so a re-issued M-op re-latches fresh operands. Wired to flush_id_ex in
// cpu.sv (only reachable via the id_ex_duplicate flush path while an M-op sits in EX).

module div_unit (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        abort,
  input  logic        start,
  input  logic [31:0] a,
  input  logic [31:0] b,
  input  logic        is_signed,
  input  logic        is_rem,
  output logic        busy,
  output logic        done,
  output logic [31:0] result
);

  logic [5:0]  cnt;               // 0=IDLE, 1-32=running, 33=output

  logic [31:0] dividend_r;        // abs(a) shifted left each cycle
  logic [31:0] divisor_r;         // abs(b), constant
  logic [31:0] a_orig_r;          // original a for corner-case remainder
  logic        neg_q_r, neg_r_r;
  logic        is_rem_r;
  logic        corner_dbz, corner_ovf;
  logic [31:0] partial_r;         // running partial remainder
  logic [31:0] quotient_r;

  // Combinatorial step signals (module-scope, not inside always_ff)
  logic [32:0] shifted_partial;
  logic [32:0] trial_sub;
  logic [31:0] q_out, r_out;
  logic [31:0] abs_a_c, abs_b_c;

  assign busy            = (cnt != 6'd0);
  assign done            = (cnt == 6'd33);
  assign shifted_partial = {1'b0, partial_r[30:0], dividend_r[31]};
  assign trial_sub       = {1'b0, shifted_partial[31:0]} - {1'b0, divisor_r};

  // Output combinatorial mux (only meaningful when cnt==33)
  always_comb begin
    q_out = neg_q_r ? -quotient_r : quotient_r;
    r_out = neg_r_r ? -partial_r  : partial_r;
    if (corner_dbz) begin
      q_out = 32'hffff_ffff;
      r_out = a_orig_r;
    end
    if (corner_ovf) begin
      q_out = 32'h8000_0000;
      r_out = 32'd0;
    end
  end

  // Absolute values for setup (only used when start fires)
  assign abs_a_c = (is_signed && a[31]) ? -a : a;
  assign abs_b_c = (is_signed && b[31]) ? -b : b;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cnt         <= 6'd0;
      dividend_r  <= '0; divisor_r   <= '0; a_orig_r   <= '0;
      neg_q_r     <= '0; neg_r_r     <= '0; is_rem_r   <= '0;
      corner_dbz  <= '0; corner_ovf  <= '0;
      partial_r   <= '0; quotient_r  <= '0;
      result      <= '0;
    end else if (abort) begin
      cnt <= 6'd0;
    end else begin
      case (cnt)

        6'd0: begin
          if (start) begin
            dividend_r  <= abs_a_c;
            divisor_r   <= abs_b_c;
            a_orig_r    <= a;
            neg_q_r     <= is_signed && (a[31] ^ b[31]) && (b != '0);
            neg_r_r     <= is_signed && a[31] && (b != '0);
            is_rem_r    <= is_rem;
            corner_dbz  <= (b == '0);
            corner_ovf  <= is_signed && (a == 32'h8000_0000) && (b == 32'hffff_ffff);
            partial_r   <= '0;
            quotient_r  <= '0;
            cnt         <= 6'd1;
          end
        end

        6'd33: begin
          result <= is_rem_r ? r_out : q_out;
          cnt    <= 6'd0;
        end

        default: begin
          // One restoring division step: shift partial left, bring in next dividend bit,
          // subtract divisor; keep if non-negative, restore otherwise.
          if (!trial_sub[32]) begin
            partial_r  <= trial_sub[31:0];
            quotient_r <= {quotient_r[30:0], 1'b1};
          end else begin
            partial_r  <= shifted_partial[31:0];
            quotient_r <= {quotient_r[30:0], 1'b0};
          end
          dividend_r <= {dividend_r[30:0], 1'b0};
          cnt        <= cnt + 6'd1;
        end

      endcase
    end
  end

endmodule
