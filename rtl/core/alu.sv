// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Eoghain Gray

import riscv_pkg::*;

// Pure combinational ALU: add/sub/shift/logic/compare only.
// RV32M (MUL/MULH/MULHSU/MULHU, DIV/DIVU/REM/REMU) is handled by the iterative
// mul_unit / div_unit instantiated in cpu.sv's EX stage — the M opcodes reach the
// `default` arm here and are never selected onto `result` (cpu.sv's ex_result mux
// overrides the ALU output for an M-op). Keeping the combinational `*` / `/` out of
// this module is what takes the divide off the fabric critical path.

module alu (
  input  logic [31:0] a,
  input  logic [31:0] b,
  input  alu_op_e     op,
  output logic [31:0] result,
  output logic        zero
);

  always_comb begin
    case (op)
      ALU_ADD:    result = a + b;
      ALU_SUB:    result = a - b;
      ALU_SLL:    result = a << b[4:0];
      ALU_SLT:    result = {31'd0, $signed(a) < $signed(b)};
      ALU_SLTU:   result = {31'd0, a < b};
      ALU_XOR:    result = a ^ b;
      ALU_SRL:    result = a >> b[4:0];
      ALU_SRA:    result = $signed(a) >>> b[4:0];
      ALU_OR:     result = a | b;
      ALU_AND:    result = a & b;
      ALU_COPY_B: result = b;
      default:    result = '0;
    endcase
    zero = (result == '0);
  end

endmodule
