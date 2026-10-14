// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Eoghain Gray

// Genesys 2 bring-up step 2.5: the real Linux-target-in-waiting top level --
// the RV32 core + caches + CLINT/PLIC + real UART (from genesys2_top_uart.sv,
// unchanged) now backed by real DDR3 (via the mig_bridge block design,
// fpga/bd_build.tcl) instead of the on-chip LUTRAM. Confirmed prerequisites
// this depends on, both already proven on real hardware this project:
// genesys2_top_ddr_calib.sv (DDR3 PHY calibration itself) and
// genesys2_top_uart.sv (the CPU/cache/UART pipeline itself, previously
// backed by LUTRAM). This file is the first time those two proven pieces
// are combined.
//
// Two independent reset domains, not one -- this is the key architectural
// difference from every prior top level in this project:
//   - axi_infra_rst_n: gated ONLY on init_calib_complete. Drives the BD's
//     clk_core_aresetn input, which in turn resets SmartConnect AND
//     jtag_axi (see bd_build.tcl). This lets a JTAG-to-AXI-Master
//     transaction load a real program into DDR3 as soon as DDR3
//     calibrates, entirely independent of whether the CPU itself is still
//     held in reset.
//   - cpu_rst_n: gated on BOTH init_calib_complete AND cpu_resetn's own
//     debounced TOGGLE state (2026-09-03, replacing an earlier plain
//     hold-while-pressed level gate -- see the toggle logic's own header
//     comment below for why: a multi-MB OpenSBI/Linux JTAG-AXI load takes
//     tens of minutes, too long to physically hold a button the whole
//     time). One debounced press holds the CPU in reset -- creating the
//     same real window to load DDR3 via JTAG-AXI before the CPU fetches
//     its first instruction -- and the next debounced press releases it,
//     starting execution from whatever was just loaded at 0x8000_0000.
//     led[6] shows the current held/running state (see its own
//     assignment below), since a toggle's state isn't visible from the
//     button alone the way a held-down level was.
//
// Clocking (changed 2026-09-05):
// clk_core now runs DIRECTLY off MIG's ui_clk (~225MHz), no divider at all
// -- same direct-connect shortcut genesys2_top_ddr_calib.sv already proved
// closes cleanly (0 unconstrained_internal_endpoints, real WNS/WHS margin),
// now extended to the full CPU+DDR design for the first time. This was
// previously a plain /12 divider (~18.75MHz) specifically BECAUSE this
// design's CPU pipeline was assumed to need a slower clock than raw ui_clk
// -- worth re-examining now that this project has a full working Linux
// system to validate against (interactive shell, sustained real interrupt
// load) rather than only the narrow synchronous smoke tests available when
// that assumption was first made. If real hardware testing at full ui_clk
// rate ever regresses, reintroduce a divider here (a BUFG fed from a
// counter/toggle divider, as this file had until 2026-09-05) rather than
// assuming the direct-connect approach always works.
//
// The create_generated_clock this still needs (clk_core is a real generated
// clock as far as STA is concerned, even at divide-by-1) lives in a
// SEPARATE constraint file (fpga/genesys2_top_ddr_timing.xdc), added to
// the project with USED_IN_SYNTHESIS=false (see build_ddr.tcl) so it's
// applied post-synthesis/during implementation instead -- at plain
// synthesis time, mig_bridge_wrapper's internals are still an
// out-of-context black box and the pin this constraint sources from
// isn't resolvable yet (confirmed the hard way while building
// genesys2_top_ddr_calib.sv: "No valid object(s) found for '-source
// [get_pins u_mig_bridge/ui_clk]'", 16742 unconstrained endpoints).
module genesys2_top_ddr #(
  parameter logic [31:0] GPIO_ADDR  = 32'hFFFF_FFF0,
  parameter logic [31:0] CLINT_BASE = 32'h0200_0000,
  parameter logic [31:0] PLIC_BASE  = 32'h0C00_0000,
  parameter logic [31:0] UART_BASE  = 32'h1000_0000
)(
  input  logic sysclk_p,
  input  logic sysclk_n,
  input  logic cpu_resetn,
  output logic [7:0] led,
  output logic uart_rx_out,   // FPGA output -> bridge RX (this project's UART TX)
  input  logic uart_tx_in,    // FPGA input  <- bridge TX (this project's UART RX)

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

  // clk_core: parameterized synchronous divider off ui_clk (~225.047MHz).
  // DIVIDE_BY=1 (direct connect, no divider) was tried 2026-09-05 as this
  // project's most aggressive/most-informative first experiment -- see
  // this module's header comment -- and FAILED real timing badly (11,891
  // of 61,025 clk_core-domain endpoints violated setup, WNS=-7.695ns at
  // the 4.444ns period, implying a real critical path around 12ns). That
  // rules out running the CPU pipeline anywhere near ui_clk's native rate.
  // DIVIDE_BY=6 (~37.5MHz) was tried next and PASSED cleanly (0
  // unconstrained_internal_endpoints, WNS=+8.184ns, WHS=+0.049ns) --
  // verified end-to-end on real hardware (booted, interactive shell,
  // cat /proc/interrupts under real load). That +8.184ns margin at
  // 26.661ns implies the real critical path is closer to ~18.5ns than the
  // failed /1 attempt's distorted-under-impossible-pressure ~12ns
  // estimate suggested -- worth another push. DIVIDE_BY=4 (~56.3MHz,
  // 17.774ns period) is that next attempt: close enough to the ~18.5ns
  // estimate to have a real chance, genuinely uncertain either way. If
  // this fails, DIVIDE_BY=6 above is the proven fallback -- revert to it
  // rather than trying to split the difference blindly.
  localparam int DIVIDE_BY = 4;
  localparam int HALF_DIV  = DIVIDE_BY / 2;

  // CLK_CORE_HZ: real clk_core frequency, carried forward as a single named
  // constant (not re-derived/hand-copied in multiple places) specifically
  // because a stale hardcoded frequency constant caused a real, previously-
  // fixed bug (uart_phy defaulting to 20MHz while clk_core was actually
  // 18.754MHz, fixed 2026-09-03). Derived from ui_clk's own
  // real measured frequency (225,047,064.4Hz, from the /12 build's
  // 53.323ns clk_core period) divided by DIVIDE_BY -- confirm against this build's own
  // fresh timing report once available and correct if it differs
  // meaningfully.
  localparam int CLK_CORE_HZ = 225_047_064 / DIVIDE_BY;

  // Fixed 3-bit counter width (matching the original /12 code's own
  // `logic [2:0] div_cnt` exactly, headroom for HALF_DIV up to 8 i.e.
  // DIVIDE_BY up to 16) -- 2026-09-05 REAL BUG: an earlier version of this
  // block auto-sized div_cnt via `$clog2(HALF_DIV)-1:0` (2 bits for
  // HALF_DIV=3). That build's check_timing report showed 62,316
  // unconstrained_internal_endpoints and 20,143 registers with "no clock
  // driven by root clock pin: clk_core_toggle_reg/Q" -- i.e. clk_core
  // silently failed to propagate as a recognized clock to virtually the
  // entire CPU pipeline, even though the build otherwise reported "All
  // user specified timing constraints are met" (a real example of this
  // project's own established warning: a clean-looking report is not
  // trustworthy when unconstrained_internal_endpoints is nonzero). Root
  // cause not fully isolated, but reverting to the exact proven fixed-width
  // literal style (rather than a parameterized width) is the minimal,
  // lowest-risk fix -- re-verify unconstrained_internal_endpoints is 0
  // again before trusting any future divisor change here.
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
  // Two independent reset domains -- see module header.
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

  // -------------------------------------------------------------------------
  // cpu_resetn as a debounced TOGGLE, not a hold-while-pressed level
  // (2026-09-03). One debounced press holds the CPU in reset, the next
  // debounced press releases it -- added specifically because the
  // OpenSBI/Linux JTAG-AXI load (fpga/load_ddr_program_burst.tcl) takes
  // ~35-40 minutes, an unreasonable amount of time to physically hold a
  // button down. Two brief presses (arm, then release once loading
  // reports complete) replace one long continuous hold. Everything this
  // gates -- cpu_rst_n only, never axi_infra_rst_n/MIG's sys_rst -- is
  // unchanged from the prior level-based design; only how cpu_rst_n
  // itself gets derived from the button changes. See the reset-domain
  // memory lesson from this project's own history before touching this
  // block further: never let anything derived from this button gate
  // infrastructure (SmartConnect/jtag_axi/MIG) that the loading path
  // itself depends on staying live.
  //
  // Debounce: only accept resetn_sync[1]'s level once it's been stable
  // for DEBOUNCE_CYCLES in a row (~20ms real time, generous margin over
  // typical mechanical-switch bounce settling time) -- standard
  // counter-reset-on-change debounce, prevents one physical press from
  // registering as several toggles. Computed from CLK_CORE_HZ (not a
  // hardcoded cycle count) specifically because clk_core's real frequency
  // changed 12x (2026-09-05, direct ui_clk connect replacing the old /12
  // divider) -- the previous fixed 375_000-cycle count was tuned for
  // ~18.75MHz and would silently become a ~1.7ms debounce (12x too short,
  // real risk of one press registering as multiple toggles on a worn
  // switch) if left unscaled. Width sized for CLK_CORE_HZ/50 at up to
  // ~225MHz+ headroom rather than reusing the old 20-bit field, which would
  // silently wrap at this new cycle count.
  localparam int DEBOUNCE_CYCLES = CLK_CORE_HZ / 50;
  localparam int DEBOUNCE_CNT_W  = $clog2(DEBOUNCE_CYCLES);

  logic                       resetn_debounced;
  logic [DEBOUNCE_CNT_W-1:0]  debounce_cnt;

  always_ff @(posedge clk_core or negedge axi_infra_rst_n) begin
    if (!axi_infra_rst_n) begin
      resetn_debounced <= 1'b1; // idle (not pressed) -- safe power-up level
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

  // Toggle on each debounced falling edge (a clean button press --
  // cpu_resetn is active-low). Reset to 1'b1 (held) on axi_infra_rst_n
  // deassertion, i.e. every fresh bitstream program or DDR3
  // recalibration starts with the CPU held, requiring one explicit press
  // to release -- matches the prior design's safe default (a freshly
  // programmed board never auto-runs).
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
  // CPU + caches -- unchanged from genesys2_top_uart.sv, just on cpu_rst_n
  // instead of the old single rst_n.
  // =========================================================================
  logic [31:0] imem_addr, imem_data;
  logic        imem_stall;
  logic        imem_req_hold;
  logic        imem_fence;

  logic [31:0] dmem_addr, dmem_wdata, dmem_rdata;
  logic [3:0]  dmem_wmask;
  logic        dmem_wen, dmem_ren, dmem_stall;

  logic clint_mtip, clint_msip_irq, plic_meip, plic_seip, uart_irq;

`ifdef GENESYS2_ILA_DEBUG
  // Debug-only CPU forward-progress taps (2026-09-06, UART/PLIC interactive
  // freeze investigation). cpu.sv's dbg_id_ex_* ports
  // already existed (2026-07-30, nanoDLA capture round) but were never
  // wired up on Genesys 2 before now.
  logic [31:0] dbg_id_ex_pc;
  logic        dbg_id_ex_valid;
`endif

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
`ifdef GENESYS2_ILA_DEBUG
    ,
    .dbg_id_ex_pc     (dbg_id_ex_pc),
    .dbg_id_ex_valid  (dbg_id_ex_valid),
    .dbg_id_ex_branch (),
    .dbg_id_ex_jump   (),
    .dbg_id_ex_jumpr  ()
`endif
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

  // CLK_FREQ_HZ: real clk_core frequency (CLK_CORE_HZ, see its own
  // definition above) -- NOT the 20MHz uart_phy defaults to. A stale value
  // here (uart_phy left at its 20MHz default while clk_core was actually
  // 18.754MHz) caused a real, previously-fixed ~6.3% baud-rate error and
  // real UART byte corruption (fixed 2026-09-03) -- reusing the one
  // CLK_CORE_HZ constant here instead of a second hardcoded literal is
  // specifically to prevent that exact class of bug recurring now that
  // clk_core's real frequency has changed again (2026-09-05).
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

  logic [31:0] icmem_addr, icmem_rdata;
  logic        icmem_ren;

`ifdef GENESYS2_ILA_DEBUG
  // Debug-only ILA taps (an "open bug, NOT resolved" item --
  // the instruction-fetch corruption bug). icache's dbg_* ports already
  // existed for exactly this purpose but were never wired up before now.
  // See the u_ila_dbg instance near the end of this module.
  logic       ic_dbg_hit;
  logic [3:0] ic_dbg_addr_idx;
  logic       ic_dbg_miss_pulse;
  logic       ic_dbg_valid;
  logic       ic_dbg_tag_match;
`endif

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
`ifdef GENESYS2_ILA_DEBUG
    ,
    .dbg_hit        (ic_dbg_hit),
    .dbg_addr_idx   (ic_dbg_addr_idx),
    .dbg_miss_pulse (ic_dbg_miss_pulse),
    .dbg_valid      (ic_dbg_valid),
    .dbg_tag_match  (ic_dbg_tag_match)
`endif
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

  // =========================================================================
  // GPIO/LED interception -- any store to GPIO_ADDR from dcache's own
  // external mem port is diverted to led_reg instead of reaching the AXI
  // master at all (there's no real memory at GPIO_ADDR for MIG/DDR3 to
  // decode). Same pattern as genesys2_top_min.sv/genesys2_top_uart.sv,
  // just relocated from "before the LUTRAM" to "before axi4lite_master."
  // GPIO writes complete with immediate mem_ready (no real AXI
  // transaction needed); everything else waits on the real AXI master's
  // mem_ready.
  // =========================================================================
  logic gpio_wen;
  assign gpio_wen = cmem_wen && (cmem_addr == GPIO_ADDR);

  logic [5:0] led_reg;
  always_ff @(posedge clk_core or negedge cpu_rst_n) begin
    if (!cpu_rst_n) led_reg <= 6'b0;
    else if (gpio_wen) led_reg <= cmem_wdata[5:0];
  end

  // led[7]=mmcm_locked: always-on board-alive indicator, harmless to keep.
  // led[6]=cpu_held_toggle (2026-09-03): the debounced-toggle reset's own
  // visible status -- unlike a hold-while-pressed button, a toggle's
  // state isn't apparent from the button alone, so this LED is the only
  // way to tell "CPU is currently held" (lit) from "CPU is running" (off)
  // at a glance, which matters most right before releasing after a long
  // (~35-40 minute) JTAG-AXI load: confirm this LED is lit before
  // starting the load, and use it (not memory/guesswork) to know the CPU
  // is still safely held throughout. Replaces the prior temporary
  // axi_infra_rst_n debug tap here (that bug -- jtag_axi reads returning
  // a canned 0xdec0dee3 DECERR sentinel -- was root-caused and fixed
  // 2026-09-02, no longer needs a dedicated LED). led_reg itself is only
  // 6 bits wide (a GPIO store only ever sets cmem_wdata[5:0]) -- led[7:6]
  // have always been permanent status indicators, never GPIO-writable,
  // unchanged by this edit.
  assign led[5:0] = led_reg;
  assign led[6]   = cpu_held_toggle;
  assign led[7]   = mmcm_locked;

  logic dcache_axi_wen, dcache_mem_ready, dcache_axi_ready;
  assign dcache_axi_wen  = cmem_wen && !gpio_wen;
  assign dcache_mem_ready = gpio_wen ? 1'b1 : dcache_axi_ready;

  // =========================================================================
  // AXI4-Lite masters -- icache (read-only) and dcache -> SmartConnect ->
  // MIG. ADDR_OFFSET(32'h8000_0000) because this core's RAM/PC_RESET
  // convention is 0x8000_0000-based while MIG's AXI window is 0-based.
  // -------------------------------------------------------------------------
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

`ifdef GENESYS2_ILA_DEBUG
  // Debug-only ILA taps -- axi4lite_master's dbg_* ports, wired up here
  // for real-hardware hang debugging.
  logic [2:0]  axi_i_dbg_state;
  logic [13:0] axi_i_dbg_txn_count;
`endif

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
`ifdef GENESYS2_ILA_DEBUG
    ,
    .dbg_state     (axi_i_dbg_state),
    .dbg_txn_count (axi_i_dbg_txn_count)
`endif
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

  // =========================================================================
  // mig_bridge block design wrapper (fpga/bd_build.tcl) -- MIG7 DDR3 +
  // SmartConnect (icache, dcache, jtag_axi) + jtag_axi itself, all
  // BD-internal except the ports below.
  // =========================================================================
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
    // Deliberately NOT cpu_resetn -- MIG's sys_rst must stay independent
    // of the CPU-hold protocol (hold cpu_resetn during JTAG-AXI DDR3
    // loading, release once loaded). If sys_rst were tied to cpu_resetn,
    // holding the button would also hold MIG itself in reset, so DDR3
    // would never calibrate and init_calib_complete (which axi_infra_rst_n
    // depends on) would never assert -- the AXI-loading path would hang
    // forever while held, exactly the moment it needs to be usable. A
    // fresh bitstream programming already resets everything MIG needs, so
    // sys_rst (ACTIVE LOW) is tied permanently deasserted here. Caught
    // before ever touching hardware, 2026-09-02, when the user asked
    // "do we need to hold reset to program for this board?" -- worth
    // remembering as a real class of mistake, not just this one instance.
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
  // Debug-only ILA (fpga/build_ddr_ila.tcl creates the ila_0 IP; this
  // define is only set by that build script, never by build_ddr.tcl).
  // Targets a real-hardware finding: the interactive console (vi, or fast
  // typing) can leave the shell totally unresponsive to further input --
  // confirmed NOT a hang-vs-idle ambiguity (a bare Enter gets zero
  // response, vs. an instant reply moments before opening vi).
  //
  // dbg_stuck_flag: a purpose-built trigger, not a plain probe -- the freeze
  // was reproduced with characters paced a comfortable 15ms apart (nowhere
  // near "too fast"), so the interesting transition can sit tens of
  // milliseconds (hundreds of thousands of clk_core cycles) after the last
  // known-good byte. No plain sample buffer at this probe width can bridge
  // that gap, so instead of hunting for the moment in a giant capture, this
  // counter watches the PLIC's own u_plic.pending1/in_service1 state
  // (hierarchical reference -- debug-only tap, doesn't touch plic.sv
  // itself) and raises dbg_stuck_flag the instant that state has gone
  // unresolved (pending without a claim, or claimed without a complete) for
  // longer than any real interrupt service should ever take -- 1,000,000
  // cycles is ~17.8ms at the real ~56.26MHz clk_core, several orders of
  // magnitude past a normal RDI/THRI round trip. That flag IS the ILA
  // trigger, so capture starts exactly at the freeze regardless of how much
  // idle real time preceded it.
  logic [23:0] dbg_stuck_cnt;
  logic        dbg_stuck_flag;
  logic        dbg_plic_irq_unresolved;
  assign dbg_plic_irq_unresolved = u_plic.pending1 || u_plic.in_service1;
  always_ff @(posedge clk_core or negedge cpu_rst_n) begin
    if (!cpu_rst_n) begin
      dbg_stuck_cnt  <= '0;
      dbg_stuck_flag <= 1'b0;
    end else begin
      if (dbg_plic_irq_unresolved) begin
        if (dbg_stuck_cnt != 24'hFF_FFFF) dbg_stuck_cnt <= dbg_stuck_cnt + 1'b1;
      end else begin
        dbg_stuck_cnt <= '0;
      end
      dbg_stuck_flag <= (dbg_stuck_cnt > 24'd1_000_000);
    end
  end
  ila_0 u_ila_dbg (
    .clk    (clk_core),
    .probe0 ({dbg_stuck_flag, u_plic.in_service1, u_plic.pending1, uart_dr_status,
              u_uart.iir_val, u_uart.ier[1:0], plic_seip, plic_meip,
              uart_tx_valid, uart_tx_busy, uart_irq}),
    .probe1 ({uart_tx_data, uart_rx_inject_data, uart_rx_inject_valid}),
    .probe2 ({plic_ren, plic_wen, u_plic.complete_fire_ctx1, u_plic.complete_fire_ctx0,
              u_plic.claim_fire_ctx1, u_plic.claim_fire_ctx0}),
    .probe3 ({dbg_id_ex_valid, dbg_id_ex_pc}),
    .probe4 ({dbg_stuck_cnt[23:16], axi_infra_rst_n, cpu_rst_n})
  );
`endif

endmodule
