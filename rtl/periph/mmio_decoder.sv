// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Eoghain Gray

// Combinational address-range decoder/mux sitting between the CPU's dmem
// port and the dcache. Peripheral addresses are diverted here, before ever
// reaching the dcache, so MMIO registers are never cached (the dcache is a
// generic write-through cache that would otherwise happily cache a UART/
// PLIC register and serve stale data to a polling loop forever). RAM
// addresses pass through to the dcache/backing-memory side completely
// unchanged from today's behavior.
//
// All four destinations are modeled as combinational/single-cycle
// (no destination ever asserts a stall) — matches the RAM's own existing
// combinational-read behavior in tb_riscv.sv, so `any_stall` needs no
// changes for the peripheral path.
module mmio_decoder #(
  parameter logic [31:0] CLINT_BASE = 32'h0200_0000,
  parameter logic [31:0] CLINT_SIZE = 32'h0001_0000,
  parameter logic [31:0] PLIC_BASE  = 32'h0C00_0000,
  parameter logic [31:0] PLIC_SIZE  = 32'h0400_0000,
  parameter logic [31:0] UART_BASE  = 32'h1000_0000,
  parameter logic [31:0] UART_SIZE  = 32'h0000_1000,
  // SPI_BASE (2026-09-06, SD-card-over-SPI storage effort): sits well past
  // UART's own 4KB window and the sim-only RX_INJECT_ADDR just past it
  // (tb_riscv.sv, UART_BASE+0x1000) -- a real, separate 4KB window, not
  // sharing UART's.
  parameter logic [31:0] SPI_BASE   = 32'h1000_2000,
  parameter logic [31:0] SPI_SIZE   = 32'h0000_1000,
  // I2C_BASE (2026-09-07, INA219 power-monitor investigation): next 4KB
  // window past SPI's, same "separate window per peripheral" convention.
  parameter logic [31:0] I2C_BASE   = 32'h1000_3000,
  parameter logic [31:0] I2C_SIZE   = 32'h0000_1000
)(
  // CPU side (pre-cache)
  input  logic [31:0] cpu_addr,
  input  logic [31:0] cpu_wdata,
  input  logic [3:0]  cpu_wmask,
  input  logic        cpu_wen,
  input  logic        cpu_ren,
  output logic [31:0] cpu_rdata,
  output logic        cpu_stall,

  // RAM/dcache side — pass-through for every address not claimed below
  output logic [31:0] ram_addr,
  output logic [31:0] ram_wdata,
  output logic [3:0]  ram_wmask,
  output logic        ram_wen,
  output logic        ram_ren,
  input  logic [31:0] ram_rdata,
  input  logic        ram_stall,

  // CLINT side
  output logic [31:0] clint_addr,
  output logic [31:0] clint_wdata,
  output logic [3:0]  clint_wmask,
  output logic        clint_wen,
  output logic        clint_ren,
  input  logic [31:0] clint_rdata,

  // PLIC side
  output logic [31:0] plic_addr,
  output logic [31:0] plic_wdata,
  output logic [3:0]  plic_wmask,
  output logic        plic_wen,
  output logic        plic_ren,
  input  logic [31:0] plic_rdata,

  // UART side
  output logic [31:0] uart_addr,
  output logic [31:0] uart_wdata,
  output logic [3:0]  uart_wmask,
  output logic        uart_wen,
  output logic        uart_ren,
  input  logic [31:0] uart_rdata,

  // SPI side
  output logic [31:0] spi_addr,
  output logic [31:0] spi_wdata,
  output logic [3:0]  spi_wmask,
  output logic        spi_wen,
  output logic        spi_ren,
  input  logic [31:0] spi_rdata,

  // I2C side
  output logic [31:0] i2c_addr,
  output logic [31:0] i2c_wdata,
  output logic [3:0]  i2c_wmask,
  output logic        i2c_wen,
  output logic        i2c_ren,
  input  logic [31:0] i2c_rdata
);

  logic is_clint, is_plic, is_uart, is_spi, is_i2c, is_ram;
  assign is_clint = (cpu_addr >= CLINT_BASE) && (cpu_addr < CLINT_BASE + CLINT_SIZE);
  assign is_plic  = (cpu_addr >= PLIC_BASE)  && (cpu_addr < PLIC_BASE  + PLIC_SIZE);
  assign is_uart  = (cpu_addr >= UART_BASE)  && (cpu_addr < UART_BASE  + UART_SIZE);
  assign is_spi   = (cpu_addr >= SPI_BASE)   && (cpu_addr < SPI_BASE   + SPI_SIZE);
  assign is_i2c   = (cpu_addr >= I2C_BASE)   && (cpu_addr < I2C_BASE   + I2C_SIZE);
  // Default/fallthrough — preserves today's behavior for every address the
  // existing riscv-tests/priv-tests/mmu-tests regression touches (all live
  // at 0x8000_0000+, none of which fall in any range above).
  assign is_ram = !is_clint && !is_plic && !is_uart && !is_spi && !is_i2c;

  assign ram_addr  = cpu_addr;
  assign ram_wdata = cpu_wdata;
  assign ram_wmask = cpu_wmask;
  assign ram_wen   = cpu_wen && is_ram;
  assign ram_ren   = cpu_ren && is_ram;

  assign clint_addr  = cpu_addr;
  assign clint_wdata = cpu_wdata;
  assign clint_wmask = cpu_wmask;
  assign clint_wen   = cpu_wen && is_clint;
  assign clint_ren   = cpu_ren && is_clint;

  assign plic_addr  = cpu_addr;
  assign plic_wdata = cpu_wdata;
  assign plic_wmask = cpu_wmask;
  assign plic_wen   = cpu_wen && is_plic;
  assign plic_ren   = cpu_ren && is_plic;

  assign uart_addr  = cpu_addr;
  assign uart_wdata = cpu_wdata;
  assign uart_wmask = cpu_wmask;
  assign uart_wen   = cpu_wen && is_uart;
  assign uart_ren   = cpu_ren && is_uart;

  assign spi_addr  = cpu_addr;
  assign spi_wdata = cpu_wdata;
  assign spi_wmask = cpu_wmask;
  assign spi_wen   = cpu_wen && is_spi;
  assign spi_ren   = cpu_ren && is_spi;

  assign i2c_addr  = cpu_addr;
  assign i2c_wdata = cpu_wdata;
  assign i2c_wmask = cpu_wmask;
  assign i2c_wen   = cpu_wen && is_i2c;
  assign i2c_ren   = cpu_ren && is_i2c;

  always_comb begin
    if (is_clint)      cpu_rdata = clint_rdata;
    else if (is_plic)  cpu_rdata = plic_rdata;
    else if (is_uart)  cpu_rdata = uart_rdata;
    else if (is_spi)   cpu_rdata = spi_rdata;
    else if (is_i2c)   cpu_rdata = i2c_rdata;
    else               cpu_rdata = ram_rdata;
  end

  assign cpu_stall = is_ram ? ram_stall : 1'b0;

endmodule
