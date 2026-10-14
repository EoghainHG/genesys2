// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Eoghain Gray

import riscv_pkg::*;

// Combinational control unit for a single-cycle RV32I processor.
module control (
  input  logic [31:0] instr,
  output alu_op_e     alu_op,
  output logic        alu_src,    // 0 = rs2,  1 = immediate
  output logic        alu_pc_a,   // 0 = rs1,  1 = PC  (AUIPC)
  output logic        reg_write,
  output logic        mem_read,
  output logic        mem_write,
  output wb_sel_e     wb_sel,
  output logic        branch,
  output logic        jump,       // JAL
  output logic        jumpr,      // JALR
  output logic        is_csr,
  output csr_op_e     csr_op,
  output logic        csr_imm,    // 1 = use zimm[4:0] in place of rs1
  output logic        is_ecall,   // ECALL  — trap to mtvec/stvec, cause selected by priv_mode/delegation
  output logic        is_mret,    // MRET   — return from M-mode trap via mepc
  output logic        is_sret,    // SRET   — return from S-mode trap via sepc
  output logic        is_wfi,     // WFI    — no-op in Phase 0
  output logic        is_sfence_vma, // SFENCE.VMA — flush TLBs (rs1/rs2 ignored, full flush)
  output logic        is_fence_i,    // FENCE.I — invalidate the icache + refetch (see cpu.sv imem_fence)
  // RV32A
  output logic        is_lr,      // LR.W
  output logic        is_sc,      // SC.W
  output logic        is_amo,     // AMO* (AMOSWAP/ADD/XOR/AND/OR/MIN/MAX/…)
  output logic [4:0]  amo_funct5  // instr[31:27] for AMO operation select
);

  logic [6:0] opcode;
  logic [2:0] funct3;
  logic       funct7_5;   // bit 5 of funct7 distinguishes ADD/SUB, SRL/SRA
  logic       funct7_m;   // funct7==0000001 → RV32M

  assign opcode   = instr[6:0];
  assign funct3   = instr[14:12];
  assign funct7_5 = instr[30];
  assign funct7_m = (instr[31:25] == 7'b0000001);

  always_comb begin
    // Safe defaults — all outputs produce a no-op
    alu_op    = ALU_ADD;
    alu_src   = 1'b0;
    alu_pc_a  = 1'b0;
    reg_write = 1'b0;
    mem_read  = 1'b0;
    mem_write = 1'b0;
    wb_sel    = WB_ALU;
    branch    = 1'b0;
    jump      = 1'b0;
    jumpr     = 1'b0;
    is_csr    = 1'b0;
    csr_op    = CSR_NOP;
    csr_imm   = 1'b0;
    is_ecall  = 1'b0;
    is_mret   = 1'b0;
    is_sret   = 1'b0;
    is_wfi    = 1'b0;
    is_sfence_vma = 1'b0;
    is_fence_i = 1'b0;
    is_lr     = 1'b0;
    is_sc     = 1'b0;
    is_amo    = 1'b0;
    amo_funct5 = 5'b0;

    case (opcode)
      // ---- R-type -------------------------------------------------------
      7'b0110011: begin
        reg_write = 1'b1;
        if (funct7_m) begin
          // RV32M
          case (funct3)
            3'b000: alu_op = ALU_MUL;
            3'b001: alu_op = ALU_MULH;
            3'b010: alu_op = ALU_MULHSU;
            3'b011: alu_op = ALU_MULHU;
            3'b100: alu_op = ALU_DIV;
            3'b101: alu_op = ALU_DIVU;
            3'b110: alu_op = ALU_REM;
            3'b111: alu_op = ALU_REMU;
            default: alu_op = ALU_ADD;
          endcase
        end else begin
          // RV32I
          case (funct3)
            3'b000: alu_op = funct7_5 ? ALU_SUB : ALU_ADD;
            3'b001: alu_op = ALU_SLL;
            3'b010: alu_op = ALU_SLT;
            3'b011: alu_op = ALU_SLTU;
            3'b100: alu_op = ALU_XOR;
            3'b101: alu_op = funct7_5 ? ALU_SRA : ALU_SRL;
            3'b110: alu_op = ALU_OR;
            3'b111: alu_op = ALU_AND;
            default: alu_op = ALU_ADD;
          endcase
        end
      end

      // ---- I-type arithmetic --------------------------------------------
      7'b0010011: begin
        reg_write = 1'b1;
        alu_src   = 1'b1;
        case (funct3)
          3'b000: alu_op = ALU_ADD;          // ADDI
          3'b001: alu_op = ALU_SLL;          // SLLI
          3'b010: alu_op = ALU_SLT;          // SLTI
          3'b011: alu_op = ALU_SLTU;         // SLTIU
          3'b100: alu_op = ALU_XOR;          // XORI
          3'b101: alu_op = funct7_5 ? ALU_SRA : ALU_SRL; // SRAI/SRLI
          3'b110: alu_op = ALU_OR;           // ORI
          3'b111: alu_op = ALU_AND;          // ANDI
          default: alu_op = ALU_ADD;
        endcase
      end

      // ---- Loads --------------------------------------------------------
      7'b0000011: begin
        reg_write = 1'b1;
        alu_src   = 1'b1;
        mem_read  = 1'b1;
        wb_sel    = WB_MEM;
        alu_op    = ALU_ADD;
      end

      // ---- Stores -------------------------------------------------------
      7'b0100011: begin
        alu_src   = 1'b1;
        mem_write = 1'b1;
        alu_op    = ALU_ADD;
      end

      // ---- Branches -----------------------------------------------------
      7'b1100011: begin
        branch = 1'b1;
        // Branch comparisons handled separately; ALU not used for result.
      end

      // ---- JAL ----------------------------------------------------------
      7'b1101111: begin
        reg_write = 1'b1;
        wb_sel    = WB_PC4;
        jump      = 1'b1;
      end

      // ---- JALR ---------------------------------------------------------
      7'b1100111: begin
        reg_write = 1'b1;
        wb_sel    = WB_PC4;
        jumpr     = 1'b1;
        alu_src   = 1'b1;
        alu_op    = ALU_ADD;
      end

      // ---- LUI ----------------------------------------------------------
      7'b0110111: begin
        reg_write = 1'b1;
        alu_src   = 1'b1;
        alu_op    = ALU_COPY_B; // rd = imm (upper 20 bits, lower 12 zeroed by imm_gen)
      end

      // ---- AUIPC --------------------------------------------------------
      7'b0010111: begin
        reg_write = 1'b1;
        alu_src   = 1'b1;
        alu_pc_a  = 1'b1;       // ALU A = PC
        alu_op    = ALU_ADD;    // rd = PC + imm
      end

      // ---- FENCE / FENCE.I --------------------------------------------
      // Plain FENCE (funct3==000) is a NOP on this in-order, single-hart
      // core (no store buffer / no reordering to fence). FENCE.I
      // (funct3==001) must make prior data stores visible to instruction
      // fetch — this core's caches are NOT coherent and there is no
      // snooping, so cpu.sv turns is_fence_i into a full icache invalidate
      // + an EX-stage refetch of the following instruction.
      7'b0001111: begin
        if (funct3 == 3'b001) is_fence_i = 1'b1;
      end

      // ---- RV32A atomics ------------------------------------------------
      7'b0101111: begin
        reg_write  = 1'b1;
        alu_src    = 1'b1;   // imm=0 → ALU computes rs1+0=rs1 (effective addr)
        amo_funct5 = instr[31:27];
        case (instr[31:27])
          5'b00010: begin    // LR.W
            is_lr    = 1'b1;
            mem_read = 1'b1;
            wb_sel   = WB_MEM;
          end
          5'b00011: begin    // SC.W
            is_sc  = 1'b1;
            wb_sel = WB_SC;
          end
          default: begin     // AMO* (AMOSWAP, AMOADD, AMOXOR, AMOAND, …)
            is_amo   = 1'b1;
            mem_read = 1'b1;
            wb_sel   = WB_MEM;
          end
        endcase
      end

      // ---- SYSTEM -------------------------------------------------------
      7'b1110011: begin
        case (funct3)
          3'b001: begin // CSRRW
            is_csr = 1'b1; csr_op = CSR_RW;
            reg_write = 1'b1; wb_sel = WB_CSR;
          end
          3'b010: begin // CSRRS
            is_csr = 1'b1; csr_op = CSR_RS;
            reg_write = 1'b1; wb_sel = WB_CSR;
          end
          3'b011: begin // CSRRC
            is_csr = 1'b1; csr_op = CSR_RC;
            reg_write = 1'b1; wb_sel = WB_CSR;
          end
          3'b101: begin // CSRRWI
            is_csr = 1'b1; csr_op = CSR_RW; csr_imm = 1'b1;
            reg_write = 1'b1; wb_sel = WB_CSR;
          end
          3'b110: begin // CSRRSI
            is_csr = 1'b1; csr_op = CSR_RS; csr_imm = 1'b1;
            reg_write = 1'b1; wb_sel = WB_CSR;
          end
          3'b111: begin // CSRRCI
            is_csr = 1'b1; csr_op = CSR_RC; csr_imm = 1'b1;
            reg_write = 1'b1; wb_sel = WB_CSR;
          end
          default: begin
            if (instr[31:20] == 12'h000) is_ecall = 1'b1; // ECALL
            if (instr[31:20] == 12'h302) is_mret  = 1'b1; // MRET
            if (instr[31:20] == 12'h102) is_sret  = 1'b1; // SRET
            if (instr[31:20] == 12'h105) is_wfi   = 1'b1; // WFI
            if (instr[31:25] == 7'b0001001) is_sfence_vma = 1'b1; // SFENCE.VMA
          end
        endcase
      end

      default: begin // Illegal / unimplemented — NOP
      end
    endcase
  end

endmodule
