// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Eoghain Gray

// Genesys 2 bring-up step 2 (DDR3, stage A): the smallest possible test of
// the real MIG7 DDR3 controller against this board's actual DDR3 chip --
// deliberately NO CPU, NO AXI traffic at all. Just MIG (via the
// mig_bridge_wrapper block design, fpga/bd_build.tcl) + two LEDs tied
// directly to init_calib_complete/mmcm_locked. This isolates "does the
// real DDR3 physical layer calibrate on real hardware" (the single
// biggest unproven risk in this project's DDR3 work -- wrong pin mapping,
// timing, or DDR3 chip identification would show up here) from "does the
// CPU's own AXI datapath work," which needs a way to load a real program
// into DDR3 first (JTAG-to-AXI Master IP, not yet built) to be
// meaningfully testable at all. Matches this
// project's own repeated staged-risk bring-up discipline (blink -> min ->
// uart -> now: calib-only, before the full CPU+DDR top level).
//
// The mig_bridge block design (fpga/bd_build.tcl) also includes a
// SmartConnect wired for two AXI4-Lite masters (icache/dcache), unused
// here -- both S_AXI_LITE_* slave ports are tied to a safe idle state
// (never asserting *valid) so SmartConnect simply never issues any AXI
// traffic through MIG; this has no effect on whether MIG itself
// calibrates. Reusing the same wrapper (rather than a separate BD without
// the AXI infrastructure) avoids rebuilding/re-validating the block
// design for a variant that will be needed again immediately once the
// full CPU+DDR top level is built.
module genesys2_top_ddr_calib (
  input  logic sysclk_p,
  input  logic sysclk_n,
  input  logic cpu_resetn,
  output logic [7:0] led,

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

  // No plain-RTL clock divider in this minimal calib-only design -- all
  // sequential logic below runs directly on ui_clk, which already has a
  // real, valid clock object from MIG's own generated constraints, and
  // Vivado uses it automatically for any logic clocked
  // directly by it, no extra top-level XDC needed.
  //
  // (A first attempt at this file used a plain /12 divider off ui_clk,
  // matching every prior top level's "no home-grown MMCM" policy -- but
  // that requires a create_generated_clock sourced from a pin *inside*
  // the mig_bridge_wrapper instance, which is synthesized out-of-context
  // as part of the Block Design flow: at the point the top-level XDC is
  // applied, that hierarchy isn't yet linked/flattened, so the pin simply
  // doesn't resolve. Confirmed the hard way: CRITICAL WARNING
  // "No valid object(s) found for '-source [get_pins u_mig_bridge/ui_clk]'"
  // and 16742 unconstrained_internal_endpoints on that attempt's build --
  // the same failure class as genesys2_top_min's original clk_core bug,
  // just triggered by an
  // OOC-hierarchy boundary instead of a missing constraint outright. This
  // minimal design has no CPU and no meaningful timing pressure even at
  // ui_clk's full native frequency, so running directly on it avoids the
  // whole class of problem rather than working around it -- the future
  // full CPU+DDR top level, which does need a slower clk_core, will need
  // a real fix for this (e.g. constraining inside the BD itself, or via a
  // constraint set scoped to apply post-synthesis), not this shortcut.)

  // clk_core is still a real BD input port (feeds SmartConnect's
  // aclk/domain-0, unused here since no AXI traffic exists in this
  // design) -- loop ui_clk back into it directly rather than leaving
  // SmartConnect's mandatory clock input undriven.
  logic clk_core;
  assign clk_core = ui_clk;

  // Reset synchronizer -- 2-flop, clk_core domain, gated on both the
  // cpu_resetn pushbutton and init_calib_complete (already synchronous to
  // ui_clk, which clk_core simply is -- this synchronizer is
  // conservative-but-correct debounce/CDC hygiene, not strictly required
  // given clk_core and ui_clk are the same clock here). No CPU exists in
  // this design to
  // actually reset, but led output below still uses this so the LEDs
  // themselves only ever reflect a stable, debounced calibration result.
  logic [1:0] resetn_sync;
  logic [1:0] calib_sync;
  logic       rst_n;
  always_ff @(posedge clk_core) begin
    resetn_sync <= {resetn_sync[0], cpu_resetn};
    calib_sync  <= {calib_sync[0], init_calib_complete};
  end
  assign rst_n = resetn_sync[1] & calib_sync[1];

  // led[0] = calibration succeeded (steady on once DDR3 PHY calibration
  // completes and stays completed through the reset synchronizer).
  // led[1] = MIG's internal MMCM locked (should assert well before
  // led[0] -- if led[1] never lights, the problem is upstream of DDR3
  // entirely, i.e. the 200MHz input clock/MMCM itself, not DDR3 timing).
  // led[7:2] unused, tied off.
  always_ff @(posedge clk_core) begin
    led[0] <= rst_n;
    led[1] <= mmcm_locked;
  end
  assign led[7:2] = '0;

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
    .sys_rst       (cpu_resetn),

    .clk_core         (clk_core),
    .clk_core_aresetn (rst_n),

    .init_calib_complete (init_calib_complete),
    .mmcm_locked          (mmcm_locked),
    .ui_clk               (ui_clk),
    .ui_clk_sync_rst      (ui_clk_sync_rst),

    // Both AXI4-Lite slave ports tied to a safe idle state -- no CPU in
    // this design to drive them. Never asserting *valid means
    // SmartConnect issues no transactions to MIG at all; this design only
    // tests whether MIG itself calibrates, not the AXI datapath.
    .S_AXI_LITE_icache_awvalid (1'b0),
    .S_AXI_LITE_icache_awaddr  (32'h0),
    .S_AXI_LITE_icache_awlen   (8'h0),
    .S_AXI_LITE_icache_awsize  (3'h0),
    .S_AXI_LITE_icache_awburst (2'h0),
    .S_AXI_LITE_icache_awlock  (1'b0),
    .S_AXI_LITE_icache_awcache (4'h0),
    .S_AXI_LITE_icache_awprot  (3'h0),
    .S_AXI_LITE_icache_awqos   (4'h0),
    .S_AXI_LITE_icache_wvalid  (1'b0),
    .S_AXI_LITE_icache_wdata   (32'h0),
    .S_AXI_LITE_icache_wstrb   (4'h0),
    .S_AXI_LITE_icache_wlast   (1'b1),
    .S_AXI_LITE_icache_bready  (1'b1),
    .S_AXI_LITE_icache_arvalid (1'b0),
    .S_AXI_LITE_icache_araddr  (32'h0),
    .S_AXI_LITE_icache_arlen   (8'h0),
    .S_AXI_LITE_icache_arsize  (3'h0),
    .S_AXI_LITE_icache_arburst (2'h0),
    .S_AXI_LITE_icache_arlock  (1'b0),
    .S_AXI_LITE_icache_arcache (4'h0),
    .S_AXI_LITE_icache_arprot  (3'h0),
    .S_AXI_LITE_icache_arqos   (4'h0),
    .S_AXI_LITE_icache_rready  (1'b1),

    .S_AXI_LITE_dcache_awvalid (1'b0),
    .S_AXI_LITE_dcache_awaddr  (32'h0),
    .S_AXI_LITE_dcache_awlen   (8'h0),
    .S_AXI_LITE_dcache_awsize  (3'h0),
    .S_AXI_LITE_dcache_awburst (2'h0),
    .S_AXI_LITE_dcache_awlock  (1'b0),
    .S_AXI_LITE_dcache_awcache (4'h0),
    .S_AXI_LITE_dcache_awprot  (3'h0),
    .S_AXI_LITE_dcache_awqos   (4'h0),
    .S_AXI_LITE_dcache_wvalid  (1'b0),
    .S_AXI_LITE_dcache_wdata   (32'h0),
    .S_AXI_LITE_dcache_wstrb   (4'h0),
    .S_AXI_LITE_dcache_wlast   (1'b1),
    .S_AXI_LITE_dcache_bready  (1'b1),
    .S_AXI_LITE_dcache_arvalid (1'b0),
    .S_AXI_LITE_dcache_araddr  (32'h0),
    .S_AXI_LITE_dcache_arlen   (8'h0),
    .S_AXI_LITE_dcache_arsize  (3'h0),
    .S_AXI_LITE_dcache_arburst (2'h0),
    .S_AXI_LITE_dcache_arlock  (1'b0),
    .S_AXI_LITE_dcache_arcache (4'h0),
    .S_AXI_LITE_dcache_arprot  (3'h0),
    .S_AXI_LITE_dcache_arqos   (4'h0),
    .S_AXI_LITE_dcache_rready  (1'b1)
  );

endmodule
