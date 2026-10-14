// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Eoghain Gray

// Genesys 2 bring-up: genesys2_top_ddr.sv (proven, unchanged in its own
// right -- CPU + caches + CLINT/PLIC/UART + real DDR3) plus spi_master.sv
// wired to the board's native SD card slot pins for the first time on real
// hardware. New top level rather than an in-place edit of genesys2_top_ddr.sv,
// per this project's own staged-risk pattern -- the proven DDR/CPU/UART
// path stays untouched and independently
// reusable if this file's SD wiring ever needs debugging.
//
// SD pins (confirmed against Digilent's
// own board_files/genesys2/H/part0_pins.xml, which labels these same four
// pins sd_sclk_i/sd_mosi_i/sd_miso_i/sd_ss_i -- i.e. Digilent's own board
// file already treats this slot in SPI terms, not just repurposed 4-bit
// SDIO pins):
//   sd_sclk (R28) -> spi_sclk (output)
//   sd_cmd  (R29) -> spi_mosi (output)
//   sd_d0   (R26) -> spi_miso (input)
//   sd_d3   (T30) -> spi_cs_n (output)
// sd_d1/sd_d2 (R30/P29, DAT1/DAT2) are deliberately left unconnected -- SPI
// mode only ever needs these four wires, real SD cards carry their own weak
// pull-ups on the unused DAT lines per spec, and Digilent's own SPI-labeled
// pin set (above) doesn't include them either. sd_cd (P28) is also left
// unconnected -- not needed for the driver's init/read/write sequence.
//
// sd_reset (AE24) is NOT optional, unlike the above -- confirmed via the
// official Genesys 2 Reference Manual's "MicroSD Slot" section (2026-09-06,
// found only after extensive real-hardware debugging of an otherwise
// inexplicable intermittent SD failure pattern): "The on-board Auxiliary
// Function microcontroller shares the SD card bus with the FPGA... Once a
// bit file is downloaded to the FPGA (from any source), the microcontroller
// powers off the SD slot and relinquishes control of the bus. The FPGA
// design will find the SD card in an unpowered state... the SD_RESET signal
// needs to be actively driven low by the FPGA to power the microSD card
// slot." Without this, the card runs on whatever unstable/residual power
// state the microcontroller's own power-down left behind -- which matches
// every symptom seen before this fix exactly (intermittent CMD0 failures,
// one early success before repeated failures, read working while the more
// power-sensitive write direction didn't, reseating the card "helping"
// temporarily). Tied permanently low here (asserted, per the manual) --
// this project has no reason to ever power off the slot once running.
module genesys2_top_sd #(
  parameter logic [31:0] GPIO_ADDR  = 32'hFFFF_FFF0,
  parameter logic [31:0] CLINT_BASE = 32'h0200_0000,
  parameter logic [31:0] PLIC_BASE  = 32'h0C00_0000,
  parameter logic [31:0] UART_BASE  = 32'h1000_0000,
  parameter logic [31:0] SPI_BASE   = 32'h1000_2000,
  parameter logic [31:0] I2C_BASE   = 32'h1000_3000
)(
  input  logic sysclk_p,
  input  logic sysclk_n,
  input  logic cpu_resetn,
  output logic [7:0] led,
  output logic uart_rx_out,   // FPGA output -> bridge RX (this project's UART TX)
  input  logic uart_tx_in,    // FPGA input  <- bridge TX (this project's UART RX)

  output logic sd_sclk,
  output logic sd_cmd,
  input  logic sd_d0,
  output logic sd_d3,
  output logic sd_reset,

  // System I2C (2026-09-07): the Genesys 2's onboard INA219 power-monitor
  // bus (six chips, one per main rail, VCC3V3 among them -- see
  // Digilent's board_files/genesys2/H/part0_pins.xml, pins 71/72,
  // scl_i/sda_i at AE30/AF30) -- added to read real voltage data during a
  // CMD24 write attempt as a software alternative to an oscilloscope, per
  // the SD-over-SPI power-margin investigation.
  inout  wire i2c_scl,
  inout  wire i2c_sda,

  output logic [14:0] ddr3_addr,
  output logic [2:0]  ddr3_ba,
  output logic        ddr3_cas_n,
  output logic [0:0]  ddr3_ck_n,
  output logic [0:0]  ddr3_ck_p,
  output logic [0:0]  ddr3_cke,
  output logic [0:0]  ddr3_cs_n,
  output logic [3:0]  ddr3_dm,
  inout  wire  [31:0] ddr3_dq,
  inout  wire  [3:0]  ddr3_dqs_n,
  inout  wire  [3:0]  ddr3_dqs_p,
  output logic [0:0]  ddr3_odt,
  output logic        ddr3_ras_n,
  output logic        ddr3_reset_n,
  output logic        ddr3_we_n
);

  logic ui_clk, ui_clk_sync_rst, init_calib_complete, mmcm_locked;

  // clk_core: same /4 (~56.26MHz) divider genesys2_top_ddr.sv already
  // proved (see that file's own header for the /1, /6, /4 history) --
  // unchanged here, this file adds a peripheral, not a clocking change.
  localparam int DIVIDE_BY = 4;
  localparam int HALF_DIV  = DIVIDE_BY / 2;
  localparam int CLK_CORE_HZ = 225_047_064 / DIVIDE_BY;

  logic [2:0] div_cnt;
  logic       clk_core_toggle, clk_core;

  always_ff @(posedge ui_clk or posedge ui_clk_sync_rst) begin
    if (ui_clk_sync_rst) begin
      div_cnt         <= '0;
      clk_core_toggle <= 1'b0;
    end else if (div_cnt == 3'(HALF_DIV - 1)) begin
      div_cnt         <= '0;
      clk_core_toggle <= ~clk_core_toggle;
    end else begin
      div_cnt <= div_cnt + 3'd1;
    end
  end

  BUFG u_bufg_core (.I(clk_core_toggle), .O(clk_core));

  // -------------------------------------------------------------------------
  // Two independent reset domains -- see genesys2_top_ddr.sv's own header
  // for the full rationale, unchanged here.
  // -------------------------------------------------------------------------
  logic [1:0] calib_sync;
  logic [1:0] resetn_sync;
  logic       axi_infra_rst_n;
  logic       cpu_rst_n;

  always_ff @(posedge clk_core) begin
    calib_sync  <= {calib_sync[0], init_calib_complete};
    resetn_sync <= {resetn_sync[0], cpu_resetn};
  end
  assign axi_infra_rst_n = calib_sync[1];

  localparam int DEBOUNCE_CYCLES = CLK_CORE_HZ / 50;
  localparam int DEBOUNCE_CNT_W  = $clog2(DEBOUNCE_CYCLES);

  logic                       resetn_debounced;
  logic [DEBOUNCE_CNT_W-1:0]  debounce_cnt;

  always_ff @(posedge clk_core or negedge axi_infra_rst_n) begin
    if (!axi_infra_rst_n) begin
      resetn_debounced <= 1'b1;
      debounce_cnt     <= '0;
    end else if (resetn_sync[1] != resetn_debounced) begin
      if (debounce_cnt == DEBOUNCE_CNT_W'(DEBOUNCE_CYCLES - 1)) begin
        resetn_debounced <= resetn_sync[1];
        debounce_cnt     <= '0;
      end else begin
        debounce_cnt <= debounce_cnt + 1'b1;
      end
    end else begin
      debounce_cnt <= '0;
    end
  end

  logic cpu_held_toggle;
  logic resetn_debounced_prev;

  always_ff @(posedge clk_core or negedge axi_infra_rst_n) begin
    if (!axi_infra_rst_n) begin
      cpu_held_toggle       <= 1'b1;
      resetn_debounced_prev <= 1'b1;
    end else begin
      resetn_debounced_prev <= resetn_debounced;
      if (resetn_debounced_prev && !resetn_debounced) begin
        cpu_held_toggle <= ~cpu_held_toggle;
      end
    end
  end

  assign cpu_rst_n = calib_sync[1] & ~cpu_held_toggle;

  // =========================================================================
  // CPU + caches -- unchanged from genesys2_top_ddr.sv.
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
    .rst_n      (cpu_rst_n),
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
  logic [31:0] spi_addr, spi_wdata, spi_rdata;
  logic [3:0]  spi_wmask;
  logic        spi_wen, spi_ren;
  logic [31:0] i2c_addr, i2c_wdata, i2c_rdata;
  logic [3:0]  i2c_wmask;
  logic        i2c_wen, i2c_ren;

  mmio_decoder #(
    .CLINT_BASE(CLINT_BASE), .PLIC_BASE(PLIC_BASE), .UART_BASE(UART_BASE),
    .SPI_BASE(SPI_BASE), .I2C_BASE(I2C_BASE)
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
    .uart_rdata  (uart_rdata),
    .spi_addr    (spi_addr),
    .spi_wdata   (spi_wdata),
    .spi_wmask   (spi_wmask),
    .spi_wen     (spi_wen),
    .spi_ren     (spi_ren),
    .spi_rdata   (spi_rdata),
    .i2c_addr    (i2c_addr),
    .i2c_wdata   (i2c_wdata),
    .i2c_wmask   (i2c_wmask),
    .i2c_wen     (i2c_wen),
    .i2c_ren     (i2c_ren),
    .i2c_rdata   (i2c_rdata)
  );

  i2c_gpio #(.BASE_ADDR(I2C_BASE)) u_i2c_gpio (
    .clk    (clk_core),
    .rst_n  (cpu_rst_n),
    .addr   (i2c_addr),
    .wdata  (i2c_wdata),
    .wmask  (i2c_wmask),
    .wen    (i2c_wen),
    .ren    (i2c_ren),
    .rdata  (i2c_rdata),
    .scl    (i2c_scl),
    .sda    (i2c_sda)
  );

  clint #(.BASE_ADDR(CLINT_BASE)) u_clint (
    .clk      (clk_core),
    .rst_n    (cpu_rst_n),
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
    .rst_n       (cpu_rst_n),
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

  logic uart_tx_valid, uart_tx_busy;
  logic [7:0] uart_tx_data;
  logic uart_rx_inject_valid;
  logic [7:0] uart_rx_inject_data;
  logic uart_dr_status;

  uart #(.BASE_ADDR(UART_BASE)) u_uart (
    .clk             (clk_core),
    .rst_n           (cpu_rst_n),
    .addr            (uart_addr),
    .wdata           (uart_wdata),
    .wmask           (uart_wmask),
    .wen             (uart_wen),
    .ren             (uart_ren),
    .rdata           (uart_rdata),
    .tx_valid        (uart_tx_valid),
    .tx_data         (uart_tx_data),
    .tx_busy         (uart_tx_busy),
    .rx_inject_valid (uart_rx_inject_valid),
    .rx_inject_data  (uart_rx_inject_data),
    .irq             (uart_irq),
    .dr_status       (uart_dr_status)
  );

  uart_phy #(.CLK_FREQ_HZ(CLK_CORE_HZ)) u_uart_phy (
    .clk             (clk_core),
    .rst_n           (cpu_rst_n),
    .tx_valid        (uart_tx_valid),
    .tx_data         (uart_tx_data),
    .tx_busy         (uart_tx_busy),
    .rx_inject_valid (uart_rx_inject_valid),
    .rx_inject_data  (uart_rx_inject_data),
    .dr_status       (uart_dr_status),
    .uart_tx_pin     (uart_rx_out),
    .uart_rx_pin     (uart_tx_in)
  );

  // =========================================================================
  // SD card over SPI -- first real-hardware wiring.
  // spi_master.sv's own register interface
  // (SPI_TXRX/SPI_STATUS/SPI_CTRL/SPI_CLKDIV) already sim-verified against
  // sim/spi-sd-tests/sd_card_model.sv; this is just the physical pin wiring.
  // =========================================================================
  // See this module's header for why this is mandatory, not optional.
  assign sd_reset = 1'b0;

  spi_master #(.BASE_ADDR(SPI_BASE)) u_spi_master (
    .clk      (clk_core),
    .rst_n    (cpu_rst_n),
    .addr     (spi_addr),
    .wdata    (spi_wdata),
    .wmask    (spi_wmask),
    .wen      (spi_wen),
    .ren      (spi_ren),
    .rdata    (spi_rdata),
    .spi_sclk (sd_sclk),
    .spi_mosi (sd_cmd),
    .spi_miso (sd_d0),
    .spi_cs_n (sd_d3)
  );

  logic [31:0] icmem_addr, icmem_rdata;
  logic        icmem_ren;

  icache #(.SETS(16), .WORDS_PER_LINE(4)) u_icache (
    .clk        (clk_core),
    .rst_n      (cpu_rst_n),
    .cpu_addr   (imem_addr),
    .cpu_rdata  (imem_data),
    .cache_stall(imem_stall),
    .req_hold   (imem_req_hold),
    .fence_i    (imem_fence),
    .mem_addr   (icmem_addr),
    .mem_ren    (icmem_ren),
    .mem_rdata  (icmem_rdata),
    .mem_ready  (icache_mem_ready)
  );

  logic [31:0] cmem_addr, cmem_wdata, cmem_rdata;
  logic [3:0]  cmem_wmask;
  logic        cmem_wen, cmem_ren;

  dcache #(.SETS(16), .WORDS_PER_LINE(4)) u_dcache (
    .clk        (clk_core),
    .rst_n      (cpu_rst_n),
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
    .mem_ready  (dcache_mem_ready)
  );

  logic gpio_wen;
  assign gpio_wen = cmem_wen && (cmem_addr == GPIO_ADDR);

  logic [5:0] led_reg;
  always_ff @(posedge clk_core or negedge cpu_rst_n) begin
    if (!cpu_rst_n) led_reg <= 6'b0;
    else if (gpio_wen) led_reg <= cmem_wdata[5:0];
  end

  assign led[5:0] = led_reg;
  assign led[6]   = cpu_held_toggle;
  assign led[7]   = mmcm_locked;

  logic dcache_axi_wen, dcache_mem_ready, dcache_axi_ready;
  assign dcache_axi_wen  = cmem_wen && !gpio_wen;
  assign dcache_mem_ready = gpio_wen ? 1'b1 : dcache_axi_ready;

  logic icache_mem_ready;

  logic [31:0] axi_i_awaddr, axi_i_wdata, axi_i_araddr, axi_i_rdata;
  logic [3:0]  axi_i_wstrb;
  logic        axi_i_awvalid, axi_i_awready, axi_i_wvalid, axi_i_wready;
  logic [1:0]  axi_i_bresp;
  logic        axi_i_bvalid, axi_i_bready;
  logic        axi_i_arvalid, axi_i_arready;
  logic [1:0]  axi_i_rresp;
  logic        axi_i_rvalid, axi_i_rready;
  logic [2:0]  axi_i_awprot, axi_i_arprot;

  axi4lite_master #(.ADDR_OFFSET(32'h8000_0000)) u_axi_i (
    .clk        (clk_core),
    .rst_n      (axi_infra_rst_n),
    .mem_addr   (icmem_addr),
    .mem_wdata  (32'h0),
    .mem_wmask  (4'h0),
    .mem_wen    (1'b0),
    .mem_ren    (icmem_ren),
    .mem_rdata  (icmem_rdata),
    .mem_ready  (icache_mem_ready),
    .m_axi_awaddr (axi_i_awaddr), .m_axi_awprot (axi_i_awprot),
    .m_axi_awvalid(axi_i_awvalid), .m_axi_awready(axi_i_awready),
    .m_axi_wdata  (axi_i_wdata),  .m_axi_wstrb  (axi_i_wstrb),
    .m_axi_wvalid (axi_i_wvalid), .m_axi_wready (axi_i_wready),
    .m_axi_bresp  (axi_i_bresp),  .m_axi_bvalid (axi_i_bvalid),
    .m_axi_bready (axi_i_bready),
    .m_axi_araddr (axi_i_araddr), .m_axi_arprot (axi_i_arprot),
    .m_axi_arvalid(axi_i_arvalid),.m_axi_arready(axi_i_arready),
    .m_axi_rdata  (axi_i_rdata),  .m_axi_rresp  (axi_i_rresp),
    .m_axi_rvalid (axi_i_rvalid), .m_axi_rready (axi_i_rready)
  );

  logic [31:0] axi_d_awaddr, axi_d_wdata, axi_d_araddr, axi_d_rdata;
  logic [3:0]  axi_d_wstrb;
  logic        axi_d_awvalid, axi_d_awready, axi_d_wvalid, axi_d_wready;
  logic [1:0]  axi_d_bresp;
  logic        axi_d_bvalid, axi_d_bready;
  logic        axi_d_arvalid, axi_d_arready;
  logic [1:0]  axi_d_rresp;
  logic        axi_d_rvalid, axi_d_rready;
  logic [2:0]  axi_d_awprot, axi_d_arprot;

  axi4lite_master #(.ADDR_OFFSET(32'h8000_0000)) u_axi_d (
    .clk        (clk_core),
    .rst_n      (axi_infra_rst_n),
    .mem_addr   (cmem_addr),
    .mem_wdata  (cmem_wdata),
    .mem_wmask  (cmem_wmask),
    .mem_wen    (dcache_axi_wen),
    .mem_ren    (cmem_ren),
    .mem_rdata  (cmem_rdata),
    .mem_ready  (dcache_axi_ready),
    .m_axi_awaddr (axi_d_awaddr), .m_axi_awprot (axi_d_awprot),
    .m_axi_awvalid(axi_d_awvalid), .m_axi_awready(axi_d_awready),
    .m_axi_wdata  (axi_d_wdata),  .m_axi_wstrb  (axi_d_wstrb),
    .m_axi_wvalid (axi_d_wvalid), .m_axi_wready (axi_d_wready),
    .m_axi_bresp  (axi_d_bresp),  .m_axi_bvalid (axi_d_bvalid),
    .m_axi_bready (axi_d_bready),
    .m_axi_araddr (axi_d_araddr), .m_axi_arprot (axi_d_arprot),
    .m_axi_arvalid(axi_d_arvalid),.m_axi_arready(axi_d_arready),
    .m_axi_rdata  (axi_d_rdata),  .m_axi_rresp  (axi_d_rresp),
    .m_axi_rvalid (axi_d_rvalid), .m_axi_rready (axi_d_rready)
  );

  mig_bridge_wrapper u_mig_bridge (
    .DDR3_addr    (ddr3_addr),
    .DDR3_ba      (ddr3_ba),
    .DDR3_cas_n   (ddr3_cas_n),
    .DDR3_ck_n    (ddr3_ck_n),
    .DDR3_ck_p    (ddr3_ck_p),
    .DDR3_cke     (ddr3_cke),
    .DDR3_cs_n    (ddr3_cs_n),
    .DDR3_dm      (ddr3_dm),
    .DDR3_dq      (ddr3_dq),
    .DDR3_dqs_n   (ddr3_dqs_n),
    .DDR3_dqs_p   (ddr3_dqs_p),
    .DDR3_odt     (ddr3_odt),
    .DDR3_ras_n   (ddr3_ras_n),
    .DDR3_reset_n (ddr3_reset_n),
    .DDR3_we_n    (ddr3_we_n),

    .SYS_CLK_clk_p (sysclk_p),
    .SYS_CLK_clk_n (sysclk_n),
    .sys_rst       (1'b1),

    .clk_core         (clk_core),
    .clk_core_aresetn (axi_infra_rst_n),

    .init_calib_complete (init_calib_complete),
    .mmcm_locked          (mmcm_locked),
    .ui_clk               (ui_clk),
    .ui_clk_sync_rst      (ui_clk_sync_rst),

    .S_AXI_LITE_icache_awvalid (axi_i_awvalid),
    .S_AXI_LITE_icache_awaddr  (axi_i_awaddr),
    .S_AXI_LITE_icache_awlen   (8'h0),
    .S_AXI_LITE_icache_awsize  (3'h2),
    .S_AXI_LITE_icache_awburst (2'h1),
    .S_AXI_LITE_icache_awlock  (1'b0),
    .S_AXI_LITE_icache_awcache (4'h0),
    .S_AXI_LITE_icache_awprot  (axi_i_awprot),
    .S_AXI_LITE_icache_awqos   (4'h0),
    .S_AXI_LITE_icache_awready (axi_i_awready),
    .S_AXI_LITE_icache_wvalid  (axi_i_wvalid),
    .S_AXI_LITE_icache_wdata   (axi_i_wdata),
    .S_AXI_LITE_icache_wstrb   (axi_i_wstrb),
    .S_AXI_LITE_icache_wlast   (1'b1),
    .S_AXI_LITE_icache_wready  (axi_i_wready),
    .S_AXI_LITE_icache_bready  (axi_i_bready),
    .S_AXI_LITE_icache_bresp   (axi_i_bresp),
    .S_AXI_LITE_icache_bvalid  (axi_i_bvalid),
    .S_AXI_LITE_icache_arvalid (axi_i_arvalid),
    .S_AXI_LITE_icache_araddr  (axi_i_araddr),
    .S_AXI_LITE_icache_arlen   (8'h0),
    .S_AXI_LITE_icache_arsize  (3'h2),
    .S_AXI_LITE_icache_arburst (2'h1),
    .S_AXI_LITE_icache_arlock  (1'b0),
    .S_AXI_LITE_icache_arcache (4'h0),
    .S_AXI_LITE_icache_arprot  (axi_i_arprot),
    .S_AXI_LITE_icache_arqos   (4'h0),
    .S_AXI_LITE_icache_arready (axi_i_arready),
    .S_AXI_LITE_icache_rdata   (axi_i_rdata),
    .S_AXI_LITE_icache_rresp   (axi_i_rresp),
    .S_AXI_LITE_icache_rvalid  (axi_i_rvalid),
    .S_AXI_LITE_icache_rready  (axi_i_rready),

    .S_AXI_LITE_dcache_awvalid (axi_d_awvalid),
    .S_AXI_LITE_dcache_awaddr  (axi_d_awaddr),
    .S_AXI_LITE_dcache_awlen   (8'h0),
    .S_AXI_LITE_dcache_awsize  (3'h2),
    .S_AXI_LITE_dcache_awburst (2'h1),
    .S_AXI_LITE_dcache_awlock  (1'b0),
    .S_AXI_LITE_dcache_awcache (4'h0),
    .S_AXI_LITE_dcache_awprot  (axi_d_awprot),
    .S_AXI_LITE_dcache_awqos   (4'h0),
    .S_AXI_LITE_dcache_awready (axi_d_awready),
    .S_AXI_LITE_dcache_wvalid  (axi_d_wvalid),
    .S_AXI_LITE_dcache_wdata   (axi_d_wdata),
    .S_AXI_LITE_dcache_wstrb   (axi_d_wstrb),
    .S_AXI_LITE_dcache_wlast   (1'b1),
    .S_AXI_LITE_dcache_wready  (axi_d_wready),
    .S_AXI_LITE_dcache_bready  (axi_d_bready),
    .S_AXI_LITE_dcache_bresp   (axi_d_bresp),
    .S_AXI_LITE_dcache_bvalid  (axi_d_bvalid),
    .S_AXI_LITE_dcache_arvalid (axi_d_arvalid),
    .S_AXI_LITE_dcache_araddr  (axi_d_araddr),
    .S_AXI_LITE_dcache_arlen   (8'h0),
    .S_AXI_LITE_dcache_arsize  (3'h2),
    .S_AXI_LITE_dcache_arburst (2'h1),
    .S_AXI_LITE_dcache_arlock  (1'b0),
    .S_AXI_LITE_dcache_arcache (4'h0),
    .S_AXI_LITE_dcache_arprot  (axi_d_arprot),
    .S_AXI_LITE_dcache_arqos   (4'h0),
    .S_AXI_LITE_dcache_arready (axi_d_arready),
    .S_AXI_LITE_dcache_rdata   (axi_d_rdata),
    .S_AXI_LITE_dcache_rresp   (axi_d_rresp),
    .S_AXI_LITE_dcache_rvalid  (axi_d_rvalid),
    .S_AXI_LITE_dcache_rready  (axi_d_rready)
  );

`ifdef GENESYS2_ILA_DEBUG
  // Debug-only ILA (fpga/build_sd_ila.tcl creates the ila_0 IP; this define
  // is only set by that build script, never by build_sd.tcl). Investigates
  // CMD24 (WRITE_BLOCK)'s data-response-token timeout (checkpoint 13,
  // cmd24_notoken_fail) -- two independent software fixes
  // (an Nwr turnaround byte, and trying 0x00 instead of 0xFF for the dummy
  // CRC16) both left this checkpoint completely unchanged, pointing at
  // something only visible on the real wire.
  //
  // dbg_dataresp_marker: NOT a trigger derived from decoding the SPI pins
  // in RTL -- a full CMD24 transaction (command+variable-length R1 poll+
  // Nwr+start token+512 data bytes+CRC16) already runs to many thousands
  // of clk_core cycles at SPI_CLKDIV_DATA's ~14MHz bit rate, comfortably
  // past what a Basic-tier ILA's practical capture depth can span end to
  // end, and the poll loop that follows can run up to
  // MAX_DATARESP_POLLS=50000 iterations before giving up -- decoding SPI
  // bytes in RTL just to find the moment of interest would be needless
  // complexity for a one-shot investigation. Instead,
  // sw/sd-test/sd_init_read_write.S itself asserts this marker (a plain
  // GPIO/led_reg write, GPIO_ADDR bit 5 -- unused by this test otherwise)
  // the instant it finishes sending data+CRC and is about to start that
  // poll loop, giving the ILA a precise, software-controlled trigger right
  // at the boundary in question: "data+CRC just went out" -> "waiting for
  // the card's response."
  logic dbg_dataresp_marker;
  assign dbg_dataresp_marker = led_reg[5];

  ila_0 u_ila_dbg (
    .clk    (clk_core),
    .probe0 ({dbg_dataresp_marker, sd_reset, sd_d3, sd_d0, sd_cmd, sd_sclk})
  );
`endif

endmodule
