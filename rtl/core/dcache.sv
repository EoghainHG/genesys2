// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Eoghain Gray

// Direct-mapped, write-through data cache.
// Parameters: 256 sets, 4 words/line → 4 KB capacity.
// Address layout: tag[31:12] | index[11:4] | word[3:2] | byte[1:0]
// Policy: write-through, update-on-hit, no-write-allocate.
// On a read miss the cache stalls the CPU for 4 cycles while filling the line.
//
// Memory-side handshake (mem_ready): the backing memory may take an
// arbitrary number of cycles to service a request — mem_addr/mem_wdata/
// mem_wmask/mem_wen/mem_ren are held stable while mem_ren or mem_wen is
// asserted, and the cache waits until mem_ready pulses (with mem_rdata
// valid that same cycle, for a read) before considering the request done.
// A backing memory that responds combinationally (same-cycle) — e.g. the
// existing sim/FPGA zero-latency RAM — simply ties mem_ready to whatever
// combinationally reflects "this request is answered", reproducing the
// original single-cycle-per-word timing exactly (see sim/tb_riscv.sv and
// fpga/genesys2_top_min.sv). This is what makes real (multi-cycle, e.g. AXI/DDR)
// backing memory possible without touching this FSM's control logic.
module dcache #(
  parameter int SETS           = 256,
  parameter int WORDS_PER_LINE = 4       // must be a power of 2
)(
  input  logic        clk,
  input  logic        rst_n,

  // CPU side
  input  logic [31:0] cpu_addr,
  input  logic [31:0] cpu_wdata,
  input  logic [3:0]  cpu_wmask,
  input  logic        cpu_wen,
  input  logic        cpu_ren,
  output logic [31:0] cpu_rdata,
  output logic        cache_stall,

  // Memory side
  output logic [31:0] mem_addr,
  output logic [31:0] mem_wdata,
  output logic [3:0]  mem_wmask,
  output logic        mem_wen,
  output logic        mem_ren,
  input  logic [31:0] mem_rdata,
  input  logic        mem_ready
);

  localparam int WORD_BITS = $clog2(WORDS_PER_LINE);          // 2
  localparam int IDX_BITS  = $clog2(SETS);                    // 8
  localparam int TAG_BITS  = 32 - IDX_BITS - WORD_BITS - 2;  // 20

  // Address field extraction
  logic [TAG_BITS-1:0]  addr_tag;
  logic [IDX_BITS-1:0]  addr_idx;
  logic [WORD_BITS-1:0] addr_word;

  assign addr_tag  = cpu_addr[31 : 2+WORD_BITS+IDX_BITS];
  assign addr_idx  = cpu_addr[2+WORD_BITS+IDX_BITS-1 : 2+WORD_BITS];
  assign addr_word = cpu_addr[2+WORD_BITS-1 : 2];

  // Cache arrays
  logic              c_valid [SETS];
  logic [TAG_BITS-1:0] c_tag [SETS];
  logic [31:0]       c_data [SETS][WORDS_PER_LINE];

  logic cache_hit;
  assign cache_hit = c_valid[addr_idx] && (c_tag[addr_idx] == addr_tag);

  // FSM
  typedef enum logic [1:0] { ST_IDLE, ST_FILL, ST_WRITE } state_t;
  state_t               state;
  logic [WORD_BITS-1:0] fill_word;
  logic [IDX_BITS-1:0]  fill_idx;
  logic [TAG_BITS-1:0]  fill_tag;

  // Write request, latched on entry to ST_WRITE and held stable (address/
  // data/mask must not change mid-transaction) until mem_ready completes it.
  logic [31:0] wr_addr, wr_wdata;
  logic [3:0]  wr_wmask;

  // Set for exactly the one cycle right after a write completes (ST_WRITE's
  // mem_ready fires and state returns to ST_IDLE). Lets ST_IDLE recognize a
  // still-held cpu_wen (the CPU hasn't advanced its pipeline yet) as the
  // SAME write finishing rather than a brand-new request, without ever
  // making cache_stall report "not busy" before state has actually reached
  // ST_IDLE. An earlier version cleared cache_stall on the same cycle
  // mem_ready arrived (still inside ST_WRITE) to break exactly this
  // retrigger case — but that made dcache look idle to OTHER dmem-port
  // users (e.g. the page-table walker sharing this same port) for a cycle
  // before it had actually finished, so a PTE fetch issued that same cycle
  // got silently ignored (dcache still busy in ST_WRITE) while still
  // reading back cpu_rdata's default 0 — a spurious page fault (found via
  // the Phase 3 regression run: mmu_identity_basic/mmu_perm_fault). This
  // pulse-based fix keeps cache_stall asserted for the FULL ST_WRITE
  // duration (matching ST_FILL's contract exactly) and instead resolves
  // the retrigger case entirely within ST_IDLE.
  logic wr_done_pulse;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state         <= ST_IDLE;
      fill_word     <= '0;
      fill_idx      <= '0;
      fill_tag      <= '0;
      wr_addr       <= '0;
      wr_wdata      <= '0;
      wr_wmask      <= '0;
      wr_done_pulse <= 1'b0;
    end else begin
      wr_done_pulse <= 1'b0;  // default: pulse lasts exactly 1 cycle
      case (state)
        ST_IDLE: begin
          if (cpu_wen && !wr_done_pulse) begin
            // Write-through cache update on store hit is handled in the
            // dedicated c_data always_ff below (2026-08-27) -- the
            // backing-memory write is still tracked here via ST_WRITE/
            // mem_ready.
            wr_addr  <= cpu_addr;
            wr_wdata <= cpu_wdata;
            wr_wmask <= cpu_wmask;
            state    <= ST_WRITE;
          end else if (!cpu_wen && cpu_ren && !cache_hit) begin
            // Miss: word-0 read already issued combinationally below;
            // move to ST_FILL to await its (possibly multi-cycle) response.
            fill_tag  <= addr_tag;
            fill_idx  <= addr_idx;
            fill_word <= '0;
            state     <= ST_FILL;
          end
        end
        ST_FILL: begin
          if (mem_ready) begin
            if (&fill_word) begin  // fill_word == WORDS_PER_LINE-1 (all 1s)
              fill_word         <= '0;
              state             <= ST_IDLE;
            end else begin
              fill_word <= fill_word + 1'b1;
            end
          end
        end
        ST_WRITE: begin
          if (mem_ready) begin
            state         <= ST_IDLE;
            wr_done_pulse <= 1'b1;
          end
        end
        default: state <= ST_IDLE;
      endcase
    end
  end

  // c_valid: reset and fill-complete set combined into one per-index,
  // priority-ordered if/else (reset unconditionally wins) instead of a
  // whole-array reset for-loop plus a separately-indexed set living
  // elsewhere in the block -- mirrors icache.sv's fix (2026-08-27). This
  // exact dcache code started producing Vivado's [Synth 8-7137] "Set and
  // reset with same priority" warning once icache's copy was fixed first,
  // confirming the warning is sensitive to whole-netlist synthesis
  // optimization, not just one module's own local source.
  always_ff @(posedge clk or negedge rst_n) begin
    for (int i = 0; i < SETS; i++) begin
      if (!rst_n) begin
        c_valid[i] <= 1'b0;
      end else if (state == ST_FILL && mem_ready && &fill_word && fill_idx == i[IDX_BITS-1:0]) begin
        c_valid[i] <= 1'b1;
      end
    end
  end

  // c_tag: only ever trusted when c_valid is also true, so it needs no
  // reset value of its own -- plain synchronous-only register.
  always_ff @(posedge clk) begin
    if (state == ST_FILL && mem_ready && &fill_word) begin
      c_tag[fill_idx] <= fill_tag;
    end
  end

  // c_data: written from two mutually exclusive states -- a write-through
  // update on a store hit, or a fill from the backing memory -- both
  // conditions live in this one dedicated always_ff (still exactly one
  // driver), needing no reset value of its own for the same reason as
  // c_tag above.
  always_ff @(posedge clk) begin
    if (state == ST_IDLE && cpu_wen && !wr_done_pulse && cache_hit) begin
      if (cpu_wmask[0]) c_data[addr_idx][addr_word][7:0]   <= cpu_wdata[7:0];
      if (cpu_wmask[1]) c_data[addr_idx][addr_word][15:8]  <= cpu_wdata[15:8];
      if (cpu_wmask[2]) c_data[addr_idx][addr_word][23:16] <= cpu_wdata[23:16];
      if (cpu_wmask[3]) c_data[addr_idx][addr_word][31:24] <= cpu_wdata[31:24];
    end else if (state == ST_FILL && mem_ready) begin
      c_data[fill_idx][fill_word] <= mem_rdata;
    end
  end

  // Combinational outputs
  always_comb begin
    cpu_rdata   = '0;
    cache_stall = 1'b0;
    mem_addr    = '0;
    mem_wdata   = '0;
    mem_wmask   = '0;
    mem_wen     = 1'b0;
    mem_ren     = 1'b0;

    case (state)
      ST_IDLE: begin
        if (cpu_wen) begin
          // wr_done_pulse: this cpu_wen is a stale hold-over from the write
          // that JUST completed (the CPU pipeline hasn't advanced yet) —
          // already done, don't stall and don't issue anything new.
          cache_stall = wr_done_pulse ? 1'b0 : 1'b1;
        end else if (cpu_ren) begin
          if (cache_hit) begin
            cpu_rdata = c_data[addr_idx][addr_word];
          end else begin
            cache_stall = 1'b1;
            mem_ren     = 1'b1;
            mem_addr    = {addr_tag, addr_idx, {WORD_BITS{1'b0}}, 2'b00};
          end
        end
      end
      ST_FILL: begin
        cache_stall = 1'b1;
        mem_ren     = 1'b1;
        mem_addr    = {fill_tag, fill_idx, fill_word, 2'b00};
      end
      ST_WRITE: begin
        // Stays asserted for the FULL ST_WRITE duration, including the
        // mem_ready cycle — matches ST_FILL's contract. This means dcache
        // never reports "not busy" before its own state has genuinely
        // returned to ST_IDLE, which matters because the dmem port is
        // shared with the page-table walker: if cache_stall cleared one
        // cycle early (still inside ST_WRITE), a PTE fetch issued that
        // same cycle would be silently ignored by this state's combinational
        // logic (it doesn't look at cpu_ren at all) while still reporting
        // "done" with cpu_rdata's stale default — a spurious page fault
        // (found via the Phase 3 regression run). See wr_done_pulse above
        // for how the CPU's own retrigger-on-stale-cpu_wen case is instead
        // resolved, entirely within ST_IDLE.
        cache_stall = 1'b1;
        mem_addr    = wr_addr;
        mem_wdata   = wr_wdata;
        mem_wmask   = wr_wmask;
        mem_wen     = 1'b1;
      end
      default: ;
    endcase
  end

endmodule
