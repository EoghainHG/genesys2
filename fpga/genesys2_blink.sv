// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Eoghain Gray

// Genesys 2 bring-up step A: pure clock/LED/JTAG smoke test, zero core RTL
// involved. The literal first thing to program the moment the board
// arrives -- confirms clocking, programming/JTAG, and I/O all work before
// ever touching the RV32 core.
//
// Clock: deliberately a PLAIN synchronous divider off the raw 200 MHz
// LVDS differential input, NOT an MMCM. This is a considered choice, not
// an oversight: an MMCME4_BASE's LOCKED output failing to assert on real
// hardware for a never-conclusively-root-caused reason has been seen on a
// different chip family (UltraScale+), and the workaround there was
// exactly this -- drop the MMCM, use a plain divider. That may not
// generalize to this board's plain 7-series fabric, but there is no
// reason to accept ANY MMCM-lock risk for a go/no-go smoke test with no
// real frequency requirement. MMCM-based real clock generation is
// deferred to after this simplest possible path is confirmed working on
// real hardware.
//
// Board facts (verified 2026-09-01 against Digilent's own
// Genesys-2-Master.xdc + the official reference manual, not guessed):
// sysclk_p/n = AD12/AD11, LVDS, 200 MHz. led[7:0] = LVCMOS33.
// cpu_resetn = R19, LVCMOS33, active-low pushbutton.
module genesys2_blink (
  input  logic sysclk_p,
  input  logic sysclk_n,
  input  logic cpu_resetn,
  output logic [7:0] led
);

  logic clk_200;
  IBUFDS u_ibufds (.I(sysclk_p), .IB(sysclk_n), .O(clk_200));

  // Plain free-running divider -- no PLL/MMCM, see header.
  localparam int DIV_BITS = 27; // 200MHz/2^27 ~= 1.5s period on the top bit
  logic [DIV_BITS-1:0] counter;

  // 2-flop synchronizer on the async pushbutton input before use as reset.
  logic [1:0] resetn_sync;
  logic       rst_n;
  always_ff @(posedge clk_200) resetn_sync <= {resetn_sync[0], cpu_resetn};
  assign rst_n = resetn_sync[1];

  always_ff @(posedge clk_200 or negedge rst_n) begin
    if (!rst_n) counter <= '0;
    else        counter <= counter + 1'b1;
  end

  // Raw binary counter on the LEDs -- each LED toggles at half the rate of
  // the next, so this does NOT read as a directional "counting" pattern to
  // the eye. That's expected, not a bug.
  assign led = counter[DIV_BITS-1 -: 8];

endmodule
