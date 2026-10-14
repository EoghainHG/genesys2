// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Eoghain Gray

module regfile (
  input  logic        clk,
  input  logic        we,
  input  logic [4:0]  rs1_addr,
  input  logic [4:0]  rs2_addr,
  input  logic [4:0]  rd_addr,
  input  logic [31:0] rd_data,
  output logic [31:0] rs1_data,
  output logic [31:0] rs2_data
);

  logic [31:0] regs [0:31];

  // x0 hardwired to zero; bypass WB write when WB and ID read same register
  assign rs1_data = (rs1_addr == 5'b0) ? 32'b0 :
                    (we && rd_addr == rs1_addr && rd_addr != 5'b0) ? rd_data : regs[rs1_addr];
  assign rs2_data = (rs2_addr == 5'b0) ? 32'b0 :
                    (we && rd_addr == rs2_addr && rd_addr != 5'b0) ? rd_data : regs[rs2_addr];

  always_ff @(posedge clk) begin
    if (we && (rd_addr != 5'b0))
      regs[rd_addr] <= rd_data;
  end

endmodule
