// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Eoghain Gray

// Minimal 16550-compatible UART: THR/RBR (offset 0x0), IER (0x1, ERBFI/ETBEI
// bits only), IIR (0x2, real RDI/THRI/NO_INT cause reporting -- see its own
// comment below; a real interrupt-storm bug, found 2026-09-05, when this was
// still RAZ), LSR (0x5, DR/THRE/TEMT bits only). Real 16-entry TX FIFO
// (2026-09-12, see its own comment below) between THR and the phy; RX FIFO
// lives in rtl/bridge/uart_phy.sv instead (this module's RBR/DR stay a
// single-byte handoff, fed by uart_phy's own queue). No baud divisor, no
// line control — FCR(0x2, write side only), LCR(0x3), MCR(0x4), SCR(0x7)
// all decode RAZ/WI. Byte-addressed (reg-shift=0), matching a real ns16550
// so Linux's stock 8250/8250_early driver needs zero new code.
//
// MSR (0x6) is the one exception to RAZ (2026-07-22): reads as a fixed
// 0xB0 (CTS/DSR/DCD asserted, RI and all four delta bits clear), not zero.
// A real console UART is wired directly with no actual modem, so these
// lines are tied permanently asserted in hardware — reading them as
// deasserted (as plain RAZ would) makes Linux's serial core believe no
// carrier is present. `uart_carrier_raised()` (drivers/tty/serial/
// serial_core.c) reads MSR via get_mctrl() and checks the DCD bit;
// tty_port_block_til_ready() (drivers/tty/tty_port.c) then blocks the
// open() indefinitely waiting for a carrier that a RAZ MSR could never
// report — confirmed as the exact cause of a "UART registers get
// programmed, then total silence forever" hang the first time anything
// (this project's own /init) opens /dev/console via the real tty layer
// rather than the polling-only early-console path used until now.
//
// THRE/TEMT default to a constant 1 (single-character, no-latency holding
// register) via `tx_busy`'s own default value below when nothing drives it
// (every sim caller — tb_riscv.sv, sim/mmu-tests, etc.) — the simplest
// valid model for this minimal subset when there's no real transmit
// latency to model. **Real hardware DOES have transmit latency**
// (rtl/bridge/uart_phy.sv serializing each byte out over the physical
// serial pin at the configured baud rate takes many real cycles, not
// zero) — `tx_busy` lets that latency become a real THRE/TEMT signal
// instead of silently vanishing: software polling an always-1 THRE would
// otherwise write new characters faster than the PHY can actually drain
// them, corrupting console output.
//
// `rx_inject_valid`/`rx_inject_data` are a sim-only backdoor (NOT real 16550
// registers/pins) that let a directed test or the eventual PLIC/UART
// integration deterministically simulate "a byte arrived" — driven only
// from a sim-only MMIO word in tb_riscv.sv, never reachable from real
// software. `tx_valid`/`tx_data` mirror THR writes one cycle later, for
// console-visibility hooks (e.g. printing over stdout in the Verilator C++
// driver) — also not a real pin until a later hardware phase.
module uart #(
  parameter logic [31:0] BASE_ADDR = 32'h1000_0000
)(
  input  logic        clk,
  input  logic        rst_n,

  input  logic [31:0] addr,
  input  logic [31:0] wdata,
  input  logic [3:0]  wmask,
  input  logic        wen,
  input  logic        ren,
  output logic [31:0] rdata,

  output logic        tx_valid,
  output logic [7:0]  tx_data,
  // tx_busy: real transmit-in-progress backpressure, driven by
  // rtl/bridge/uart_phy.sv's own `tx_busy` output on real hardware (still
  // shifting out a previous byte). Callers with no real PHY in the chain
  // (sim/tb_riscv.sv, fpga/genesys2_top_min.sv) tie this to 1'b0 (never
  // busy), preserving always-ready behavior — no default value here, since
  // this tool doesn't support them on module inputs, so every caller must
  // wire it explicitly. See this file's header comment for why this port
  // exists.
  input  logic         tx_busy,

  input  logic        rx_inject_valid,
  input  logic [7:0]  rx_inject_data,

  output logic        irq,
  // dr_status (2026-07-22): direct combinational view of the internal `dr`
  // (LSR bit0) flag, exposed so a host-driven RX injector (see tb_riscv.sv's
  // host_rx_valid/host_rx_ready) can tell whether the single-byte `rbr`
  // holding register is still occupied by an unread byte before injecting
  // a new one -- without this, injecting faster than the guest reads
  // silently overwrites `rbr`, dropping characters (confirmed: this exact
  // symptom, garbled scripted shell commands, is what led to adding this).
  output logic        dr_status
);
  assign dr_status = dr;

  logic [2:0] reg_off;
  logic [1:0] byte_lane;
  assign reg_off   = addr[2:0];
  assign byte_lane = addr[1:0];

  logic [7:0] wr_byte;
  assign wr_byte = wdata[8*byte_lane +: 8];

  logic [7:0] rbr;
  logic [7:0] ier;
  logic       dr;

  // TX FIFO (2026-09-12): a real 16-entry queue between THR writes and the
  // one-byte-at-a-time handoff to uart_phy (tx_valid/tx_data/tx_busy, all
  // unchanged below) -- added so Linux's stock 8250 driver can legitimately
  // burst up to `fifosize` THR writes in a row after seeing THRE=1, instead
  // of needing to re-poll THRE before every single byte
  // (drivers/tty/serial/8250/8250_port.c's serial8250_tx_chars() always
  // assumes it can do this once fifosize > 1 -- it's the entire point of a
  // FIFO). Before this, a single-register handoff meant: (a) the original
  // 2026-09-03 dropped-byte bug, when the DTS falsely claimed fifosize=16
  // against zero real buffering (fixed at the time by reporting fifosize=1
  // instead, i.e. "ns16450" -- see fpga/genesys2_hw.dts's own history); (b)
  // the 2026-09-06 vi/top interactive-console livelock, root-caused
  // to a TX-interrupt re-entry/storm under fifosize=1's
  // inherent "one THR write, one THRE interrupt" cadence during a big
  // screen-redraw burst. Reporting (and actually providing) a real 16-deep
  // FIFO turns that into "one THRE interrupt per ~16-byte burst" -- the
  // standard 16550A design intent this register model was already
  // pretending to implement. Depth 16 matches the DTS's `fifosize=16`
  // (compatible = "ns16550a"); fixed-width literals throughout (not
  // $clog2-derived) per this project's own clock-divider lesson.
  logic [7:0] tx_fifo [0:15];
  logic [3:0] tx_fifo_head, tx_fifo_tail;
  logic [4:0] tx_fifo_count;
  logic       tx_fifo_push, tx_fifo_pop, tx_fifo_empty;
  assign tx_fifo_empty = (tx_fifo_count == 5'd0);
  // Push: any THR write with room to spare. A write arriving when the FIFO
  // is already full (software violating the fifosize=16 contract THRE
  // advertises) is simply dropped, same minimalism as everywhere else in
  // this model (no OE flag) -- should never happen if THRE is honored.
  assign tx_fifo_push = wen && wmask[byte_lane] && (reg_off == 3'd0) && (tx_fifo_count != 5'd16);
  // Pop: hand the oldest queued byte to the phy the instant it's ready for
  // another one. tx_busy (from uart_phy) keeps its original meaning --
  // "the phy's serializer is still shifting a byte out" -- just now fed by
  // this FIFO instead of directly by a THR write.
  //
  // `!tx_valid` (2026-09-12, found by sim/uart-fifo-tests, not caught by
  // the single-byte-at-a-time sim/uart-phy-tests) is a REQUIRED extra term,
  // not a stylistic one: tx_busy is a registered output of a DIFFERENT
  // module (uart_phy), so it takes one full cycle after a tx_valid pulse
  // before tx_busy actually rises. With only "!tx_fifo_empty && !tx_busy",
  // every queued byte past the first got popped in that same one-cycle
  // window (tx_busy still stale-0, fifo still non-empty), each pop
  // overwriting tx_data/tx_valid before uart_phy ever latched the previous
  // one -- silently skipping bytes under a real multi-byte burst (a single
  // queued byte was always safe: after that one pop the fifo goes empty,
  // which masks the same race). tx_valid itself reverts to 0 exactly one
  // cycle after a pop (the default assignment below) precisely when
  // tx_busy finally rises, so anding it in closes the gap with no other
  // timing assumptions.
  assign tx_fifo_pop  = !tx_fifo_empty && !tx_busy && !tx_valid;

  logic [7:0] lsr_val;
  // bit6=TEMT (fifo empty AND phy done shifting -- truly idle), bit5=THRE
  // (fifo empty -- room for a fresh burst, even if the phy is still
  // finishing the last byte), bit0=DR. Real 16550A semantics: THRE reflects
  // the FIFO, not the shift register.
  assign lsr_val = {1'b0, (tx_fifo_empty && !tx_busy), tx_fifo_empty, 4'b0000, dr};

  assign irq = (dr && ier[0]) || (tx_fifo_empty && ier[1]); // (DR&&ERBFI) || (THRE&&ETBEI)

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rbr           <= 8'h0;
      ier           <= 8'h0;
      dr            <= 1'b0;
      tx_valid      <= 1'b0;
      tx_data       <= 8'h0;
      tx_fifo_head  <= 4'h0;
      tx_fifo_tail  <= 4'h0;
      tx_fifo_count <= 5'h0;
    end else begin
      tx_valid <= 1'b0;

      if (wen && wmask[byte_lane]) begin
        case (reg_off)
          3'd1: ier <= wr_byte;                                  // IER
          default: ; // RAZ/WI: IIR/FCR, LCR, MCR, LSR, MSR, SCR (THR handled
                     // separately below via the TX FIFO push/pop logic)
        endcase
      end

      if (tx_fifo_push) begin
        tx_fifo[tx_fifo_tail] <= wr_byte;
        tx_fifo_tail          <= tx_fifo_tail + 4'd1;
      end

      if (tx_fifo_pop) begin
        tx_data      <= tx_fifo[tx_fifo_head];
        tx_valid     <= 1'b1;
        tx_fifo_head <= tx_fifo_head + 4'd1;
      end

      case ({tx_fifo_push, tx_fifo_pop})
        2'b10:   tx_fifo_count <= tx_fifo_count + 5'd1;
        2'b01:   tx_fifo_count <= tx_fifo_count - 5'd1;
        default: tx_fifo_count <= tx_fifo_count; // 00 or 11 (same-cycle push+pop): unchanged
      endcase

      if (rx_inject_valid) begin
        rbr <= rx_inject_data;
        dr  <= 1'b1;
      end else if (ren && (reg_off == 3'd0)) begin
        dr <= 1'b0; // reading RBR clears DR
      end
    end
  end

  // IIR (2026-09-05, real bug found on the first real interrupt-driven RX
  // use -- every prior real-hardware session only ever exercised TX
  // interrupts/polling console output, never a human/script typing input).
  // This was previously RAZ (always reads 0x00), which a real 16550 decodes
  // as "interrupt pending, cause = modem status change" (UART_IIR_MSI=0x00)
  // -- completely disconnected from `irq`'s own real trigger condition
  // (RX-data-ready or TX-empty, see the `irq` assign above). Linux's real
  // interrupt-driven 8250 driver dispatches on this cause field to decide
  // what to service; fed a permanent false "modem status" cause, it never
  // performs the RBR read that would clear `dr`, so `irq` (level-triggered)
  // never deasserts -- a real interrupt storm/livelock, confirmed on real
  // hardware: the shell echoed a couple of typed characters then went
  // completely silent and unresponsive, even from a real terminal directly
  // on COM5 (not a bug in any capture tooling). Real 16550 priority order:
  // RDI (received data) outranks THRI (THR empty) when both are pending.
  logic [7:0] iir_val;
  always_comb begin
    if (dr && ier[0])                 iir_val = 8'h04; // UART_IIR_RDI
    else if (tx_fifo_empty && ier[1]) iir_val = 8'h02; // UART_IIR_THRI
    else                              iir_val = 8'h01; // UART_IIR_NO_INT
  end

  logic [7:0] read_byte;
  always_comb begin
    case (reg_off)
      3'd0:    read_byte = rbr;
      3'd1:    read_byte = {6'b0, ier[1:0]};
      3'd2:    read_byte = iir_val;
      3'd5:    read_byte = lsr_val;
      3'd6:    read_byte = 8'hB0; // MSR: DCD|DSR|CTS asserted, see file header
      default: read_byte = 8'h00;
    endcase
  end

  always_comb begin
    rdata = 32'h0;
    if (ren) begin
      case (byte_lane)
        2'd0: rdata[7:0]   = read_byte;
        2'd1: rdata[15:8]  = read_byte;
        2'd2: rdata[23:16] = read_byte;
        2'd3: rdata[31:24] = read_byte;
      endcase
    end
  end

endmodule
