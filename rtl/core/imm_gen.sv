// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Eoghain Gray

// Generates the sign-extended immediate for all RV32I instruction formats.
module imm_gen (
  input  logic [31:0] instr,
  output logic [31:0] imm
);

  logic [6:0] opcode;
  assign opcode = instr[6:0];

  always_comb begin
    case (opcode)
      // I-type: ADDI, SLTI, SLTIU, XORI, ORI, ANDI, SLLI, SRLI, SRAI
      7'b0010011,
      // I-type: LB, LH, LW, LBU, LHU
      7'b0000011,
      // I-type: JALR
      7'b1100111,
      // I-type: ECALL/EBREAK/CSR
      7'b1110011:
        imm = {{20{instr[31]}}, instr[31:20]};

      // S-type: SB, SH, SW
      7'b0100011:
        imm = {{20{instr[31]}}, instr[31:25], instr[11:7]};

      // B-type: BEQ, BNE, BLT, BGE, BLTU, BGEU
      7'b1100011:
        imm = {{19{instr[31]}}, instr[31], instr[7], instr[30:25], instr[11:8], 1'b0};

      // U-type: LUI, AUIPC
      7'b0110111,
      7'b0010111:
        imm = {instr[31:12], 12'b0};

      // J-type: JAL
      7'b1101111:
        imm = {{11{instr[31]}}, instr[31], instr[19:12], instr[20], instr[30:21], 1'b0};

      default:
        imm = 32'b0;
    endcase
  end

endmodule
