// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Eoghain Gray

// Genesys 2 bring-up step B: the RV32IMA core + a small on-chip LUTRAM,
// no DDR3/MIG7 yet, no real UART pins yet -- deliberately isolates "does
// the core itself work on this board" from both of those bigger, separate
// risks.
//
// UART is instantiated for module-set parity but tx/rx are NOT wired to
// real pins yet: Genesys 2 has no hard UART IP -- uart.sv is only a
// byte-level 16550 register model (see rtl/periph/uart.sv's own header),
// not a real serializer/deserializer. rtl/bridge/uart_phy.sv provides
// that PHY and is wired in starting with fpga/genesys2_top_uart.sv; this
// file predates it and deliberately isolates the core+LUTRAM bring-up
// step on its own.
//
// Clock: plain synchronous /10 divider off the 200 MHz LVDS sysclk ->
// 20 MHz core clock, NOT an MMCM -- see genesys2_blink.sv's header for why
// (the KU3P's MMCME4_BASE LOCKED-never-asserts lesson; no reason to accept
// that risk before the simplest path is confirmed on real hardware).
// Reset: cpu_resetn pushbutton (active-low), 2-flop synchronized into the
// clk_core domain.
module genesys2_top_min #(
  parameter int MEM_WORDS    = 512,           // 2 KB unified program memory
  parameter logic [31:0] GPIO_ADDR  = 32'hFFFF_FFF0,
  parameter logic [31:0] CLINT_BASE = 32'h0200_0000,
  parameter logic [31:0] PLIC_BASE  = 32'h0C00_0000,
  parameter logic [31:0] UART_BASE  = 32'h1000_0000
)(
  input  logic sysclk_p,
  input  logic sysclk_n,
  input  logic cpu_resetn,
  output logic [7:0] led
);

  // =========================================================================
  // Clocking: 200 MHz LVDS in -> plain /10 divider -> 20 MHz clk_core.
  // =========================================================================
  logic clk_200;
  IBUFDS u_ibufds (.I(sysclk_p), .IB(sysclk_n), .O(clk_200));

  logic [2:0] div_cnt;
  logic       clk_core_toggle, clk_core;

  always_ff @(posedge clk_200) begin
    if (div_cnt == 3'd4) begin
      div_cnt         <= 3'd0;
      clk_core_toggle <= ~clk_core_toggle;
    end else begin
      div_cnt <= div_cnt + 3'd1;
    end
  end

  BUFG u_bufg_core (.I(clk_core_toggle), .O(clk_core));

  // =========================================================================
  // Reset synchronizer -- 2-flop, clk_core domain.
  // =========================================================================
  logic [1:0] resetn_sync;
  logic       rst_n;
  always_ff @(posedge clk_core) resetn_sync <= {resetn_sync[0], cpu_resetn};
  assign rst_n = resetn_sync[1];

  // =========================================================================
  // CPU + caches
  // =========================================================================
  logic [31:0] imem_addr, imem_data;
  logic        imem_stall;
  logic        imem_req_hold;
  logic        imem_fence;

  logic [31:0] dmem_addr, dmem_wdata, dmem_rdata;
  logic [3:0]  dmem_wmask;
  logic        dmem_wen, dmem_ren, dmem_stall;

  logic clint_mtip, clint_msip_irq, plic_meip, plic_seip, uart_irq;

  cpu #(.PC_RESET(32'h8000_0000)) u_cpu (
    .clk        (clk_core),
    .rst_n      (rst_n),
    .imem_addr  (imem_addr),
    .imem_data  (imem_data),
    .imem_req_hold (imem_req_hold),
    .imem_fence (imem_fence),
    .dmem_addr  (dmem_addr),
    .dmem_wdata (dmem_wdata),
    .dmem_wmask (dmem_wmask),
    .dmem_wen   (dmem_wen),
    .dmem_ren   (dmem_ren),
    .dmem_rdata (dmem_rdata),
    .dmem_stall (dmem_stall),
    .imem_stall (imem_stall),
    .irq_mtip   (clint_mtip),
    .irq_meip   (plic_meip),
    .irq_msip   (clint_msip_irq),
    .irq_seip   (plic_seip)
  );

  // -------------------------------------------------------------------------
  // MMIO address decoder -- sits between the CPU's dmem port and the dcache.
  // -------------------------------------------------------------------------
  logic [31:0] ram_addr, ram_wdata, ram_rdata;
  logic [3:0]  ram_wmask;
  logic        ram_wen, ram_ren, ram_stall;

  logic [31:0] clint_addr, clint_wdata, clint_rdata;
  logic [3:0]  clint_wmask;
  logic        clint_wen, clint_ren;
  logic [31:0] plic_addr, plic_wdata, plic_rdata;
  logic [3:0]  plic_wmask;
  logic        plic_wen, plic_ren;
  logic [31:0] uart_addr, uart_wdata, uart_rdata;
  logic [3:0]  uart_wmask;
  logic        uart_wen, uart_ren;

  mmio_decoder #(
    .CLINT_BASE(CLINT_BASE), .PLIC_BASE(PLIC_BASE), .UART_BASE(UART_BASE)
  ) u_mmio_decoder (
    .cpu_addr    (dmem_addr),
    .cpu_wdata   (dmem_wdata),
    .cpu_wmask   (dmem_wmask),
    .cpu_wen     (dmem_wen),
    .cpu_ren     (dmem_ren),
    .cpu_rdata   (dmem_rdata),
    .cpu_stall   (dmem_stall),
    .ram_addr    (ram_addr),
    .ram_wdata   (ram_wdata),
    .ram_wmask   (ram_wmask),
    .ram_wen     (ram_wen),
    .ram_ren     (ram_ren),
    .ram_rdata   (ram_rdata),
    .ram_stall   (ram_stall),
    .clint_addr  (clint_addr),
    .clint_wdata (clint_wdata),
    .clint_wmask (clint_wmask),
    .clint_wen   (clint_wen),
    .clint_ren   (clint_ren),
    .clint_rdata (clint_rdata),
    .plic_addr   (plic_addr),
    .plic_wdata  (plic_wdata),
    .plic_wmask  (plic_wmask),
    .plic_wen    (plic_wen),
    .plic_ren    (plic_ren),
    .plic_rdata  (plic_rdata),
    .uart_addr   (uart_addr),
    .uart_wdata  (uart_wdata),
    .uart_wmask  (uart_wmask),
    .uart_wen    (uart_wen),
    .uart_ren    (uart_ren),
    .uart_rdata  (uart_rdata)
  );

  clint #(.BASE_ADDR(CLINT_BASE)) u_clint (
    .clk      (clk_core),
    .rst_n    (rst_n),
    .addr     (clint_addr),
    .wdata    (clint_wdata),
    .wmask    (clint_wmask),
    .wen      (clint_wen),
    .ren      (clint_ren),
    .rdata    (clint_rdata),
    .mtip     (clint_mtip),
    .msip_irq (clint_msip_irq)
  );

  plic #(.BASE_ADDR(PLIC_BASE)) u_plic (
    .clk         (clk_core),
    .rst_n       (rst_n),
    .addr        (plic_addr),
    .wdata       (plic_wdata),
    .wmask       (plic_wmask),
    .wen         (plic_wen),
    .ren         (plic_ren),
    .rdata       (plic_rdata),
    .irq_source1 (uart_irq),
    .meip        (plic_meip),
    .seip        (plic_seip)
  );

  // tx_valid/tx_data/rx_inject intentionally left unconnected -- see module
  // header. uart_phy.sv wiring is the next step, not this one.
  uart #(.BASE_ADDR(UART_BASE)) u_uart (
    .clk             (clk_core),
    .rst_n           (rst_n),
    .addr            (uart_addr),
    .wdata           (uart_wdata),
    .wmask           (uart_wmask),
    .wen             (uart_wen),
    .ren             (uart_ren),
    .rdata           (uart_rdata),
    .tx_valid        (),
    .tx_data         (),
    .tx_busy         (1'b0),          // no uart_phy in this design yet
    .rx_inject_valid (1'b0),
    .rx_inject_data  (8'h0),
    .irq             (uart_irq)
  );

  logic [31:0] icmem_addr, icmem_rdata;
  logic        icmem_ren;

  // SETS=16: icache/dcache use plain
  // behavioral arrays, never validated at a large SETS count for real
  // synthesis (blows FF/MUXF8 budget). 16 is ample for a tiny bring-up
  // program.
  icache #(.SETS(16), .WORDS_PER_LINE(4)) u_icache (
    .clk        (clk_core),
    .rst_n      (rst_n),
    .cpu_addr   (imem_addr),
    .cpu_rdata  (imem_data),
    .cache_stall(imem_stall),
    .req_hold   (imem_req_hold),
    .fence_i    (imem_fence),
    .mem_addr   (icmem_addr),
    .mem_ren    (icmem_ren),
    .mem_rdata  (icmem_rdata),
    .mem_ready  (1'b1)          // LUTRAM below is zero-latency (combinational)
  );

  logic [31:0] cmem_addr, cmem_wdata, cmem_rdata;
  logic [3:0]  cmem_wmask;
  logic        cmem_wen, cmem_ren;

  dcache #(.SETS(16), .WORDS_PER_LINE(4)) u_dcache (
    .clk        (clk_core),
    .rst_n      (rst_n),
    .cpu_addr   (ram_addr),
    .cpu_wdata  (ram_wdata),
    .cpu_wmask  (ram_wmask),
    .cpu_wen    (ram_wen),
    .cpu_ren    (ram_ren),
    .cpu_rdata  (ram_rdata),
    .cache_stall(ram_stall),
    .mem_addr   (cmem_addr),
    .mem_wdata  (cmem_wdata),
    .mem_wmask  (cmem_wmask),
    .mem_wen    (cmem_wen),
    .mem_ren    (cmem_ren),
    .mem_rdata  (cmem_rdata),
    .mem_ready  (1'b1)          // LUTRAM below is zero-latency (combinational)
  );

  // =========================================================================
  // Unified program memory: true dual-port LUTRAM via XPM_MEMORY_TDPRAM.
  // A plain behavioral array with two independent async read ports makes
  // Vivado's RTL memory-inference heuristic fall back to a full per-bit mux
  // tree (>10 GB, never finishes) -- XPM guarantees LUTRAM mapping instead.
  // MEMORY_INIT_FILE reuses the existing sw/blink.mem test program
  // (identical GPIO_ADDR convention, zero new software needed for this
  // first core test) -- only its low 8 (of the 6 it actually writes) bits
  // matter here since this board has 8 plain LEDs.
  // =========================================================================
  localparam int IDX_BITS = $clog2(MEM_WORDS);

  logic gpio_wen;
  assign gpio_wen = cmem_wen && (cmem_addr == GPIO_ADDR);

  logic [IDX_BITS-1:0] icmem_idx, cmem_idx;
  assign icmem_idx = icmem_addr[IDX_BITS+1:2];
  assign cmem_idx  = cmem_addr[IDX_BITS+1:2];

  logic [3:0] mem_wea;
  assign mem_wea = (cmem_wen && !gpio_wen) ? cmem_wmask : 4'b0000;

  xpm_memory_tdpram #(
    .ADDR_WIDTH_A        (IDX_BITS),
    .ADDR_WIDTH_B        (IDX_BITS),
    .BYTE_WRITE_WIDTH_A  (8),
    .BYTE_WRITE_WIDTH_B  (32),
    .CLOCKING_MODE       ("common_clock"),
    .ECC_MODE            ("no_ecc"),
    .MEMORY_INIT_FILE    ("sw/blink.mem"),
    .MEMORY_PRIMITIVE    ("distributed"),
    .MEMORY_SIZE         (MEM_WORDS * 32),
    .READ_DATA_WIDTH_A   (32),
    .READ_DATA_WIDTH_B   (32),
    .READ_LATENCY_A      (0),
    .READ_LATENCY_B      (0),
    .WRITE_DATA_WIDTH_A  (32),
    .WRITE_DATA_WIDTH_B  (32),
    .WRITE_MODE_A        ("read_first"),
    .WRITE_MODE_B        ("read_first")
  ) u_mem (
    .clka   (clk_core), .rsta (1'b0), .ena (1'b1), .regcea (1'b1),
    .wea    (mem_wea), .addra (cmem_idx), .dina (cmem_wdata), .douta (cmem_rdata),
    .injectsbiterra (1'b0), .injectdbiterra (1'b0), .sbiterra (), .dbiterra (),

    .clkb   (clk_core), .rstb (1'b0), .enb (1'b1), .regceb (1'b1),
    .web    (1'b0), .addrb (icmem_idx), .dinb (32'b0), .doutb (icmem_rdata),
    .injectsbiterrb (1'b0), .injectdbiterrb (1'b0), .sbiterrb (), .dbiterrb (),
    .sleep  (1'b0)
  );

  // =========================================================================
  // LED GPIO register -- any store to GPIO_ADDR
  // =========================================================================
  logic [7:0] led_reg;

  always_ff @(posedge clk_core or negedge rst_n) begin
    if (!rst_n) led_reg <= 8'b0;
    else if (gpio_wen) led_reg <= cmem_wdata[7:0];
  end

  assign led = led_reg;

endmodule
