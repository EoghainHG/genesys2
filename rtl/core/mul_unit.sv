// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Eoghain Gray

// 3-cycle 32×32 multiplier using 16×32 sub-products.
//
// Latency: start asserted → done asserted = 3 clock cycles.
// busy is high during S1 and S2 (cycles 1-2); deasserts the cycle done fires (cycle 3).
// cpu.sv uses: mul_stall = is_mul && !done && !result_valid, start = is_mul && !busy && !result_valid.
//
// mode[1] = sign_b (signed b), mode[0] = sign_a (signed a):
//   MUL / MULHU : mode = 2'b00  (unsigned product; caller selects lo/hi 32)
//   MULHSU      : mode = 2'b01  (signed a, unsigned b)
//   MULH        : mode = 2'b11  (signed a, signed b)
//
// Sign-correction identity:
//   signed_result = unsigned(a)*unsigned(b)
//                 - (sign_a ? b*2^32 : 0)
//                 - (sign_b ? a*2^32 : 0)
//   Only bits [63:32] differ from the unsigned product.
//
// abort: synchronous "the instruction that started me was flushed" — forces the FSM
// back to idle so a re-issued M-op re-latches fresh operands. Wired to flush_id_ex in
// cpu.sv (only reachable via the id_ex_duplicate flush path while an M-op sits in EX).

module mul_unit (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        abort,
  input  logic        start,      // 1-cycle pulse; a/b/mode must be valid
  input  logic [31:0] a, b,
  input  logic [1:0]  mode,
  output logic        busy,       // stall pipeline while high
  output logic        done,       // result valid this cycle (1-cycle pulse)
  output logic [63:0] result
);

  logic [1:0]  cnt;       // 0=IDLE, 1=S1, 2=S2, 3=DONE
  logic [31:0] a1_r, b1_r;
  logic [1:0]  mode1_r;
  logic [47:0] lo2_r, hi2_r;   // 16×32 partial products (16+32=48-bit max)
  logic [31:0] a2_r, b2_r;
  logic [1:0]  mode2_r;
  logic [63:0] prod_c;  // combinatorial combine+correct, registered into result

  // busy excludes the done cycle so the pipeline can advance immediately
  assign busy = (cnt == 2'd1) || (cnt == 2'd2);
  assign done = (cnt == 2'd3);

  // Combinatorial combine + sign correction for S2 result (registered into result)
  always_comb begin
    prod_c = {16'b0, lo2_r} + {hi2_r, 16'b0};
    if (mode2_r[0] && a2_r[31]) prod_c = prod_c - {b2_r, 32'b0}; // sign_a
    if (mode2_r[1] && b2_r[31]) prod_c = prod_c - {a2_r, 32'b0}; // sign_b
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cnt     <= 2'd0;
      a1_r    <= '0; b1_r    <= '0; mode1_r <= '0;
      lo2_r   <= '0; hi2_r   <= '0;
      a2_r    <= '0; b2_r    <= '0; mode2_r <= '0;
      result  <= '0;
    end else if (abort) begin
      cnt <= 2'd0;
    end else begin
      case (cnt)
        2'd0: begin
          if (start) begin
            a1_r    <= a;
            b1_r    <= b;
            mode1_r <= mode;
            cnt     <= 2'd1;
          end
        end

        2'd1: begin
          // Two 16×32 partial products.  Each path: FF → 16×32 MUL → FF (~10 ns TT).
          lo2_r   <= 48'(a1_r[15:0])  * 48'(b1_r);   // a_lo × b, zero-extended
          hi2_r   <= 48'(a1_r[31:16]) * 48'(b1_r);   // a_hi × b, zero-extended
          a2_r    <= a1_r;
          b2_r    <= b1_r;
          mode2_r <= mode1_r;
          cnt     <= 2'd2;
        end

        2'd2: begin
          // Combine: a_lo*b + a_hi*b*2^16 = unsigned(a)*unsigned(b).
          // Sign corrections (subtract b*2^32 / a*2^32) fix upper 32 bits.
          // Path: FF → 64-bit add + up to two 64-bit subs → FF (~15 ns TT).
          // prod_c is a module-level combinatorial signal driven above the always_ff.
          result <= prod_c;
          cnt    <= 2'd3;
        end

        2'd3: begin
          cnt <= 2'd0;   // done for one cycle; caller latches result now
        end

        default: cnt <= 2'd0;
      endcase
    end
  end

endmodule
