// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Eoghain Gray

// AXI4-Lite master bridge: translates the core's simple synchronous memory
// protocol (mem_addr/mem_wdata/mem_wmask/mem_wen/mem_ren/mem_rdata/mem_ready
// — see dcache.sv/icache.sv's header comments for the exact contract) into
// AXI4-Lite master read/write transactions. This is what lets the caches,
// tolerant of an arbitrary-latency backing store via mem_ready, actually
// reach DDR3 through MIG's AXI slave port (via an AXI SmartConnect, see
// fpga/bd_build.tcl).
//
// mem_wmask maps directly onto WSTRB (both are byte-lane strobes over a
// 32-bit word — no translation needed). AWPROT/ARPROT are tied to 3'b000
// (unprivileged, secure, data) — this core doesn't model AXI privilege/
// security signaling.
//
// One transaction in flight at a time (matches the caches' own contract:
// they never issue a new request until mem_ready completes the last one),
// so this FSM does not need to pipeline AW/W/B or AR/R.
//
// ADDR_OFFSET is subtracted from mem_addr before driving AWADDR/ARADDR —
// needed because this core's RAM/PC_RESET convention is 0x8000_0000-based
// (see sim/tb_riscv.sv, fpga/genesys2_top_ddr.sv) while MIG's AXI window is
// 0-based. Leave at the default 0 for any target where the AXI-side and
// core-side address conventions already agree.
module axi4lite_master #(
  parameter int  ADDR_WIDTH  = 32,
  parameter int  DATA_WIDTH  = 32,
  parameter logic [ADDR_WIDTH-1:0] ADDR_OFFSET = '0
)(
  input  logic                    clk,
  input  logic                    rst_n,

  // Core-facing side (cache's memory port)
  input  logic [ADDR_WIDTH-1:0]   mem_addr,
  input  logic [DATA_WIDTH-1:0]   mem_wdata,
  input  logic [DATA_WIDTH/8-1:0] mem_wmask,
  input  logic                    mem_wen,
  input  logic                    mem_ren,
  output logic [DATA_WIDTH-1:0]   mem_rdata,
  output logic                    mem_ready,

  // AXI4-Lite master — write address channel
  output logic [ADDR_WIDTH-1:0]   m_axi_awaddr,
  output logic [2:0]              m_axi_awprot,
  output logic                    m_axi_awvalid,
  input  logic                    m_axi_awready,

  // AXI4-Lite master — write data channel
  output logic [DATA_WIDTH-1:0]   m_axi_wdata,
  output logic [DATA_WIDTH/8-1:0] m_axi_wstrb,
  output logic                    m_axi_wvalid,
  input  logic                    m_axi_wready,

  // AXI4-Lite master — write response channel
  input  logic [1:0]              m_axi_bresp,
  input  logic                    m_axi_bvalid,
  output logic                    m_axi_bready,

  // AXI4-Lite master — read address channel
  output logic [ADDR_WIDTH-1:0]   m_axi_araddr,
  output logic [2:0]              m_axi_arprot,
  output logic                    m_axi_arvalid,
  input  logic                    m_axi_arready,

  // AXI4-Lite master — read data channel
  input  logic [DATA_WIDTH-1:0]   m_axi_rdata,
  input  logic [1:0]              m_axi_rresp,
  input  logic                    m_axi_rvalid,
  output logic                    m_axi_rready,

  // Debug-only (2026-07-30): raw FSM state, added to localize a real
  // hardware-only post-satp translated-access hang (found 2026-07-28) —
  // lets a caller tell ST_READ (AR outstanding, waiting
  // on m_axi_arready) apart from ST_RRESP (waiting on m_axi_rvalid) apart
  // from ST_IDLE (no transaction even issued).
  output logic [2:0]              dbg_state,

  // Debug-only (2026-08-03): free-running count of successfully-completed
  // reads (ST_RRESP exiting via a real m_axi_rvalid, not the fatal parked
  // case). Added to test whether the real-hardware ST_RRESP hang
  // (found 2026-08-03) is a deterministic, transaction-
  // count-driven event (e.g. some fixed-size internal AXI infrastructure
  // resource exhausting/wrapping after N transactions) rather
  // than a purely address/timing-driven one — never captured before this.
  // Like dbg_state, this needs no one-shot capture trick: the fatal
  // transaction parks in ST_RRESP forever, so this counter's final value
  // (read via LED/dbg_ja at any later, convenient moment) is simply "how
  // many reads succeeded before the one that never did."
  output logic [13:0]             dbg_txn_count
);

  typedef enum logic [2:0] {
    ST_IDLE,
    ST_WRITE,   // AW/W outstanding (independently, each latched once accepted)
    ST_BRESP,   // waiting for B
    ST_READ,    // AR outstanding
    ST_RRESP    // waiting for R
  } state_t;
  state_t state;

  assign dbg_state = state;

  logic [13:0] txn_count;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) txn_count <= '0;
    else if ((state == ST_RRESP) && m_axi_rvalid) txn_count <= txn_count + 1'b1;
  end
  assign dbg_txn_count = txn_count;

  // Latched request, held stable for the duration of the transaction —
  // mem_addr/mem_wdata/mem_wmask are only guaranteed valid on the cycle
  // mem_wen/mem_ren first fires (matches every existing dcache/icache
  // caller's contract: they don't re-drive the request every cycle).
  logic [ADDR_WIDTH-1:0]   req_addr;
  logic [DATA_WIDTH-1:0]   req_wdata;
  logic [DATA_WIDTH/8-1:0] req_wstrb;

  // Independent AW/W acceptance tracking — AXI4-Lite does not guarantee
  // AWREADY and WREADY assert on the same cycle.
  logic aw_done, w_done;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state     <= ST_IDLE;
      req_addr  <= '0;
      req_wdata <= '0;
      req_wstrb <= '0;
      aw_done   <= 1'b0;
      w_done    <= 1'b0;
    end else begin
      case (state)
        ST_IDLE: begin
          aw_done <= 1'b0;
          w_done  <= 1'b0;
          if (mem_wen) begin
            req_addr  <= mem_addr - ADDR_OFFSET;
            req_wdata <= mem_wdata;
            req_wstrb <= mem_wmask;
            state     <= ST_WRITE;
          end else if (mem_ren) begin
            req_addr <= mem_addr - ADDR_OFFSET;
            state    <= ST_READ;
          end
        end
        ST_WRITE: begin
          if (m_axi_awvalid && m_axi_awready) aw_done <= 1'b1;
          if (m_axi_wvalid  && m_axi_wready)  w_done  <= 1'b1;
          if ((aw_done || (m_axi_awvalid && m_axi_awready)) &&
              (w_done  || (m_axi_wvalid  && m_axi_wready)))
            state <= ST_BRESP;
        end
        ST_BRESP: begin
          if (m_axi_bvalid) state <= ST_IDLE;  // BRESP not checked — see header
        end
        ST_READ: begin
          if (m_axi_arvalid && m_axi_arready) state <= ST_RRESP;
        end
        ST_RRESP: begin
          if (m_axi_rvalid) state <= ST_IDLE;
        end
        default: state <= ST_IDLE;
      endcase
    end
  end

  // Write address channel
  assign m_axi_awaddr  = req_addr;
  assign m_axi_awprot  = 3'b000;
  assign m_axi_awvalid = (state == ST_WRITE) && !aw_done;

  // Write data channel
  assign m_axi_wdata  = req_wdata;
  assign m_axi_wstrb  = req_wstrb;
  assign m_axi_wvalid = (state == ST_WRITE) && !w_done;

  // Write response channel — always ready; BRESP (error/OK) is not surfaced
  // to the core, matching this project's existing scope (no bus-fault
  // reporting anywhere else in the memory path either).
  assign m_axi_bready = (state == ST_BRESP);

  // Read address channel
  assign m_axi_araddr  = req_addr;
  assign m_axi_arprot  = 3'b000;
  assign m_axi_arvalid = (state == ST_READ);

  // Read data channel
  assign m_axi_rready = (state == ST_RRESP);

  // mem_rdata/mem_ready
  assign mem_rdata = m_axi_rdata;
  assign mem_ready = ((state == ST_BRESP) && m_axi_bvalid) ||
                      ((state == ST_RRESP) && m_axi_rvalid);

endmodule
