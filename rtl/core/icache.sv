// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Eoghain Gray

// Direct-mapped, read-only instruction cache.
// Parameters: 256 sets, 4 words/line → 4 KB capacity.
// Address layout: tag[31:12] | index[11:4] | word[3:2] | byte[1:0]
// On a miss the cache stalls the CPU for 4 cycles while filling the line.
//
// Memory-side handshake (mem_ready): see dcache.sv's header comment — same
// contract. A zero-latency backing memory ties mem_ready combinationally
// to reproduce the original single-cycle-per-word timing exactly.
module icache #(
  parameter int SETS           = 256,
  parameter int WORDS_PER_LINE = 4
)(
  input  logic        clk,
  input  logic        rst_n,

  // CPU side (read-only)
  input  logic [31:0] cpu_addr,
  output logic [31:0] cpu_rdata,
  output logic        cache_stall,

  // req_hold (2026-08-28): asserted by the CPU when cpu_addr is NOT yet a
  // resolved physical address this cycle -- specifically during an ITLB miss,
  // when cpu.sv's imem_addr mux falls through to the raw, untranslated VA
  // while the page-table walk is still in flight. Without this the icache
  // has no notion of "translation pending": it would miss on that raw VA and
  // issue an AXI read for it. For an identity mapping that read is merely
  // wasteful (the raw VA == the real PA); for a non-identity mapping -- e.g.
  // a kernel's / mmu_transition_test's jump to a high-half VA alias like
  // 0xC050016C -- the raw VA is out of physical DRAM range, the interconnect
  // accepts the AR and never returns RVALID, and the whole core wedges. This
  // was the real-hardware Phase 2 boot hang root-caused end-to-end 2026-08-28.
  // While req_hold is asserted the icache stays in
  // ST_IDLE, issues no mem_ren, and asserts cache_stall -- it only ever
  // acts on cpu_addr once it is the final translated (or Bare) PA.
  input  logic        req_hold,

  // fence_i (2026-08-29, fix #6): 1-cycle pulse from cpu.sv (imem_fence)
  // when a FENCE.I retires. This core's caches are not coherent and there
  // is no snoop, so a data-side store to an instruction address is
  // otherwise invisible to fetch until the line is evicted. On this pulse,
  // drop every line's valid bit -- the next fetch of each line re-loads it
  // from (now-current) memory. The CPU pairs this with a pc_if redirect to
  // the instruction after the FENCE.I, so nothing stale stays in flight.
  input  logic        fence_i,

  // Memory side
  output logic [31:0] mem_addr,
  output logic        mem_ren,
  input  logic [31:0] mem_rdata,
  input  logic        mem_ready,

  // Debug-only (2026-08-06): expose the hit/miss decision and the index
  // being looked up every cycle. Added to test the ST_RRESP hang's latest
  // hypothesis (found 2026-08-04) — that the second fetch of an address the loop just fetched
  // moments earlier genuinely re-misses because something else executed in
  // between aliased to the same direct-mapped index and evicted the line
  // (real hardware instantiates SETS=16, so addr_idx is only 4 bits wide —
  // high alias pressure). dbg_miss_pulse fires exactly once per real miss
  // decision (not held across the whole ST_FILL refill), so a capture can
  // pick out every intervening eviction-driven miss, not just the two
  // known 0x140058 ones.
  output logic                    dbg_hit,
  output logic [$clog2(SETS)-1:0] dbg_addr_idx,
  output logic                    dbg_miss_pulse,

  // Debug-only (2026-08-06, continued): dbg_hit is valid&&tag_match ANDed
  // together, which can't distinguish *why* a revisit misses. The
  // icachefire capture this session showed the fatal line (index 6) fills
  // and hits once, then misses again on the very next revisit with no
  // other access to that index in between -- these two split taps let a
  // follow-up capture show directly whether the valid bit itself reads
  // back false, or whether the tag comparison mismatches, at that exact
  // revisit.
  output logic                    dbg_valid,
  output logic                    dbg_tag_match
);

  localparam int WORD_BITS = $clog2(WORDS_PER_LINE);          // 2
  localparam int IDX_BITS  = $clog2(SETS);                    // 8
  localparam int TAG_BITS  = 32 - IDX_BITS - WORD_BITS - 2;  // 20

  logic [TAG_BITS-1:0]  addr_tag;
  logic [IDX_BITS-1:0]  addr_idx;
  logic [WORD_BITS-1:0] addr_word;

  assign addr_tag  = cpu_addr[31 : 2+WORD_BITS+IDX_BITS];
  assign addr_idx  = cpu_addr[2+WORD_BITS+IDX_BITS-1 : 2+WORD_BITS];
  assign addr_word = cpu_addr[2+WORD_BITS-1 : 2];

  logic              c_valid [SETS];
  logic [TAG_BITS-1:0] c_tag [SETS];
  logic [31:0]       c_data [SETS][WORDS_PER_LINE];

  logic cache_hit;
  assign cache_hit = c_valid[addr_idx] && (c_tag[addr_idx] == addr_tag);

  assign dbg_valid     = c_valid[addr_idx];
  assign dbg_tag_match = (c_tag[addr_idx] == addr_tag);

  typedef enum logic { ST_IDLE = 1'b0, ST_FILL = 1'b1 } state_t;
  state_t               state;
  logic [WORD_BITS-1:0] fill_word;
  logic [IDX_BITS-1:0]  fill_idx;
  logic [TAG_BITS-1:0]  fill_tag;

  assign dbg_hit        = cache_hit;
  assign dbg_addr_idx   = addr_idx;
  assign dbg_miss_pulse = !cache_hit && (state == ST_IDLE);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state     <= ST_IDLE;
      fill_word <= '0;
      fill_idx  <= '0;
      fill_tag  <= '0;
    end else begin
      case (state)
        ST_IDLE: begin
          if (!cache_hit && !req_hold) begin
            // Miss on a resolved address: word-0 read already issued
            // combinationally below; move to ST_FILL to await its
            // (possibly multi-cycle) response. A miss while req_hold is
            // asserted is ignored entirely -- cpu_addr isn't a real PA yet.
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
        default: state <= ST_IDLE;
      endcase
    end
  end

  // c_tag: same reasoning as c_data below -- only ever trusted when
  // c_valid is also true, so no reset value of its own is needed. Moved
  // out of the main FSM always_ff above (2026-08-27, second pass): with
  // c_valid/c_data already extracted, Vivado's synthesis started flagging
  // c_tag with the identical [Synth 8-7137] warning instead -- confirming
  // this is a whole-netlist optimization interaction, not a fixed property
  // of any one register in isolation.
  always_ff @(posedge clk) begin
    if (state == ST_FILL && mem_ready && &fill_word) begin
      c_tag[fill_idx] <= fill_tag;
    end
  end

  // c_valid: each entry's reset and its fill-complete set are combined into
  // one per-index, priority-ordered if/else (reset unconditionally wins)
  // instead of a whole-array reset for-loop plus a separately-indexed set
  // living elsewhere in the block -- the previous structure produced
  // Vivado's [Synth 8-7137] "Set and reset with same priority... may cause
  // simulation mismatches" warning on every c_valid bit (found 2026-08-27).
  always_ff @(posedge clk or negedge rst_n) begin
    for (int i = 0; i < SETS; i++) begin
      if (!rst_n) begin
        c_valid[i] <= 1'b0;
      end else if (fence_i) begin
        // FENCE.I invalidate-all. Priority above the fill-set below so a
        // fill that happens to complete on the same edge still ends up
        // invalid (conservative -- it just re-misses). In practice the CPU
        // only pulses fence_i while !any_stall, and imem_stall (asserted for
        // the whole ST_FILL) is part of any_stall, so this coincidence
        // cannot actually occur -- the priority is purely defensive.
        c_valid[i] <= 1'b0;
      end else if (state == ST_FILL && mem_ready && &fill_word && fill_idx == i[IDX_BITS-1:0]) begin
        c_valid[i] <= 1'b1;
      end
    end
  end

  // c_data: content is only ever trusted when c_valid is also true, so it
  // needs no reset value of its own -- a plain synchronous-only register
  // (no async control input at all) sidesteps the same set/reset-priority
  // ambiguity entirely, rather than relying on synthesis's implicit
  // default init value as a de facto "reset" alongside the fill write.
  always_ff @(posedge clk) begin
    if (state == ST_FILL && mem_ready) begin
      c_data[fill_idx][fill_word] <= mem_rdata;
    end
  end

  always_comb begin
    cpu_rdata   = '0;
    cache_stall = 1'b0;
    mem_addr    = '0;
    mem_ren     = 1'b0;

    case (state)
      ST_IDLE: begin
        if (req_hold) begin
          // cpu_addr isn't a resolved PA this cycle (ITLB miss, walk pending
          // or not yet started). Issue nothing to memory (no mem_ren, and
          // the sequential block above won't enter ST_FILL). Deliberately do
          // NOT assert cache_stall (2026-08-29): the CPU's own itlb_miss ->
          // stall_if / stall_if_id / ptw_stall machinery holds the pipeline
          // front. Asserting cache_stall here instead pins imem_stall (hence
          // any_stall) high for the entire ITLB walk, which deadlocks every
          // PTW state whose exit/trigger waits on it -- PTW_FAULT's exit
          // (cpu.sv fix #4), the PTW_IDLE walk-trigger when mem_wants_port
          // defers it, and PTW_DONE's `!imem_stall` exit gate. cpu_rdata
          // stays 0 and the CPU never consumes it while itlb_miss=1: if_id's
          // latch is gated by stall_if_id's itlb_miss term, and
          // if_is_jal / if_is_jalr are gated on !itlb_miss.
          cpu_rdata = '0;
        end else if (cache_hit) begin
          cpu_rdata = c_data[addr_idx][addr_word];
        end else begin
          cache_stall = 1'b1;
          mem_ren     = 1'b1;
          mem_addr    = {addr_tag, addr_idx, {WORD_BITS{1'b0}}, 2'b00};
        end
      end
      ST_FILL: begin
        cache_stall = 1'b1;
        mem_ren     = 1'b1;
        mem_addr    = {fill_tag, fill_idx, fill_word, 2'b00};
      end
      default: ;
    endcase
  end

endmodule
