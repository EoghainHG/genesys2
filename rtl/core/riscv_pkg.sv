// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Eoghain Gray

package riscv_pkg;

  typedef enum logic [4:0] {
    ALU_ADD    = 5'd0,
    ALU_SUB    = 5'd1,
    ALU_SLL    = 5'd2,
    ALU_SLT    = 5'd3,
    ALU_SLTU   = 5'd4,
    ALU_XOR    = 5'd5,
    ALU_SRL    = 5'd6,
    ALU_SRA    = 5'd7,
    ALU_OR     = 5'd8,
    ALU_AND    = 5'd9,
    ALU_COPY_B = 5'd10,  // pass B unchanged — used for LUI
    // RV32M
    ALU_MUL    = 5'd11,  // lower 32 of rs1*rs2 (signed or unsigned, same result)
    ALU_MULH   = 5'd12,  // upper 32 of signed*signed
    ALU_MULHSU = 5'd13,  // upper 32 of signed*unsigned
    ALU_MULHU  = 5'd14,  // upper 32 of unsigned*unsigned
    ALU_DIV    = 5'd15,  // signed divide
    ALU_DIVU   = 5'd16,  // unsigned divide
    ALU_REM    = 5'd17,  // signed remainder
    ALU_REMU   = 5'd18   // unsigned remainder
  } alu_op_e;

  typedef enum logic [2:0] {
    WB_ALU = 3'd0,   // ALU result
    WB_MEM = 3'd1,   // memory load (sign/zero-extended)
    WB_PC4 = 3'd2,   // PC+4 (JAL/JALR return address)
    WB_CSR = 3'd3,   // CSR read value
    WB_SC  = 3'd4    // SC.W result: 0=success, 1=failure
  } wb_sel_e;

  typedef enum logic [1:0] {
    CSR_NOP = 2'd0,
    CSR_RW  = 2'd1,   // CSRRW / CSRRWI
    CSR_RS  = 2'd2,   // CSRRS / CSRRSI
    CSR_RC  = 2'd3    // CSRRC / CSRRCI
  } csr_op_e;

  typedef enum logic [1:0] {
    PRIV_U = 2'b00,
    PRIV_S = 2'b01,
    PRIV_M = 2'b11
  } priv_mode_e;

  // Exception cause codes used by Phase 0 privilege/trap infrastructure
  // (subset of the full RISC-V privileged spec cause list — only what
  // ECALL delegation actually needs).
  localparam logic [31:0] CAUSE_USER_ECALL       = 32'd8;
  localparam logic [31:0] CAUSE_SUPERVISOR_ECALL = 32'd9;
  localparam logic [31:0] CAUSE_MACHINE_ECALL    = 32'd11;

  // Phase 1 (Sv32 MMU) page-fault causes. Every page-table-walk failure
  // (reserved encoding, invalid pointer, refused superpage leaf, missing
  // A/D bit) is a page fault per spec, not an access fault — access
  // faults are a PMP/physical-memory-map concept that stays dormant
  // until PMP enforcement lands in a later phase.
  localparam logic [31:0] CAUSE_INSTR_PAGE_FAULT = 32'd12;
  localparam logic [31:0] CAUSE_LOAD_PAGE_FAULT  = 32'd13;
  localparam logic [31:0] CAUSE_STORE_PAGE_FAULT = 32'd15; // also used for AMO

  // Phase 2: mip/mie bit positions (RISC-V Privileged Spec). mie bit
  // positions are numerically identical (SSIE/MSIE/STIE/MTIE/SEIE/MEIE).
  localparam int MIP_SSIP_BIT = 1;
  localparam int MIP_MSIP_BIT = 3;
  localparam int MIP_STIP_BIT = 5;
  localparam int MIP_MTIP_BIT = 7;
  localparam int MIP_SEIP_BIT = 9;
  localparam int MIP_MEIP_BIT = 11;

  localparam logic [31:0] MIE_MASK             = 32'h0000_0AAA; // bits 1,3,5,7,9,11
  localparam logic [31:0] MIP_SW_WRITABLE_MASK = 32'h0000_0222; // bits 1,5,9 (SSIP/STIP/SEIP)

  // Phase 2 interrupt mcause values (bit31 set per spec; low bits = cause).
  localparam logic [31:0] CAUSE_SUPERVISOR_SOFTWARE_INT = 32'h8000_0001;
  localparam logic [31:0] CAUSE_MACHINE_SOFTWARE_INT    = 32'h8000_0003;
  localparam logic [31:0] CAUSE_SUPERVISOR_TIMER_INT    = 32'h8000_0005;
  localparam logic [31:0] CAUSE_MACHINE_TIMER_INT       = 32'h8000_0007;
  localparam logic [31:0] CAUSE_SUPERVISOR_EXTERNAL_INT = 32'h8000_0009;
  localparam logic [31:0] CAUSE_MACHINE_EXTERNAL_INT    = 32'h8000_000B;

endpackage
