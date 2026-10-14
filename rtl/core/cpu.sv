// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Eoghain Gray

import riscv_pkg::*;

// 5-stage pipelined RV32IM processor with branch prediction.
// Pipeline: IF → ID → EX → MEM → WB
// Data hazards:    EX-EX forwarding, MEM-EX forwarding, 1-cycle load-use stall
// Control hazards: 64-entry BTB + 2-bit counter; JAL decoded in IF; 0–2 cycle penalty
module cpu #(
  parameter logic [31:0] PC_RESET = 32'h80000000
)(
  input  logic        clk,
  input  logic        rst_n,

  output logic [31:0] imem_addr,
  input  logic [31:0] imem_data,
  // imem_req_hold (2026-08-28): high whenever imem_addr is NOT a resolved
  // physical address this cycle -- i.e. during an ITLB miss, when the mux
  // below falls through to the raw untranslated VA while the page-table walk
  // runs. The icache must not miss/fill/issue-AR on that raw VA (a
  // non-identity high-half alias is out of DRAM range and hangs the bus on
  // real hardware -- the 2026-08-28 Phase 2 boot-hang root cause). Wire
  // straight to icache.sv's req_hold input. See imem_addr's mux and
  // icache.sv's port comment.
  output logic        imem_req_hold,

  // imem_fence (2026-08-29, fix #6): 1-cycle pulse the cycle a FENCE.I
  // retires from EX. Wire straight to icache.sv's fence_i input -> it clears
  // every cache line's valid bit so the next fetch reloads instruction
  // memory as modified by prior data stores. This core's I/D caches are not
  // coherent and there is no snoop; without this, kernel .text patching
  // (runtime_const, jump labels, ftrace, kprobes, module load) is only
  // visible to fetch once a line happens to get evicted -- a race the
  // kernel's FENCE.I is supposed to close. See ex_real_redirect for the
  // companion pc_if redirect that re-fetches whatever was speculatively
  // fetched past the FENCE.I.
  output logic        imem_fence,

  (* mark_debug = "true" *) output logic [31:0] dmem_addr,
  output logic [31:0] dmem_wdata,
  output logic [3:0]  dmem_wmask,
  output logic        dmem_wen,
  (* mark_debug = "true" *) output logic        dmem_ren,
  (* mark_debug = "true" *) input  logic [31:0] dmem_rdata,
  (* mark_debug = "true" *) input  logic        dmem_stall, // asserted by dcache on a miss
  (* mark_debug = "true" *) input  logic        imem_stall, // asserted by icache on a miss

  // Phase 2: hardware-driven interrupt-pending lines (CLINT/PLIC), OR'd into
  // mip.MTIP/MEIP/MSIP below — mip storage itself stays software-writable
  // only for SSIP/STIP/SEIP (see csr_mip_sw/csr_mip_full).
  input  logic        irq_mtip,
  input  logic        irq_meip,
  input  logic        irq_msip,
  // irq_seip (2026-07-22): hardware-driven Supervisor External Interrupt
  // Pending, from the PLIC's own S-mode context (mirrors irq_meip's
  // existing pattern exactly, OR'd into csr_mip_full below). SEIP stays
  // additionally software-writable (MIP_SW_WRITABLE_MASK, unchanged) —
  // this only adds a hardware source alongside it, the same relationship
  // MTIP/MSIP/MEIP already have to their own CLINT/PLIC lines. Added
  // because Linux's stock irq-sifive-plic.c driver requires a genuine,
  // separate PLIC context for S-mode (this platform's PLIC previously had
  // only one, M-mode-only, context) — see rtl/periph/plic.sv's own
  // context-1 addition for the hardware side of this fix.
  input  logic        irq_seip,

  // Debug-only outputs (2026-07-30): raw PTW/ITLB/DTLB state, driven
  // straight from RTL rather than through any CPU instruction, so they
  // reflect real hardware state even if the pipeline never fetches
  // another instruction. Added to localize the real-hardware-only hang at
  // the first post-satp translated memory access, after Vivado's ILA
  // repeatedly failed to arm ("0 comparators available") -- found 2026-07-28.
  output logic [2:0]  dbg_ptw_state,
  output logic        dbg_ptw_active,
  output logic        dbg_itlb_miss,
  output logic        dbg_dtlb_miss,

  // dbg_pc_ptw_match (2026-07-30, nanoDLA capture round): 1 when pc_if
  // equals the VA the current/most recent PTW walk latched (ptw_va) — a
  // direct check of whether pc_if ever drifted away from the address the
  // walk was actually performed for, since LED rounds showed itlb_miss
  // still asserted even once ptw_state reaches PTW_DONE (which should be
  // impossible if pc_if stayed frozen and the fill matched it).
  output logic         dbg_pc_ptw_match,

  // dbg_itlb_hit/dbg_itlb_valid0/dbg_itlb_super0/dbg_itlb_tag_match_super/
  // dbg_itlb_tag_match_full (2026-07-30, follow-up round): a captured
  // imem_addr showed the CPU fetching via the raw, untranslated,
  // out-of-range VA (0xC0400000-ish, matching mmu_transition_test.S's own
  // CODE_HIGH_VPN1) despite pc_if==ptw_va — meaning the walk's fill
  // (itlb_valid[itlb_repl_ptr]<=1, itlb_vpn[itlb_repl_ptr]<=ptw_va[31:12])
  // should trivially satisfy the hit-check but apparently doesn't. Since
  // this is very likely the very first-ever ITLB fill this whole run
  // (if_translate_en reads 0 for ~4.78s beforehand per the nanoDLA
  // capture), itlb_repl_ptr should read 0 at fill time — these expose
  // entry 0 directly, plus both raw tag-match terms, to distinguish "the
  // valid bit didn't take" from "the tag data is wrong" from "the
  // comparison itself has a subtlety" without more netlist archaeology.
  output logic         dbg_itlb_hit,
  output logic         dbg_itlb_valid0,
  output logic         dbg_itlb_super0,
  output logic         dbg_itlb_tag_match_super,
  output logic         dbg_itlb_tag_match_full,

  // dbg_dtlb_hit/dbg_dtlb_valid0/dbg_dtlb_super0/dbg_ptw_acc (2026-07-31,
  // follow-up round): the multi-driven itlb_valid[]/dtlb_valid[] fix let
  // PHASE1_IDENTITY_MMU_OK print on real hardware
  // for the first time ever, but PHASE2_HIGHVA_MMU_OK now hangs instead —
  // LEDs at the hang read itlb_hit=1, suggesting ITLB translation itself
  // (including a second fill after a flush) works. Leading suspect is
  // DTLB-side translation for the UART MMIO write PHASE2's print needs
  // (Phase 1's checkpoint only needed ITLB); these mirror the itlb debug
  // ports for the DTLB, plus ptw_acc to tell whether the most recent walk
  // was even DTLB-triggered at all (PTW_ACC_LOAD/STORE/AMO vs _FETCH).
  output logic         dbg_dtlb_hit,
  output logic         dbg_dtlb_valid0,
  output logic         dbg_dtlb_super0,
  output logic [1:0]   dbg_ptw_acc,

  // dbg_if_is_jal/dbg_ex_redirect/dbg_flush_if_id (2026-08-08, follow-up
  // round): the icachevalid capture showed the fatal
  // icache tag-mismatch (icache.sv, index 6's second revisit) is uniquely
  // preceded by a taken branch/jump redirect (0x14005f -> 0x140058,
  // backward), unlike every other miss in the same trace, all reached by
  // plain sequential PC+4 progression. report_timing found no marginal
  // path anywhere near the tag array itself, reopening a non-timing
  // explanation: a burst of simultaneous pipeline-redirect switching
  // activity coinciding with (or just preceding) the tag array's read,
  // inducing a transient misread rather than a static timing violation.
  // These taps let a follow-up capture check the exact cycle-level timing
  // relationship directly instead of inferring it from addresses alone.
  output logic         dbg_if_is_jal,
  output logic         dbg_ex_redirect,
  output logic         dbg_flush_if_id,

  // dbg_id_ex_pc/dbg_id_ex_valid/dbg_id_ex_branch/dbg_id_ex_jump/
  // dbg_id_ex_jumpr (2026-08-08, follow-up round): the icachebr repro
  // test's own timing didn't match the original capture's -- ex_redirect
  // there was already held true starting from the exact cycle the
  // distractor line's OWN fetch began, before that line (and the branch
  // assumed to be its last word, 0x14005f) could possibly have finished
  // being fetched. A branch can't resolve before it's fetched, so the real
  // identity of whichever instruction is latched in id_ex during that
  // window is still genuinely unknown -- these taps let a follow-up
  // capture identify it directly (by PC) instead of continuing to infer it
  // from addresses and timing alone.
  output logic [31:0]  dbg_id_ex_pc,
  output logic         dbg_id_ex_valid,
  output logic         dbg_id_ex_branch,
  output logic         dbg_id_ex_jump,
  output logic         dbg_id_ex_jumpr
);

  // =========================================================================
  // Forward declarations — signals assigned in later pipeline stages
  // but needed in earlier stages for hazard/forwarding logic.
  // =========================================================================
  logic        load_use_hazard, ex_redirect;
  logic        ex_real_redirect;
  logic [31:0] ex_real_target;
  (* mark_debug = "true" *) logic        any_stall, amo_stall;
  logic        mul_stall, div_stall;   // iterative RV32M units busy in EX (see mul_unit/div_unit)
  logic        stall_if, stall_if_id, flush_if_id, flush_id_ex;
  logic        jalr_hold;   // freeze IF while an unpredicted JALR is unresolved (see stall_if)

  // EX/MEM register (needed by forwarding unit in EX)
  logic [31:0] ex_mem_alu_result, ex_mem_fwd_data;
  logic [4:0]  ex_mem_rd_addr;
  logic        ex_mem_reg_write;
  wb_sel_e     ex_mem_wb_sel;
  logic [31:0] ex_mem_pc, ex_mem_csr_rdata;
  // ex_mem_priv/ex_mem_eff_priv (2026-10-13): the privilege the EX/MEM
  // instruction actually executed under, latched with it. See mem_eff_priv.
  priv_mode_e  ex_mem_priv, ex_mem_eff_priv;
  logic        ex_mem_is_lr, ex_mem_is_sc, ex_mem_is_amo;
  logic [4:0]  ex_mem_amo_funct5;
  logic [31:0] sc_result;  // available combinationally in MEM; forward-decl for EX/MEM fwd mux

  // MEM/WB register (needed by forwarding unit in EX)
  logic [31:0] mem_wb_rd_data;
  logic [4:0]  mem_wb_rd_addr;
  logic        mem_wb_reg_write;
  // mem_wb_pc (2026-07-21): added specifically to symmetrically guard the
  // MEM/WB forwarding path against the same id_ex/duplication self-
  // reference bug already fixed for the EX/MEM path — see the forwarding
  // unit's own comment for the full diagnosis. No other consumer needs
  // this; it exists purely for that one comparison.
  logic [31:0] mem_wb_pc;

  // WB wires → register file write port
  logic [31:0] wb_rd_data;
  logic [4:0]  wb_rd_addr;
  logic        wb_reg_write;

  // =========================================================================
  // Branch Prediction — 64-entry BTB + 2-bit saturating counter
  // =========================================================================
  localparam int BTB_ENTRIES  = 64;
  localparam int BTB_IDX_BITS = 6;   // log2(64): index = pc[7:2]
  localparam int BTB_TAG_BITS = 24;  // tag = pc[31:8]

  logic              btb_valid  [BTB_ENTRIES];
  logic [BTB_TAG_BITS-1:0] btb_tag [BTB_ENTRIES];
  logic [31:0]       btb_target [BTB_ENTRIES];
  logic [1:0]        btb_cnt    [BTB_ENTRIES];  // 2-bit saturating counter

  initial begin
    for (int bi = 0; bi < BTB_ENTRIES; bi++) begin
      btb_valid[bi] = 1'b0;
      btb_cnt[bi]   = 2'b01;  // weakly not-taken until first execution
    end
  end

  // =========================================================================
  // IF — Instruction Fetch
  // =========================================================================
  (* mark_debug = "true" *) logic [31:0] pc_if, next_pc;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)         pc_if <= PC_RESET;
    else if (!stall_if) pc_if <= next_pc;
  end

  // Translation mux: inert until if_translate_en is true AND the ITLB actually
  // holds a matching entry (never true before the PTW below can fill it).
  // A superpage hit uses only PPN[1] (the entry's stored ppn[19:10]) with
  // VA[21:0] as the 4MB-page offset, instead of the full ppn with VA[11:0].
  assign imem_addr = (if_translate_en && itlb_hit) ?
                        (itlb_super[itlb_hit_idx] ? {itlb_ppn[itlb_hit_idx][19:10], pc_if[21:0]}
                                                   : {itlb_ppn[itlb_hit_idx], pc_if[11:0]})
                                                     : pc_if;

  // IF-stage prediction: BTB lookup + early JAL decode
  logic [BTB_IDX_BITS-1:0] if_btb_idx;
  logic [BTB_TAG_BITS-1:0] if_btb_tag_chk;
  logic              if_btb_hit;
  logic              if_pred_taken;
  logic [31:0]       if_pred_target;
  logic              if_is_jal;
  logic              if_is_jalr;
  logic [31:0]       if_jal_imm;

  assign if_btb_idx     = pc_if[BTB_IDX_BITS+1:2];
  assign if_btb_tag_chk = pc_if[31:BTB_IDX_BITS+2];
  assign if_btb_hit     = btb_valid[if_btb_idx] && (btb_tag[if_btb_idx] == if_btb_tag_chk);

  // JAL: opcode=1101111; decode target from instruction word (available from icache on hit)
  // !itlb_miss (2026-08-29): with the icache no longer asserting cache_stall
  // under req_hold (see icache.sv), imem_stall can read 0 while itlb_miss=1 and
  // imem_data is then stale/zero (cpu_rdata forced to 0). Gate the predecode on
  // !itlb_miss too so a phantom JAL/JALR can't be decoded off a non-instruction.
  assign if_is_jal  = (imem_data[6:0] == 7'b1101111) && !imem_stall && !itlb_miss;
  assign if_jal_imm = {{12{imem_data[31]}}, imem_data[19:12], imem_data[20], imem_data[30:21], 1'b0};
  assign dbg_if_is_jal = if_is_jal;

  // JALR: opcode=1100111. Its target needs rs1, which isn't available in IF, so
  // there is no early-redirect path like JAL's — without help, IF speculatively
  // fetches straight past a JALR down its fall-through path until EX resolves it
  // (~2 cycles later). For an *unpredicted* JALR (no BTB entry) that fall-through
  // is almost never the real path, so those fetches are pure waste — and worse,
  // if one crosses a cache line boundary its incidental icache miss asserts
  // `any_stall`, which gates `flush_if_id` off and DEFERS the JALR's own redirect
  // until that unrelated fill finishes. That deferred flush landing on the exact
  // cycle of the redirected re-fetch is the trigger for the real-hardware icache
  // tag-misread / `ST_RRESP` boot hang captured end-to-end 2026-08-28.
  // Fix: `jalr_hold` (near stall_if) freezes pc_if while an
  // unpredicted JALR is in IF or ID, so IF issues NO wrong-path fetch and the
  // redirect fires the moment the JALR reaches EX with `any_stall` clear.
  // BTB-predicted JALRs are unaffected — their speculation rides the normal
  // predict/verify path (if_pred_taken / ex_real_redirect).
  assign if_is_jalr = (imem_data[6:0] == 7'b1100111) && !imem_stall && !itlb_miss; // !itlb_miss: see if_is_jal

  always_comb begin
    if (if_is_jal) begin
      // JAL decoded in IF → 0-cycle penalty (deterministic target)
      if_pred_taken  = 1'b1;
      if_pred_target = pc_if + if_jal_imm;
    end else if (if_btb_hit && btb_cnt[if_btb_idx][1]) begin
      // BTB hit with counter ≥ 2: predict taken
      if_pred_taken  = 1'b1;
      if_pred_target = btb_target[if_btb_idx];
    end else begin
      if_pred_taken  = 1'b0;
      if_pred_target = pc_if + 32'd4;
    end
  end

  // =========================================================================
  // IF/ID Pipeline Register
  // =========================================================================
  logic [31:0] if_id_pc, if_id_instr;
  logic        if_id_pred_taken;
  logic [31:0] if_id_pred_target;
  // True only when if_id holds a real, freshly-fetched instruction — false
  // for exactly one cycle immediately after flush_if_id fires, before the
  // redirected fetch has had a chance to land in if_id. Without this,
  // id_ex_valid (below) is set unconditionally to 1 whenever id_ex
  // advances, regardless of whether if_id's *currently latched* content is
  // a genuine instruction or the just-flushed bubble (if_id_pc=0) — a
  // real, confirmed bug (found via direct signal tracing while writing
  // sim/clint-tests/clint_timer_irq_mid_jal_icache_miss.S): one cycle
  // after ANY flush (branch/jal/jalr misprediction, mret/sret/ecall,
  // page fault — not jal-specific), id_ex_valid reads 1 with id_ex_pc==0
  // for exactly one cycle, since id_ex naively latches whatever if_id_pc
  // held *before* if_id's own same-cycle update to the real redirect
  // target. If irq_taken_now (below) happens to fire on that exact
  // phantom-valid cycle, mepc/sepc get corrupted to 0. Gating id_ex_valid
  // on if_id_valid (both read pre-update, i.e. this cycle's stale value)
  // propagates the "not really valid yet" status forward by exactly the
  // one extra cycle needed, closing the race regardless of whether a
  // stall is involved.
  logic        if_id_valid;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n || flush_if_id) begin
      if_id_pc          <= '0;
      if_id_instr       <= 32'h0000_0013; // NOP = ADDI x0, x0, 0
      if_id_pred_taken  <= '0;
      if_id_pred_target <= '0;
      if_id_valid       <= 1'b0;
    end else if (!stall_if_id) begin
      if_id_pc          <= pc_if;
      if_id_instr       <= imem_data;
      if_id_pred_taken  <= if_pred_taken;
      if_id_pred_target <= if_pred_target;
      if_id_valid       <= 1'b1;
    end
  end

  // =========================================================================
  // ID — Decode + Register Read
  // =========================================================================
  logic [4:0]  id_rs1_addr, id_rs2_addr, id_rd_addr;
  logic [2:0]  id_funct3;
  logic [31:0] id_imm;
  alu_op_e     id_alu_op;
  logic        id_alu_src, id_alu_pc_a;
  logic        id_reg_write, id_mem_read, id_mem_write;
  wb_sel_e     id_wb_sel;
  logic        id_branch, id_jump, id_jumpr;
  logic        id_is_csr;
  csr_op_e     id_csr_op;
  logic        id_csr_imm, id_is_ecall, id_is_mret, id_is_sret, id_is_wfi, id_is_sfence_vma;
  logic        id_is_fence_i;
  logic        id_is_lr, id_is_sc, id_is_amo;
  logic [4:0]  id_amo_funct5;

  assign id_rd_addr  = if_id_instr[11:7];
  assign id_funct3   = if_id_instr[14:12];
  assign id_rs1_addr = if_id_instr[19:15];
  assign id_rs2_addr = if_id_instr[24:20];

  imm_gen u_imm_gen (.instr(if_id_instr), .imm(id_imm));

  control u_ctrl (
    .instr     (if_id_instr),
    .alu_op    (id_alu_op),    .alu_src   (id_alu_src),
    .alu_pc_a  (id_alu_pc_a), .reg_write (id_reg_write),
    .mem_read  (id_mem_read), .mem_write (id_mem_write),
    .wb_sel    (id_wb_sel),   .branch    (id_branch),
    .jump      (id_jump),     .jumpr     (id_jumpr),
    .is_csr    (id_is_csr),   .csr_op    (id_csr_op),
    .csr_imm   (id_csr_imm), .is_ecall  (id_is_ecall),
    .is_mret   (id_is_mret), .is_sret   (id_is_sret),
    .is_wfi    (id_is_wfi),  .is_sfence_vma (id_is_sfence_vma),
    .is_fence_i (id_is_fence_i),
    .is_lr     (id_is_lr),   .is_sc     (id_is_sc),
    .is_amo    (id_is_amo),  .amo_funct5(id_amo_funct5)
  );

  logic [31:0] id_rs1_data, id_rs2_data;

  regfile u_rf (
    .clk      (clk),          .we       (wb_reg_write),
    .rs1_addr (id_rs1_addr),  .rs2_addr (id_rs2_addr),
    .rd_addr  (wb_rd_addr),   .rd_data  (wb_rd_data),
    .rs1_data (id_rs1_data),  .rs2_data (id_rs2_data)
  );

  // =========================================================================
  // ID/EX Pipeline Register
  // =========================================================================
  logic [31:0] id_ex_pc, id_ex_rs1_data, id_ex_rs2_data, id_ex_imm;
  logic [4:0]  id_ex_rs1_addr, id_ex_rs2_addr, id_ex_rd_addr;
  logic [2:0]  id_ex_funct3;
  logic [11:0] id_ex_csr_addr;
  alu_op_e     id_ex_alu_op;
  logic        id_ex_alu_src, id_ex_alu_pc_a;
  logic        id_ex_reg_write, id_ex_mem_read, id_ex_mem_write;
  wb_sel_e     id_ex_wb_sel;
  logic        id_ex_branch, id_ex_jump, id_ex_jumpr;
  logic        id_ex_is_csr;
  csr_op_e     id_ex_csr_op;
  logic        id_ex_csr_imm, id_ex_is_ecall, id_ex_is_mret, id_ex_is_sret, id_ex_is_sfence_vma;
  logic        id_ex_is_fence_i;
  logic        id_ex_is_lr, id_ex_is_sc, id_ex_is_amo;
  logic [4:0]  id_ex_amo_funct5;
  logic        id_ex_pred_taken;
  logic [31:0] id_ex_pred_target;
  // True only when id_ex_* holds a real (non-bubble) instruction — needed
  // because the interrupt-pending check below is computed purely from CSR
  // state, independent of what's in id_ex, unlike ptw_fault_pending/
  // id_ex_is_ecall (naturally 0 on a flush bubble). Without this flag, an
  // interrupt landing on a bubble cycle (id_ex_pc==0) would corrupt mepc/sepc.
  logic        id_ex_valid;

  assign dbg_id_ex_pc     = id_ex_pc;
  assign dbg_id_ex_valid  = id_ex_valid;
  assign dbg_id_ex_branch = id_ex_branch;
  assign dbg_id_ex_jump   = id_ex_jump;
  assign dbg_id_ex_jumpr  = id_ex_jumpr;

  // id_ex_advance_ok (2026-07-22): the shared "may id_ex consume a fresh
  // if_id instruction this cycle" condition, extracted into its own signal
  // so flush_id_ex's id_ex_duplicate clause (far below) can consult it too.
  // Previously this exact expression was duplicated inline here and in
  // id_ex_fresh's always_ff below; now both reference this single signal.
  // Bug this closes: id_ex_duplicate (id_ex_pc==ex_mem_pc, meaning ex_mem
  // already caught up and holds the same stale instruction id_ex is frozen
  // on) unconditionally forced flush_id_ex, discarding if_id's own,
  // genuinely fresh, ready-to-advance content on the exact cycle a stall
  // (e.g. itlb_miss) that caused the duplicate happens to clear — losing
  // whatever if_id held (confirmed: a `jal` whose own fetch had succeeded
  // and was simply waiting one extra cycle to hand off, silently dropped,
  // its rd=ra write never happening). Excluding id_ex_advance_ok from that
  // clause lets id_ex properly ADVANCE (replacing the stale duplicate with
  // if_id's fresh content) instead of being bubbled in that specific case,
  // while leaving the original duplicate-flush behavior completely intact
  // whenever id_ex is NOT simultaneously ready to advance (the scenario
  // the duplicate-flush was originally added for: id_ex still frozen on
  // itlb_miss while ex_mem catches up — id_ex_advance_ok is false then too,
  // so flush_id_ex still fires exactly as before).
  logic id_ex_advance_ok;
  assign id_ex_advance_ok = !any_stall && !dtlb_miss && !itlb_miss &&
                            !(ptw_fault_pending && ptw_acc != PTW_ACC_FETCH);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n || flush_id_ex) begin
      id_ex_valid     <= 1'b0;
      id_ex_pc        <= '0;      id_ex_rs1_data  <= '0;
      id_ex_rs2_data  <= '0;      id_ex_imm       <= '0;
      id_ex_rs1_addr  <= '0;      id_ex_rs2_addr  <= '0;
      id_ex_rd_addr   <= '0;      id_ex_funct3    <= '0;
      id_ex_csr_addr  <= '0;      id_ex_alu_op    <= ALU_ADD;
      id_ex_alu_src   <= '0;      id_ex_alu_pc_a  <= '0;
      id_ex_reg_write <= '0;      id_ex_mem_read  <= '0;
      id_ex_mem_write <= '0;      id_ex_wb_sel    <= WB_ALU;
      id_ex_branch    <= '0;      id_ex_jump      <= '0;
      id_ex_jumpr     <= '0;      id_ex_is_csr    <= '0;
      id_ex_csr_op    <= CSR_NOP; id_ex_csr_imm   <= '0;
      id_ex_is_ecall  <= '0;      id_ex_is_mret   <= '0;
      id_ex_is_sret   <= '0;      id_ex_is_sfence_vma <= '0;
      id_ex_is_fence_i <= '0;
      id_ex_is_lr     <= '0;      id_ex_is_sc     <= '0;
      id_ex_is_amo    <= '0;      id_ex_amo_funct5 <= '0;
      id_ex_pred_taken  <= '0;
      id_ex_pred_target <= '0;
    end else if (id_ex_advance_ok) begin
      // ptw_fault_pending exclusion (2026-07-20, corrected — an earlier
      // version of this used the broad `ex_real_redirect` term, which
      // also covers id_ex being a genuine jal/jalr/branch needing its own
      // misprediction correction, unrelated to any PTW fault; excluding
      // the advance for THAT case broke ordinary JALR handling —
      // regression caught it immediately, rv32ui-p-jalr and
      // clint_timer_irq_mid_jalr both failed. The check must be scoped to
      // exactly the ptw_fault_pending condition, not the broader
      // redirect): mirrors ex_mem's own identical exclusion below (see
      // its much longer comment for the full diagnosis — a real,
      // confirmed bug: without this, id_ex could steal if_id's pre-flush
      // content on the same edge if_id is being flushed by flush_if_id
      // for this same fault, one stage earlier in the same "younger
      // instruction sneaks through a trap redirect" family). Added
      // symmetrically as a defensive measure — the concretely-reproduced
      // instance of this bug was one stage later (id_ex/ex_mem), but the
      // same mechanism structurally applies here too.
      // itlb_miss (2026-07-20, corrected — see flush_id_ex's comment for
      // why the original fix here was wrong): id_ex must not ADVANCE
      // (consume a new if_id instruction) while itlb_miss holds if_id
      // back, but critically must NOT be flushed either — id_ex may
      // already validly hold a completely different, ready-to-retire
      // instruction (e.g. a JAL about to write ra) that has nothing to do
      // with the fetch stage's current itlb_miss. Simply not advancing
      // (this term) preserves that instruction untouched for a later
      // cycle once !any_stall && !itlb_miss.
      // dtlb_miss (2026-07-20): id_ex must not advance (consume a new
      // if_id instruction) while ex_mem's current instruction is itself
      // waiting on a data-side translation — see dtlb_miss's own comment
      // near stall_if/stall_if_id above for the full mechanism. Simply not
      // advancing is sufficient here (unlike if_id, id_ex needs no
      // flush/bubble trick): it just holds its current content untouched.
      // Gated on if_id_valid (not unconditionally 1) — see if_id_valid's
      // own comment above for the phantom-bubble race this closes.
      id_ex_valid     <= if_id_valid;
      id_ex_pc        <= if_id_pc;           id_ex_rs1_data  <= id_rs1_data;
      id_ex_rs2_data  <= id_rs2_data;        id_ex_imm       <= id_imm;
      id_ex_rs1_addr  <= id_rs1_addr;        id_ex_rs2_addr  <= id_rs2_addr;
      id_ex_rd_addr   <= id_rd_addr;         id_ex_funct3    <= id_funct3;
      id_ex_csr_addr  <= if_id_instr[31:20];
      id_ex_alu_op    <= id_alu_op;          id_ex_alu_src   <= id_alu_src;
      id_ex_alu_pc_a  <= id_alu_pc_a;        id_ex_reg_write <= id_reg_write;
      id_ex_mem_read  <= id_mem_read;        id_ex_mem_write <= id_mem_write;
      id_ex_wb_sel    <= id_wb_sel;          id_ex_branch    <= id_branch;
      id_ex_jump      <= id_jump;            id_ex_jumpr     <= id_jumpr;
      id_ex_is_csr    <= id_is_csr;          id_ex_csr_op    <= id_csr_op;
      id_ex_csr_imm   <= id_csr_imm;         id_ex_is_ecall  <= id_is_ecall;
      id_ex_is_mret    <= id_is_mret;        id_ex_is_sret   <= id_is_sret;
      id_ex_is_sfence_vma <= id_is_sfence_vma;
      id_ex_is_fence_i <= id_is_fence_i;
      id_ex_is_lr      <= id_is_lr;       id_ex_is_sc      <= id_is_sc;
      id_ex_is_amo     <= id_is_amo;      id_ex_amo_funct5 <= id_amo_funct5;
      id_ex_pred_taken  <= if_id_pred_taken;
      id_ex_pred_target <= if_id_pred_target;
    end
  end

  // id_ex_fresh (2026-07-21): mirrors id_ex's own advance-enable condition
  // exactly (see id_ex's always_ff above), registered so downstream logic
  // can ask "did id_ex's *current* content just arrive this edge, or is it
  // a repeat of what id_ex already held" — independent of *which* specific
  // condition (itlb_miss, a lingering ptw_state==PTW_DONE stall, or
  // anything else) caused id_ex to freeze. Two consumers both need exactly
  // this signal, and both are described in full where they're used:
  // mem_wants_port's own exclusion (below) and the forwarding unit's
  // self-reference guard (further down). A genuine loop correctly shows
  // id_ex_fresh=1 on the cycle it re-fetches the same static PC as a new
  // dynamic iteration, so neither consumer misfires on legitimate
  // loop-carried dependencies — only on id_ex being genuinely stuck.
  logic id_ex_fresh;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n || flush_id_ex)
      id_ex_fresh <= 1'b0;
    else if (id_ex_advance_ok)
      id_ex_fresh <= 1'b1;
    else
      id_ex_fresh <= 1'b0;
  end

  // =========================================================================
  // EX — Execute
  // =========================================================================

  // Forwarding mux selects: 2'b10=EX/MEM, 2'b01=MEM/WB, 2'b00=register file
  logic [1:0]  fwd_a, fwd_b;
  logic [31:0] ex_fwd_rs1, ex_fwd_rs2;

  always_comb begin
    case (fwd_a)
      2'b10:   ex_fwd_rs1 = ex_mem_fwd_data;
      2'b01:   ex_fwd_rs1 = mem_wb_rd_data;
      default: ex_fwd_rs1 = id_ex_rs1_data;
    endcase
    case (fwd_b)
      2'b10:   ex_fwd_rs2 = ex_mem_fwd_data;
      2'b01:   ex_fwd_rs2 = mem_wb_rd_data;
      default: ex_fwd_rs2 = id_ex_rs2_data;
    endcase
  end

  // ALU
  logic [31:0] ex_alu_a, ex_alu_b, ex_alu_result;
  logic        ex_alu_zero;

  assign ex_alu_a = id_ex_alu_pc_a ? id_ex_pc  : ex_fwd_rs1;
  assign ex_alu_b = id_ex_alu_src  ? id_ex_imm : ex_fwd_rs2;

  alu u_alu (
    .a(ex_alu_a), .b(ex_alu_b), .op(id_ex_alu_op),
    .result(ex_alu_result), .zero(ex_alu_zero)
  );

  // =========================================================================
  // Multi-cycle RV32M multiply / divide  (ported from risc_2core/rtl/cpu.sv)
  // =========================================================================
  // The combinational 32x32 multiply and 32-bit divide used to live in alu.sv and
  // set the fabric critical path (~135 ns / Fmax ~8 MHz). They now run in the
  // iterative mul_unit (3 cyc) / div_unit (34 cyc), which freeze the pipeline via
  // mul_stall / div_stall OR'd into any_stall -- structurally identical to a
  // dcache-miss stall. An M-op never translates, touches memory, or traps, so it
  // does not interact with the PTW / AMO / trap machinery; every existing
  // !any_stall gate simply holds for the extra cycles. A div can only reach EX
  // once !any_stall held the cycle before, which guarantees the older instruction
  // in ex_mem already passed its DTLB check and cannot fault mid-compute.
  logic is_mul, is_div;
  assign is_mul = (id_ex_alu_op >= ALU_MUL) && (id_ex_alu_op <= ALU_MULHU);
  assign is_div = (id_ex_alu_op >= ALU_DIV) && (id_ex_alu_op <= ALU_REMU);

  logic       mul_busy, mul_done, div_busy, div_done;
  logic       mul_result_valid, div_result_valid;
  logic       mul_start, div_start;
  logic [1:0] mul_mode;   // [0]=sign_a, [1]=sign_b
  always_comb begin
    case (id_ex_alu_op)
      ALU_MULH:   mul_mode = 2'b11;
      ALU_MULHSU: mul_mode = 2'b01;
      default:    mul_mode = 2'b00;   // MUL / MULHU
    endcase
  end

  // Start on the first EX cycle of the M-op (not already running, no held result).
  assign mul_start = is_mul && !mul_busy && !mul_result_valid;
  assign div_start = is_div && !div_busy && !div_result_valid;

  // mul: result is registered the cycle BEFORE done fires -> stall may drop on done.
  // div: result is registered the SAME edge done fires   -> stall holds through done.
  assign mul_stall = is_mul && !mul_done && !mul_result_valid;
  assign div_stall = is_div && !div_result_valid;

  // *_result_valid holds a finished result in place while an UNRELATED older stall
  // (e.g. a dcache miss) keeps the pipeline frozen past the M-op's own completion.
  // Cleared when the M-op retires (!any_stall && is_*) or is squashed (flush_id_ex
  // -- only the id_ex_duplicate path can hit an M-op in EX; the units' abort input
  // resets their FSMs to match, so a re-issued M-op re-latches fresh operands).
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)                     mul_result_valid <= 1'b0;
    else if (flush_id_ex)           mul_result_valid <= 1'b0;
    else if (!any_stall && is_mul)  mul_result_valid <= 1'b0;
    else if (mul_done)              mul_result_valid <= 1'b1;
  end
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)                     div_result_valid <= 1'b0;
    else if (flush_id_ex)           div_result_valid <= 1'b0;
    else if (!any_stall && is_div)  div_result_valid <= 1'b0;
    else if (div_done)              div_result_valid <= 1'b1;
  end

  logic [63:0] mul_result;
  mul_unit u_mul (
    .clk    (clk),         .rst_n (rst_n),      .abort (flush_id_ex),
    .start  (mul_start),   .a     (ex_fwd_rs1), .b     (ex_fwd_rs2),
    .mode   (mul_mode),
    .busy   (mul_busy),    .done  (mul_done),   .result(mul_result)
  );

  logic [31:0] div_result;
  div_unit u_div (
    .clk       (clk),        .rst_n (rst_n),      .abort (flush_id_ex),
    .start     (div_start),  .a     (ex_fwd_rs1), .b     (ex_fwd_rs2),
    .is_signed ((id_ex_alu_op == ALU_DIV) || (id_ex_alu_op == ALU_REM)),
    .is_rem    ((id_ex_alu_op == ALU_REM) || (id_ex_alu_op == ALU_REMU)),
    .busy      (div_busy),   .done  (div_done),   .result(div_result)
  );

  // Final EX result: mul/div override the ALU output for an M-op.
  logic [31:0] ex_result;
  always_comb begin
    if (is_mul)
      ex_result = (id_ex_alu_op == ALU_MUL) ? mul_result[31:0] : mul_result[63:32];
    else if (is_div)
      ex_result = div_result;
    else
      ex_result = ex_alu_result;
  end

  // Branch condition using forwarded register values
  logic ex_branch_taken;
  always_comb begin
    case (id_ex_funct3)
      3'b000: ex_branch_taken = (ex_fwd_rs1 == ex_fwd_rs2);
      3'b001: ex_branch_taken = (ex_fwd_rs1 != ex_fwd_rs2);
      3'b100: ex_branch_taken = ($signed(ex_fwd_rs1) < $signed(ex_fwd_rs2));
      3'b101: ex_branch_taken = ($signed(ex_fwd_rs1) >= $signed(ex_fwd_rs2));
      3'b110: ex_branch_taken = (ex_fwd_rs1 < ex_fwd_rs2);
      3'b111: ex_branch_taken = (ex_fwd_rs1 >= ex_fwd_rs2);
      default: ex_branch_taken = 1'b0;
    endcase
  end

  // CSR register file — sparse (~22 architectural CSRs), not a full 4096-entry
  // array. Upstream cpu.sv modeled csr_regs as logic[31:0] [0:4095] (one
  // flip-flop group per possible 12-bit CSR address), which is harmless for
  // ASIC/sim but synthesizes to >130K FFs on real FPGA fabric — this was the
  // dominant cause of the xc7z007s DRC overflow. Only these CSRs are ever
  // read or written by this core's CSR/exception logic.
  localparam CSR_MHARTID  = 12'hF14;
  localparam CSR_MISA     = 12'h301;
  localparam CSR_MSTATUS  = 12'h300;
  localparam CSR_MTVEC    = 12'h305;
  localparam CSR_MEPC     = 12'h341;
  localparam CSR_MCAUSE   = 12'h342;
  localparam CSR_SSTATUS  = 12'h100;
  localparam CSR_SIE      = 12'h104;
  localparam CSR_STVEC    = 12'h105;
  localparam CSR_SSCRATCH = 12'h140;
  localparam CSR_SEPC     = 12'h141;
  localparam CSR_SCAUSE   = 12'h142;
  localparam CSR_STVAL    = 12'h143;
  localparam CSR_SIP      = 12'h144;
  localparam CSR_SATP     = 12'h180;
  localparam CSR_MEDELEG  = 12'h302;
  localparam CSR_MIDELEG  = 12'h303;
  localparam CSR_MIE      = 12'h304;
  localparam CSR_MSCRATCH = 12'h340;
  localparam CSR_MTVAL    = 12'h343;
  localparam CSR_MIP      = 12'h344;
  localparam CSR_PMPCFG0  = 12'h3A0;
  localparam CSR_PMPADDR0 = 12'h3B0;
  // Unprivileged counter/timer (Zicntr). Only `time`/`timeh` are wired -- the
  // kernel's arch/riscv/lib/delay.c __delay() spins on rdtime, so an
  // unimplemented `time` (default CSR case -> reads 0) makes every udelay/
  // mdelay/wait_for_xmitr busy-wait loop forever. Read-only: the CSR write
  // case below has no entry for these, so writes are silently dropped (as for
  // mhartid/misa). See csr_time_ctr below.
  localparam CSR_TIME     = 12'hC01;
  localparam CSR_TIMEH    = 12'hC81;

  // sstatus is a masked read/write view of mstatus (SUM|MXR|SPP|SPIE|SIE only);
  // sie/sip are masked views of mie/mip restricted to S-mode interrupt bits.
  localparam logic [31:0] SSTATUS_MASK = 32'h000C_0122;
  localparam logic [31:0] SIE_MASK     = 32'h0000_0222;

  logic [31:0] csr_mhartid, csr_misa, csr_mtvec, csr_mepc, csr_mcause;

  // mstatus, decomposed into individual fields rather than one flat
  // register: sstatus (0x100) is a masked read/write *view* of the same
  // bits as mstatus (0x300), and MRET/SRET/trap-entry hardware needs to
  // update individual fields independently of software CSR writes.
  priv_mode_e  priv_mode;
  logic        mstatus_mie, mstatus_mpie, mstatus_sie, mstatus_spie, mstatus_spp;
  priv_mode_e  mstatus_mpp;
  logic        mstatus_mprv, mstatus_mxr, mstatus_sum;
  // All other mstatus bits (FS/XS/VS/TVM/TW/TSR/UBE/SD) are hardwired 0 on
  // read and ignored on write in Phase 0 — out of scope (no FPU, no S-mode
  // TVM/TW/TSR enforcement, no virtual memory yet).

  logic [31:0] csr_medeleg, csr_mideleg, csr_mie, csr_mip_sw, csr_mscratch, csr_mtval;
  logic [31:0] csr_stvec, csr_sepc, csr_scause, csr_stval, csr_sscratch;
  (* mark_debug = "true" *) logic [31:0] csr_satp;
  logic [31:0] csr_pmpaddr0;
  logic [7:0]  csr_pmpcfg0;

  logic [31:0] ex_csr_rdata, ex_csr_rs1_val, ex_csr_wdata;
  logic        ex_csr_we;

  // Full 32-bit mstatus view, reassembled from the decomposed fields above.
  function automatic logic [31:0] compose_mstatus(
    input priv_mode_e mpp, input logic spp, input logic mprv,
    input logic sum_, input logic mxr,
    input logic mpie, input logic spie, input logic mie, input logic sie
  );
    compose_mstatus = {1'b0, 8'b0, 1'b0, 1'b0, 1'b0, mxr, sum_, mprv, 2'b0, 2'b0,
                        mpp, 2'b0, spp, mpie, 1'b0, spie, 1'b0, mie, 1'b0, sie, 1'b0};
  endfunction

  logic [31:0] mstatus_full;
  assign mstatus_full = compose_mstatus(mstatus_mpp, mstatus_spp, mstatus_mprv,
                                         mstatus_sum, mstatus_mxr,
                                         mstatus_mpie, mstatus_spie, mstatus_mie, mstatus_sie);

  // mip, decomposed the same way mstatus is: csr_mip_sw stores only the
  // software-writable bits (SSIP/STIP/SEIP — the only mip bits that can
  // never be hardware-driven, since M-level interrupts can't be delegated);
  // MTIP/MEIP/MSIP are hardware-driven directly from CLINT/PLIC and OR'd in
  // here for CSR reads and the interrupt-arbitration logic below. Software
  // writes to mip (CSR_MIP/CSR_SIP cases below) are masked to
  // MIP_SW_WRITABLE_MASK so they can no longer stomp the hardware bits.
  logic [31:0] csr_mip_full;
  assign csr_mip_full = csr_mip_sw
                      | (irq_mtip ? (32'h1 << MIP_MTIP_BIT) : 32'h0)
                      | (irq_meip ? (32'h1 << MIP_MEIP_BIT) : 32'h0)
                      | (irq_msip ? (32'h1 << MIP_MSIP_BIT) : 32'h0)
                      | (irq_seip ? (32'h1 << MIP_SEIP_BIT) : 32'h0);

  // Free-running 64-bit time counter for the `time`/`timeh` CSRs. Ticks once
  // per core clock -- identical construction to clint.sv's mtime (both reset
  // to 0 on rst_n, both += 1 every clk), so rdtime == the CLINT mtimer and
  // matches the DT's `timebase-frequency` (real hardware: clk_core, derived
  // from MIG's ui_clk -- 18,753,922 Hz, see fpga/genesys2_top_ddr.sv's own
  // clk_core header comment). Without this,
  // rdtime read 0 and arch/riscv/lib/delay.c __delay() spun forever the first
  // time the kernel hit a real busy-wait delay (8250 wait_for_xmitr under TX
  // backpressure, right after "Run /init"). Sim missed it: the zero-latency
  // UART model never makes wait_for_xmitr wait. No overflow handling: 64 bits
  // at a few MHz never wraps in any realistic run.
  logic [63:0] csr_time_ctr;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) csr_time_ctr <= 64'd0;
    else        csr_time_ctr <= csr_time_ctr + 64'd1;
  end

  always_comb begin
    case (id_ex_csr_addr)
      CSR_MHARTID:  ex_csr_rdata = csr_mhartid;
      CSR_MISA:     ex_csr_rdata = csr_misa;
      CSR_MSTATUS:  ex_csr_rdata = mstatus_full;
      CSR_SSTATUS:  ex_csr_rdata = mstatus_full & SSTATUS_MASK;
      CSR_MEDELEG:  ex_csr_rdata = csr_medeleg;
      CSR_MIDELEG:  ex_csr_rdata = csr_mideleg;
      CSR_MIE:      ex_csr_rdata = csr_mie;
      CSR_MTVEC:    ex_csr_rdata = csr_mtvec;
      CSR_MSCRATCH: ex_csr_rdata = csr_mscratch;
      CSR_MEPC:     ex_csr_rdata = csr_mepc;
      CSR_MCAUSE:   ex_csr_rdata = csr_mcause;
      CSR_MTVAL:    ex_csr_rdata = csr_mtval;
      CSR_MIP:      ex_csr_rdata = csr_mip_full;
      CSR_PMPCFG0:  ex_csr_rdata = {24'b0, csr_pmpcfg0};
      CSR_PMPADDR0: ex_csr_rdata = csr_pmpaddr0;
      CSR_SIE:      ex_csr_rdata = csr_mie & SIE_MASK;
      CSR_STVEC:    ex_csr_rdata = csr_stvec;
      CSR_SSCRATCH: ex_csr_rdata = csr_sscratch;
      CSR_SEPC:     ex_csr_rdata = csr_sepc;
      CSR_SCAUSE:   ex_csr_rdata = csr_scause;
      CSR_STVAL:    ex_csr_rdata = csr_stval;
      CSR_SIP:      ex_csr_rdata = csr_mip_full & SIE_MASK;
      CSR_SATP:     ex_csr_rdata = csr_satp;
      CSR_TIME:     ex_csr_rdata = csr_time_ctr[31:0];
      CSR_TIMEH:    ex_csr_rdata = csr_time_ctr[63:32];
      default:      ex_csr_rdata = 32'b0;
    endcase
  end

  assign ex_csr_rs1_val = id_ex_csr_imm ? {27'b0, id_ex_rs1_addr} : ex_fwd_rs1;

  always_comb begin
    case (id_ex_csr_op)
      CSR_RW:  ex_csr_wdata = ex_csr_rs1_val;
      CSR_RS:  ex_csr_wdata = ex_csr_rdata |  ex_csr_rs1_val;
      CSR_RC:  ex_csr_wdata = ex_csr_rdata & ~ex_csr_rs1_val;
      default: ex_csr_wdata = ex_csr_rdata;
    endcase
    ex_csr_we = id_ex_is_csr && (id_ex_csr_op != CSR_NOP);
  end

  // ECALL cause selection + delegation gate. Traps are never delegated to a
  // mode >= current mode; M-mode callers always trap to M (medeleg has no
  // effect there, since M-mode traps can't be delegated per spec).
  logic [31:0] ecall_cause;
  logic        ecall_delegated;
  always_comb begin
    case (priv_mode)
      PRIV_M:  ecall_cause = CAUSE_MACHINE_ECALL;
      PRIV_S:  ecall_cause = CAUSE_SUPERVISOR_ECALL;
      default: ecall_cause = CAUSE_USER_ECALL;
    endcase
    ecall_delegated = (priv_mode != PRIV_M) && csr_medeleg[ecall_cause];
  end

  // =========================================================================
  // Interrupt-pending/priority arbitration (Phase 2). Priority (highest
  // first): MEI > MSI > MTI > SEI > SSI > STI, per the priv spec. Only bits
  // 1/5/9 (S*I) have a legal mideleg position — M-level interrupts (bits
  // 3/7/11) can never be delegated, matching real hardware. Evaluated every
  // cycle, independent of pipeline contents (gated by id_ex_valid below) —
  // unlike ptw_fault_pending/id_ex_is_ecall, which are tied to a specific
  // in-flight access/instruction.
  // =========================================================================
  logic [31:0] pending_en;
  assign pending_en = csr_mip_full & csr_mie;

  // Whether a given S-mode-targetable interrupt bit is actually delegated.
  function automatic logic irq_deleg_s(input int bit_idx);
    irq_deleg_s = (bit_idx == MIP_SSIP_BIT || bit_idx == MIP_STIP_BIT || bit_idx == MIP_SEIP_BIT)
                  && csr_mideleg[bit_idx];
  endfunction

  // Global interrupt-enable gate for the target privilege level a bit would
  // trap into: an M-mode target is always enabled while running below M, and
  // gated by mstatus.MIE while running in M; an S-mode target is always
  // enabled while running in U, and gated by mstatus.SIE while running in S.
  function automatic logic irq_enabled_at(input logic to_s);
    irq_enabled_at = to_s ? ((priv_mode == PRIV_U) || (priv_mode == PRIV_S && mstatus_sie))
                          : ((priv_mode != PRIV_M) || mstatus_mie);
  endfunction

  logic        irq_take;
  logic [31:0] irq_cause;
  priv_mode_e  irq_priv;
  always_comb begin
    irq_take  = 1'b0;
    irq_cause = 32'h0;
    irq_priv  = PRIV_M;
    if (pending_en[MIP_MEIP_BIT] && irq_enabled_at(1'b0)) begin
      irq_take = 1'b1; irq_priv = PRIV_M; irq_cause = CAUSE_MACHINE_EXTERNAL_INT;
    end else if (pending_en[MIP_MSIP_BIT] && irq_enabled_at(1'b0)) begin
      irq_take = 1'b1; irq_priv = PRIV_M; irq_cause = CAUSE_MACHINE_SOFTWARE_INT;
    end else if (pending_en[MIP_MTIP_BIT] && irq_enabled_at(1'b0)) begin
      irq_take = 1'b1; irq_priv = PRIV_M; irq_cause = CAUSE_MACHINE_TIMER_INT;
    end else if (pending_en[MIP_SEIP_BIT] && irq_enabled_at(irq_deleg_s(MIP_SEIP_BIT))) begin
      irq_take  = 1'b1;
      irq_priv  = irq_deleg_s(MIP_SEIP_BIT) ? PRIV_S : PRIV_M;
      irq_cause = irq_deleg_s(MIP_SEIP_BIT) ? CAUSE_SUPERVISOR_EXTERNAL_INT : CAUSE_MACHINE_EXTERNAL_INT;
    end else if (pending_en[MIP_SSIP_BIT] && irq_enabled_at(irq_deleg_s(MIP_SSIP_BIT))) begin
      irq_take  = 1'b1;
      irq_priv  = irq_deleg_s(MIP_SSIP_BIT) ? PRIV_S : PRIV_M;
      irq_cause = irq_deleg_s(MIP_SSIP_BIT) ? CAUSE_SUPERVISOR_SOFTWARE_INT : CAUSE_MACHINE_SOFTWARE_INT;
    end else if (pending_en[MIP_STIP_BIT] && irq_enabled_at(irq_deleg_s(MIP_STIP_BIT))) begin
      irq_take  = 1'b1;
      irq_priv  = irq_deleg_s(MIP_STIP_BIT) ? PRIV_S : PRIV_M;
      irq_cause = irq_deleg_s(MIP_STIP_BIT) ? CAUSE_SUPERVISOR_TIMER_INT : CAUSE_MACHINE_TIMER_INT;
    end
  end

  // True on a cycle where an interrupt actually preempts the instruction
  // sitting in id_ex. Excludes id_ex_is_ecall/mret/sret so a synchronous
  // trap/return already committing this cycle takes priority (matches
  // ptw_fault_pending's precedent of being pipeline-inert traps that don't
  // need this exclusion — an interrupt is the first source that can land on
  // an arbitrary, non-inert instruction, hence also needing the EX/MEM
  // squash further below).
  logic irq_taken_now;
  assign irq_taken_now = irq_take && id_ex_valid && !any_stall &&
                         !id_ex_is_ecall && !id_ex_is_mret && !id_ex_is_sret;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      csr_mhartid  <= 32'h0000_0000;
      csr_misa     <= 32'h4014_0100; // RV32IM + S + U  (bit18=S, bit20=U)
      csr_mtvec    <= PC_RESET + 32'h4; // default trap, tracks PC_RESET
      csr_mepc     <= 32'h0000_0000;
      csr_mcause   <= 32'h0000_0000;

      priv_mode    <= PRIV_M;
      mstatus_mpp  <= PRIV_M;
      mstatus_spp  <= 1'b0;
      mstatus_mie  <= 1'b0; mstatus_mpie <= 1'b0;
      mstatus_sie  <= 1'b0; mstatus_spie <= 1'b0;
      mstatus_mprv <= 1'b0; mstatus_mxr  <= 1'b0; mstatus_sum <= 1'b0;

      csr_medeleg  <= 32'h0; csr_mideleg <= 32'h0;
      csr_mie      <= 32'h0; csr_mip_sw  <= 32'h0;
      csr_mscratch <= 32'h0; csr_mtval  <= 32'h0;
      csr_stvec    <= 32'h0; csr_sepc    <= 32'h0; csr_scause <= 32'h0;
      csr_stval    <= 32'h0; csr_sscratch <= 32'h0; csr_satp  <= 32'h0;

      // Permissive-by-construction PMP: TOR, R=W=X=1, upper bound spans all
      // 32-bit space. Per spec, zero configured PMP entries denies S/U-mode
      // all memory access — resetting to a fully-open single region avoids
      // that trap without needing real enforcement logic in the address
      // path (nothing in Phase 0 relies on PMP faults; OpenSBI will
      // reprogram this itself in Phase 4 before dropping to S-mode).
      csr_pmpcfg0  <= 8'h0F;
      csr_pmpaddr0 <= 32'hFFFF_FFFF;
    end else if (ptw_fault_pending) begin
      // Parallel fourth trap source alongside ECALL/MRET/SRET above — a PTW
      // fault has no decoded instruction sitting in id_ex_* (IF never
      // finished fetching, or the faulting load/store's own id_ex_is_ecall
      // etc. are all 0), so it's injected directly here rather than
      // threaded through the normal instruction-decode path. This branch
      // re-fires every cycle ptw_fault_pending is true (a level, not a
      // pulse — see its declaration) with the same stable, latched inputs,
      // so repeated (idempotent) writes while waiting out an unrelated
      // stall are harmless.
      if (ptw_delegated) begin
        csr_sepc     <= ptw_epc;
        csr_scause   <= ptw_fault_cause;
        csr_stval    <= ptw_va;
        mstatus_spp  <= (ptw_priv == PRIV_S);
        mstatus_spie <= mstatus_sie;
        mstatus_sie  <= 1'b0;
        priv_mode    <= PRIV_S;
      end else begin
        csr_mepc     <= ptw_epc;
        csr_mcause   <= ptw_fault_cause;
        csr_mtval    <= ptw_va;
        mstatus_mpp  <= ptw_priv;
        mstatus_mpie <= mstatus_mie;
        mstatus_mie  <= 1'b0;
        priv_mode    <= PRIV_M;
      end
    end else if (irq_taken_now) begin
      // A pending, enabled interrupt preempts whatever's in id_ex this
      // cycle. Lower priority than a page fault or any synchronous
      // trap/return already committing this cycle (irq_taken_now's own
      // definition already excludes ecall/mret/sret) — per spec, a
      // synchronous exception on the currently-committing instruction
      // always wins; the interrupt is a level, not a pulse, so nothing is
      // lost by deferring it one cycle.
      if (irq_priv == PRIV_S) begin
        csr_sepc     <= id_ex_pc;
        csr_scause   <= irq_cause;
        csr_stval    <= 32'h0;
        mstatus_spp  <= (priv_mode == PRIV_S);
        mstatus_spie <= mstatus_sie;
        mstatus_sie  <= 1'b0;
        priv_mode    <= PRIV_S;
      end else begin
        csr_mepc     <= id_ex_pc;
        csr_mcause   <= irq_cause;
        csr_mtval    <= 32'h0;
        mstatus_mpp  <= priv_mode;
        mstatus_mpie <= mstatus_mie;
        mstatus_mie  <= 1'b0;
        priv_mode    <= PRIV_M;
      end
    end else if (!any_stall) begin
      if (ex_csr_we) begin
        case (id_ex_csr_addr)
          CSR_MISA: csr_misa <= ex_csr_wdata;
          CSR_MSTATUS: begin
            mstatus_mpp  <= priv_mode_e'(ex_csr_wdata[12:11]);
            mstatus_spp  <= ex_csr_wdata[8];
            mstatus_mpie <= ex_csr_wdata[7];
            mstatus_spie <= ex_csr_wdata[5];
            mstatus_mie  <= ex_csr_wdata[3];
            mstatus_sie  <= ex_csr_wdata[1];
            mstatus_mprv <= ex_csr_wdata[17];
            mstatus_sum  <= ex_csr_wdata[18];
            mstatus_mxr  <= ex_csr_wdata[19];
          end
          CSR_SSTATUS: begin
            mstatus_spp  <= ex_csr_wdata[8];
            mstatus_spie <= ex_csr_wdata[5];
            mstatus_sie  <= ex_csr_wdata[1];
            mstatus_sum  <= ex_csr_wdata[18];
            mstatus_mxr  <= ex_csr_wdata[19];
          end
          CSR_MEDELEG:  csr_medeleg  <= ex_csr_wdata;
          CSR_MIDELEG:  csr_mideleg  <= ex_csr_wdata;
          CSR_MIE:      csr_mie      <= ex_csr_wdata & MIE_MASK;
          CSR_MTVEC:    csr_mtvec    <= ex_csr_wdata;
          CSR_MSCRATCH: csr_mscratch <= ex_csr_wdata;
          CSR_MEPC:     csr_mepc     <= ex_csr_wdata;
          CSR_MCAUSE:   csr_mcause   <= ex_csr_wdata;
          CSR_MTVAL:    csr_mtval    <= ex_csr_wdata;
          CSR_MIP:      csr_mip_sw   <= (csr_mip_sw & ~MIP_SW_WRITABLE_MASK) | (ex_csr_wdata & MIP_SW_WRITABLE_MASK);
          CSR_PMPCFG0:  csr_pmpcfg0  <= ex_csr_wdata[7:0];
          CSR_PMPADDR0: csr_pmpaddr0 <= ex_csr_wdata;
          CSR_SIE:      csr_mie      <= (csr_mie & ~SIE_MASK) | (ex_csr_wdata & SIE_MASK);
          CSR_STVEC:    csr_stvec    <= ex_csr_wdata;
          CSR_SSCRATCH: csr_sscratch <= ex_csr_wdata;
          CSR_SEPC:     csr_sepc     <= ex_csr_wdata;
          CSR_SCAUSE:   csr_scause   <= ex_csr_wdata;
          CSR_STVAL:    csr_stval    <= ex_csr_wdata;
          CSR_SIP:      csr_mip_sw   <= (csr_mip_sw & ~SIE_MASK) | (ex_csr_wdata & SIE_MASK);
          CSR_SATP:     csr_satp     <= ex_csr_wdata;
          default: ;
        endcase
      end

      if (id_ex_is_ecall) begin
        if (ecall_delegated) begin
          csr_sepc     <= id_ex_pc;
          csr_scause   <= ecall_cause;
          csr_stval    <= 32'h0;
          mstatus_spp  <= (priv_mode == PRIV_S);
          mstatus_spie <= mstatus_sie;
          mstatus_sie  <= 1'b0;
          priv_mode    <= PRIV_S;
        end else begin
          csr_mepc     <= id_ex_pc;
          csr_mcause   <= ecall_cause;
          csr_mtval    <= 32'h0;
          mstatus_mpp  <= priv_mode;
          mstatus_mpie <= mstatus_mie;
          mstatus_mie  <= 1'b0;
          priv_mode    <= PRIV_M;
        end
      end

      if (id_ex_is_mret) begin
        // Non-blocking assigns: priv_mode <= mstatus_mpp reads the
        // pre-update value of mstatus_mpp even though mstatus_mpp is
        // written in this same block — order in source doesn't matter here.
        priv_mode    <= mstatus_mpp;
        mstatus_mie  <= mstatus_mpie;
        mstatus_mpie <= 1'b1;
        mstatus_mpp  <= PRIV_U;
        if (mstatus_mpp != PRIV_M) mstatus_mprv <= 1'b0;
      end

      if (id_ex_is_sret) begin
        priv_mode    <= mstatus_spp ? PRIV_S : PRIV_U;
        mstatus_sie  <= mstatus_spie;
        mstatus_spie <= 1'b1;
        mstatus_spp  <= 1'b0;
        mstatus_mprv <= 1'b0;
      end
    end
  end

  // PC redirect target (computed in EX)
  logic [31:0] ex_target_pc;
  always_comb begin
    if (ptw_fault_pending)
      ex_target_pc = ptw_delegated ? {csr_stvec[31:2], 2'b00} : {csr_mtvec[31:2], 2'b00};
    else if (irq_taken_now)
      ex_target_pc = (irq_priv == PRIV_S) ? {csr_stvec[31:2], 2'b00} : {csr_mtvec[31:2], 2'b00};
    else if (id_ex_is_ecall)
      ex_target_pc = ecall_delegated ? {csr_stvec[31:2], 2'b00} : {csr_mtvec[31:2], 2'b00};
    else if (id_ex_is_mret)  ex_target_pc = csr_mepc;
    else if (id_ex_is_sret)  ex_target_pc = csr_sepc;
    else if (id_ex_jumpr)    ex_target_pc = {ex_alu_result[31:1], 1'b0};
    else                     ex_target_pc = id_ex_pc + id_ex_imm; // JAL, branch
  end

  assign ex_redirect = ptw_fault_pending || irq_taken_now || id_ex_jump || id_ex_jumpr ||
                       (id_ex_branch && ex_branch_taken) ||
                       id_ex_is_ecall || id_ex_is_mret || id_ex_is_sret;
  assign dbg_ex_redirect = ex_redirect;

  // imem_fence (2026-08-29, fix #6): FENCE.I retiring from EX. Mirrors
  // tlb_flush's shape ("retire" == the op is in id_ex, valid, and not
  // stalled), and defers to a same-cycle trap (ptw_fault_pending /
  // irq_taken_now) so the fault/interrupt redirect wins and the FENCE.I
  // simply re-executes afterward. Pulses icache.sv's fence_i (invalidate
  // all) and forces the pc_if redirect below.
  logic fence_i_retire;
  assign fence_i_retire = id_ex_is_fence_i && id_ex_valid && !any_stall &&
                          !ptw_fault_pending && !irq_taken_now;
  assign imem_fence = fence_i_retire;

  // =========================================================================
  // MMU — Sv32 page table walker + TLB (Phase 1)
  // =========================================================================

  // satp decode (pure wires — csr_satp itself is unchanged Phase-0 storage).
  // PPN truncated from the spec's 22-bit field to 20 bits: imem_addr/dmem_addr
  // are 32-bit ports, so physical addresses are capped at 32 bits here; PPN
  // bits [21:20] are silently ignored if software sets them. Deliberate scope
  // decision, not a bug — documented non-goal for this bring-up.
  logic        satp_mode;
  logic [19:0] satp_ppn;
  assign satp_mode = csr_satp[31];
  assign satp_ppn  = csr_satp[19:0];

  // Translation-enable signals. mstatus_mprv/mstatus_mpp must appear ONLY in
  // the MEM-side (data) signals below, never in if_translate_en — MPRV
  // affects data accesses only, never instruction fetch.
  priv_mode_e  mem_eff_priv;
  logic        if_translate_en, mem_translate_en;
  // mem_eff_priv is the EX/MEM instruction's OWN latched effective privilege
  // (2026-10-13), not the live priv_mode/MPRV. Live state can run ahead of
  // that instruction: an instruction-page-fault trap commits (ptw_fault_
  // pending, priv_mode -> S) without waiting for an older load/store still
  // stalled in EX/MEM, so a user store finishing after a fetch fault was
  // checked as an S-mode access to a U page (spurious store fault at /init
  // startup once DTLB hits began re-checking permissions, see dtlb_hit).
  // CSR writes and xRET still update this in program order: they commit
  // from EX, so the next instruction to enter EX/MEM latches the new value.
  assign mem_eff_priv     = ex_mem_eff_priv;
  assign if_translate_en  = satp_mode && (priv_mode != PRIV_M);
  assign mem_translate_en = satp_mode && (mem_eff_priv != PRIV_M);

  // ITLB / DTLB — 8-entry fully-associative, FIFO replacement, no ASID tag
  // (ASID lives in satp but is never consulted — every sfence.vma AND every
  // satp write does a full flush instead of ASID-selective flushing).
  localparam int ITLB_ENTRIES = 8;
  localparam int DTLB_ENTRIES = 8;

  // itlb_super/dtlb_super (2026-07-16, superpage support): marks an entry as
  // a 4MB leaf-at-level-1 translation rather than an ordinary 4KB leaf-at-
  // level-0 one. Only itlb_vpn[i][19:10]/dtlb_vpn[i][19:10] (VPN[1]) are
  // meaningful for a super entry's tag match — VPN[0] is ignored, matching
  // how any VA within the 4MB region must hit. Must be written on every
  // fill path (both the L1-leaf and L2-leaf cases below), never left
  // implicit — FIFO replacement reuses slots, so a stale value from a
  // previous occupant would otherwise silently mismatch a new entry's kind.
  logic        itlb_valid [ITLB_ENTRIES];
  logic [19:0] itlb_vpn   [ITLB_ENTRIES];
  logic [19:0] itlb_ppn   [ITLB_ENTRIES];
  logic        itlb_x     [ITLB_ENTRIES];
  logic        itlb_u     [ITLB_ENTRIES];
  logic        itlb_super [ITLB_ENTRIES];
  logic [2:0]  itlb_repl_ptr;

  logic        dtlb_valid [DTLB_ENTRIES];
  logic [19:0] dtlb_vpn   [DTLB_ENTRIES];
  logic [19:0] dtlb_ppn   [DTLB_ENTRIES];
  logic        dtlb_r     [DTLB_ENTRIES];
  logic        dtlb_w     [DTLB_ENTRIES];
  logic        dtlb_x     [DTLB_ENTRIES];
  logic        dtlb_u     [DTLB_ENTRIES];
  logic        dtlb_d     [DTLB_ENTRIES];
  logic        dtlb_super [DTLB_ENTRIES];
  logic [2:0]  dtlb_repl_ptr;

  // Full flush on sfence.vma or any satp write (see rationale above).
  (* mark_debug = "true" *) logic tlb_flush;
  assign tlb_flush = ((id_ex_is_sfence_vma && !any_stall) ||
                      (ex_csr_we && (id_ex_csr_addr == CSR_SATP) && !any_stall)) &&
                      !irq_taken_now;

  // itlb_valid/dtlb_valid's reset-and-flush clear used to live in its own
  // always_ff here, separate from the PTW always_ff below that performs the
  // actual fill write (itlb_valid[itlb_repl_ptr] <= 1'b1 etc.). That's a
  // real multi-driver hazard, not a benign one: real Vivado synthesis
  // (2026-07-31 root-cause finding) builds two distinct
  // physical flip-flops per bit — one per always_ff — and resolves the
  // conflict via [Synth 8-6858] "multi-driven net Q is connected to at
  // least one constant driver which has been preserved, other driver is
  // ignored": it silently keeps the constant (GND, from this block) and
  // discards the PTW fill's real write, on every single ITLB/DTLB entry.
  // itlb_hit was therefore permanently, structurally impossible on every
  // real-hardware build with this pattern (confirmed: identical warning
  // present since at least the 2026-07-23 build) — completely independent
  // of the timing/metastability hypotheses chased for weeks, and invisible
  // in sim because Verilator does not resolve the same conflict this way.
  // Fixed by merging both write paths into the single PTW always_ff below
  // (itlb_repl_ptr/dtlb_repl_ptr already lived only there, matching this
  // comment's own now-generalized rule: a signal may only be driven by one
  // procedural block).

  // TLB lookup — combinational, every cycle, mirrors the BTB lookup pattern.
  // (The DTLB half lives below perm_fault_f, which it needs.)
  logic [2:0] itlb_hit_idx, dtlb_hit_idx;
  logic       itlb_hit, dtlb_hit;
  always_comb begin
    itlb_hit     = 1'b0;
    itlb_hit_idx = '0;
    for (int i = 0; i < ITLB_ENTRIES; i++) begin
      if (itlb_valid[i] &&
          (itlb_super[i] ? (itlb_vpn[i][19:10] == pc_if[31:22])   // VPN[1] only
                          : (itlb_vpn[i] == pc_if[31:12]))) begin
        itlb_hit     = 1'b1;
        itlb_hit_idx = i[2:0];
      end
    end
  end

  // ---- Page-table walker (PTW) -------------------------------------------
  // Extends the AMO-FSM pattern: steals cycles from the pipeline via a stall
  // signal OR'd into any_stall, reusing the existing dmem_* port for PTE
  // fetches (no new top-level ports, no bypass around dcache).

  typedef enum logic [2:0] {
    PTW_IDLE       = 3'd0,
    PTW_L1         = 3'd1,   // fetching level-1 (root) PTE
    PTW_L2         = 3'd2,   // fetching level-0 (leaf) PTE
    PTW_DONE       = 3'd3,   // stall-releasing terminal state (success)
    PTW_FAULT      = 3'd4,   // stall-releasing terminal state (fault)
    // PTW_L1_SETTLE/PTW_L2_SETTLE (2026-07-30): a real-hardware-only
    // capture caught the ITLB fill
    // using a partially-settled PTE word — this design's dcache/PTW
    // contract treats dmem_rdata as valid the same cycle dmem_stall first
    // deasserts, matching every sim backing store's atomic timing exactly,
    // but the real AXI3-via-protocol-converter path apparently doesn't
    // always honor that same-cycle guarantee. These two states insert one
    // extra cycle: PTW_L1/PTW_L2 now only latch dmem_rdata into
    // ptw_pte_captured and advance here; all fault/leaf detection and the
    // actual TLB fill happen one cycle later, off the latched (by then
    // definitely settled) copy instead of the live combinational value.
    PTW_L1_SETTLE  = 3'd5,
    PTW_L2_SETTLE  = 3'd6
  } ptw_state_t;

  typedef enum logic [1:0] {
    PTW_ACC_FETCH = 2'd0,
    PTW_ACC_LOAD  = 2'd1,
    PTW_ACC_STORE = 2'd2,
    PTW_ACC_AMO   = 2'd3
  } ptw_acc_e;

  // Permission-fault check, evaluated at whichever level turns out to hold
  // the leaf PTE — level 0 for an ordinary 4KB page, or level 1 for a 4MB
  // superpage (2026-07-16: superpages now translate instead of always
  // faulting, see ptw_l1_is_leaf below; the A/D-bit and R/W/X/U checks
  // apply identically either way).
  function automatic logic perm_fault_f(
    input logic [31:0] pte, input ptw_acc_e acc, input priv_mode_e p,
    input logic mxr, input logic sum_
  );
    logic r, w, x, u, a, d;
    logic needs_r, needs_w, needs_x, needs_d;
    r = pte[1]; w = pte[2]; x = pte[3]; u = pte[4]; a = pte[6]; d = pte[7];
    needs_r = (acc == PTW_ACC_LOAD)  || (acc == PTW_ACC_AMO);
    needs_w = (acc == PTW_ACC_STORE) || (acc == PTW_ACC_AMO);
    needs_x = (acc == PTW_ACC_FETCH);
    needs_d = (acc == PTW_ACC_STORE) || (acc == PTW_ACC_AMO);
    perm_fault_f = (needs_x && !x) ||
                   (needs_r && !(r || (mxr && x))) ||
                   (needs_w && !w) ||
                   (needs_x && (p == PRIV_S) && u) ||
                   (!needs_x && (p == PRIV_S) && u && !sum_) ||
                   (p == PRIV_U && !u) ||
                   (!a) || (needs_d && !d);
  endfunction

  // DTLB lookup (2026-10-13: permission recheck on every hit). An entry only
  // counts as a hit if its cached R/W/X/U/D bits also permit THIS access
  // under the current effective privilege/SUM/MXR -- the same perm_fault_f
  // the walker applies, run against a PTE rebuilt from the cached bits (A is
  // implied: an entry is only ever filled from a PTE with A=1). An entry
  // that matches the VPN but fails the check is treated as a plain miss, so
  // the ordinary walk re-reads the real PTE and raises the page fault (or
  // refills, if software upgraded the PTE without an sfence.vma).
  //
  // Before this, permissions were checked ONLY during the walk that filled
  // the entry, and a hit was a pure VPN match. Root cause of a deterministic
  // Linux panic (`dmesg | tail -60` as the first command of a fresh boot):
  // fork() write-protects every writable page for copy-on-write; a load
  // cached the read-only translation, and a later store to the same page hit
  // that entry and wrote straight into the page still shared by parent and
  // child, with no fault -- each corrupting the other's stack and heap.
  // Also covers a store to a W=1,D=0 page and an S-mode access to a U page
  // after SUM is cleared. Regression: sim/mmu-tests/mmu_tlb_perm_recheck.S.
  ptw_acc_e ex_mem_acc;
  assign ex_mem_acc = ex_mem_is_amo ? PTW_ACC_AMO :
                      (ex_mem_mem_write || ex_mem_is_sc) ? PTW_ACC_STORE : PTW_ACC_LOAD;

  always_comb begin
    dtlb_hit     = 1'b0;
    dtlb_hit_idx = '0;
    for (int i = 0; i < DTLB_ENTRIES; i++) begin
      if (dtlb_valid[i] &&
          (dtlb_super[i] ? (dtlb_vpn[i][19:10] == ex_mem_alu_result[31:22])
                          : (dtlb_vpn[i] == ex_mem_alu_result[31:12])) &&
          !perm_fault_f({24'b0, dtlb_d[i], 1'b1, 1'b0, dtlb_u[i], dtlb_x[i],
                         dtlb_w[i], dtlb_r[i], 1'b1},
                        ex_mem_acc, mem_eff_priv, mstatus_mxr, mstatus_sum)) begin
        dtlb_hit     = 1'b1;
        dtlb_hit_idx = i[2:0];
      end
    end
  end

  (* mark_debug = "true" *) ptw_state_t  ptw_state;
  (* mark_debug = "true" *) ptw_acc_e    ptw_acc;
  (* mark_debug = "true" *) logic [31:0] ptw_va;             // faulting/translating VA, latched at trigger
  logic [31:0] ptw_epc;            // return PC for a trap, latched at trigger
  priv_mode_e  ptw_priv;           // ACTUAL priv_mode at trigger time — used only
                                    // for the delegation gate and mstatus_mpp/spp
                                    // restoration on a fault. Deliberately never
                                    // set from mem_eff_priv: an MPRV-mediated
                                    // M-mode access can be permission-checked as
                                    // if from S/U, but the trap it raises is still
                                    // an M-mode trap (M-mode traps are never
                                    // delegated, regardless of MPRV).
  priv_mode_e  ptw_perm_priv;      // EFFECTIVE priv_mode used only inside
                                    // perm_fault_f — mem_eff_priv for a DTLB
                                    // trigger (respects MPRV), same as ptw_priv
                                    // for an ITLB trigger (MPRV never affects
                                    // instruction fetch).
  logic [19:0] ptw_l1_ppn;         // latched level-1 pointer PPN
  logic [31:0] ptw_fault_cause;
  logic [31:0] ptw_pte_captured;   // dmem_rdata latched one cycle, see PTW_L1_SETTLE above

  (* mark_debug = "true" *) logic ptw_active;
  assign ptw_active = (ptw_state != PTW_IDLE);

  // ptw_fault_pending is a LEVEL (true for as long as ptw_state==PTW_FAULT),
  // not a one-cycle pulse. A pulse would race the pipeline's own stall/flush
  // machinery: if any_stall happens to still be 1 on the exact cycle the
  // fault is detected (e.g. an unrelated, older AMO still draining in
  // EX/MEM), a pulse could vanish before flush_if_id/flush_id_ex ever get a
  // chance to fire, silently dropping the redirect. As a level, the CSR
  // commit below simply re-fires (idempotently — its inputs are all stable,
  // latched registers) every cycle until the redirect actually succeeds.
  logic ptw_fault_pending;
  assign ptw_fault_pending = (ptw_state == PTW_FAULT);

  // fetch_fault_redirect / any_stall_trap (2026-08-29): break a self-deadlock
  // on the instruction-page-fault trap path. When a PTW walk faults for an
  // instruction fetch (ptw_acc==PTW_ACC_FETCH -> PTW_FAULT), itlb_miss stays 1
  // for the faulting pc_if, which holds the icache via imem_req_hold (fix #2,
  // 2026-08-28) -> icache asserts cache_stall unconditionally -> imem_stall ->
  // any_stall=1. But PTW_FAULT's own exit is `if (!any_stall)` AND stall_if has
  // a bare any_stall term freezing pc_if -> pc_if can never redirect to the
  // trap vector -> itlb_miss never clears -> permanent freeze (captured on real
  // HW 2026-08-29: build/kernelhang_capture.csv, and Linux's relocate_enable_mmu
  // deliberately takes exactly this fault as its PA->VA hand-off; sim repro
  // sim/mmu-tests/mmu_fetch_fault.S). The imem_stall in this state is purely
  // the icache being held for the very fetch we're about to trap away from --
  // it must not gate the trap. dmem_stall/amo_stall are still real
  // older-instruction stalls (a fetch fault behind an in-flight older load/AMO
  // must still resolve in program order), so they stay. req_hold itself is
  // left asserted -- the icache still issues NO AXI read for the bad VA.
  logic fetch_fault_redirect, any_stall_trap;
  assign fetch_fault_redirect = ptw_fault_pending && (ptw_acc == PTW_ACC_FETCH);
  assign any_stall_trap = fetch_fault_redirect ? (dmem_stall || amo_stall)
                                               : any_stall;

  logic ptw_delegated;
  assign ptw_delegated = (ptw_priv != PRIV_M) && csr_medeleg[ptw_fault_cause];

  (* mark_debug = "true" *) logic ex_mem_needs_mem, itlb_miss, dtlb_miss;
  assign ex_mem_needs_mem = ex_mem_mem_read || ex_mem_mem_write || ex_mem_is_lr ||
                             ex_mem_is_sc || ex_mem_is_amo;
  assign itlb_miss = if_translate_en && !itlb_hit;
  assign dtlb_miss = mem_translate_en && ex_mem_needs_mem && !dtlb_hit;

  // See the imem_req_hold port comment. itlb_miss is exactly "imem_addr is
  // the raw untranslated VA right now" -- the icache must not act on it.
  assign imem_req_hold = itlb_miss;

  assign dbg_ptw_state      = ptw_state;
  assign dbg_ptw_active     = ptw_active;
  assign dbg_itlb_miss      = itlb_miss;
  assign dbg_dtlb_miss      = dtlb_miss;
  assign dbg_pc_ptw_match   = (pc_if == ptw_va);

  assign dbg_itlb_hit             = itlb_hit;
  assign dbg_itlb_valid0          = itlb_valid[0];
  assign dbg_itlb_super0          = itlb_super[0];
  assign dbg_itlb_tag_match_super = (itlb_vpn[0][19:10] == pc_if[31:22]);
  assign dbg_itlb_tag_match_full  = (itlb_vpn[0] == pc_if[31:12]);

  assign dbg_dtlb_hit    = dtlb_hit;
  assign dbg_dtlb_valid0 = dtlb_valid[0];
  assign dbg_dtlb_super0 = dtlb_super[0];
  assign dbg_ptw_acc     = ptw_acc;

  // amo_wants_start: mirrors the AMO_IDLE case's own trigger condition
  // (below, in the AMO FSM always_ff) exactly. Extracted here so the PTW's
  // itlb_miss trigger can avoid racing it — both independently check only
  // the *other's current, pre-transition* state (ptw_active for the AMO;
  // amo_state for the PTW) to decide whether to start, which fails to
  // prevent both from leaving idle on the exact same cycle, since neither
  // has technically left idle yet from the other's point of view at the
  // moment each check fires. A DTLB-miss-triggered walk never needs this
  // same exclusion: if the AMO's own address is what's untranslated,
  // amo_wants_start is already false (it requires !dtlb_miss); if some
  // other ex_mem instruction caused the DTLB miss, ex_mem_is_amo is false
  // and amo_wants_start is false regardless. Found via a real,
  // previously-undiscovered bug during `ETXTBSY`/`i_writecount` diagnosis:
  // an ITLB miss (for a later, unrelated fetch) landing on the exact cycle
  // a bare AMO (`put_write_access()`'s `atomic_dec`) was ready to start let
  // both transition into "active" simultaneously; the PTW then wins the
  // shared dmem_addr mux's priority (see `assign dmem_addr` below),
  // silently stealing the AMO's actual read/write cycle and losing its
  // otherwise-idempotent decrement.
  logic amo_wants_start;
  assign amo_wants_start = ex_mem_is_amo && !dmem_stall && !ptw_active && !dtlb_miss;

  // mem_wants_port (2026-07-21): a fifth instance of this phase's recurring
  // "value lost at a PTW/hazard boundary" bug class, found root-causing the
  // post-Part-3 busybox NULL-pointer crash (found 2026-07-21).
  // amo_wants_start above defers an ITLB-triggered walk so it can't steal
  // the shared dmem port from an AMO that also wants to start this cycle —
  // but that protection was scoped to AMOs only. An ORDINARY load/store in
  // ex_mem with a translation already resolved (dtlb_hit, no dtlb_miss) gets
  // no such protection: if an unrelated itlb_miss (for whatever pc_if is
  // currently fetching) is detected the exact same cycle, ptw_will_trigger
  // fires anyway (its itlb_miss branch only excluded !amo_wants_start),
  // ptw_active asserts next cycle and the dmem_addr/dmem_ren mux hands the
  // port entirely to the walker's own PTE traffic — even though the load's
  // own request may have already been sitting on the bus with genuinely
  // valid data (mem_load_data/mem_wb_rd_mux read dmem_rdata live, not a
  // value latched at the moment of completion). Any_stall stays asserted
  // throughout the walk (and, if it faults, ex_mem is *correctly* allowed
  // to advance during PTW_FAULT for ptw_acc==PTW_ACC_FETCH — see ex_mem's
  // own advance-condition comment — since an unrelated older instruction
  // must retire normally), so mem_wb ends up sampling whatever the walker
  // left on dmem_rdata (a stale PTE word, or 0 once idle/faulted) instead
  // of the load's own correct value. Confirmed via cycle-exact tracing
  // (+NODETRACE): a hash-node's `lw a0,8(a5)` read the correct pointer
  // (0x001526f4) onto dmem_rdata the very cycle an unrelated itlb_miss was
  // also detected, then silently ended up committing 0 to a0 once the
  // walk (which faulted) finished — busybox then dereferenced that bogus
  // NULL "name" pointer and segfaulted. Generalizes amo_wants_start's
  // protection to ANY pending ex_mem memory op (plain load/store/LR/SC/AMO)
  // whose own translation is already resolved.
  //
  // Took two iterations to get right (both checked against the full kernel
  // boot, not just the 86-test regression, which stayed clean either way):
  // the first attempt used `ex_mem_needs_mem && !dtlb_miss` alone (omitting
  // !dmem_stall/!ptw_active) — regression-clean, but deadlocked the entire
  // kernel boot (hung with zero progress past `printk: legacy bootconsole
  // enabled`, no crash, just TIMEOUT). Root cause: that version blocks the
  // itlb-triggered walk for an ex_mem load/store's *entire* multi-cycle
  // dmem_stall duration, not just the single cycle its result is actually
  // ready — during a genuinely slow backing-store miss, blocking itlb_miss
  // for the whole stall (rather than just the completion cycle) can starve
  // the fetch side indefinitely whenever ex_mem stays continuously occupied
  // by back-to-back loads/stores (e.g. a tight memcpy/memset-style loop),
  // since a new load/store re-occupies ex_mem the instant the last one
  // retires, leaving no window where mem_wants_port ever reads 0. Fixed by
  // mirroring amo_wants_start's exact shape (including !dmem_stall and
  // !ptw_active) — this narrows the exclusion to precisely the single cycle
  // the pending access is actually ready to complete (a fresh hit, or a
  // miss whose fill just landed), which is the only cycle mem_wb's live
  // dmem_rdata sample is actually at risk. Safe to allow the itlb walk
  // in-between while dmem_stall=1: dcache.sv's own backing-store address
  // (fill_tag/fill_idx, set once at miss-start) is latched independently of
  // the live cpu-facing dmem_addr, so a concurrent PTW taking over the
  // shared top-level dmem_addr/dmem_ren mux mid-miss doesn't disturb an
  // already-in-flight fill.
  //
  // Third iteration (2026-07-21, continued): the two-iteration version
  // above is correct in isolation, but has a real deadlock when id_ex and
  // ex_mem end up holding the *identical* dynamic instruction (the same
  // "id_ex frozen on itlb_miss while ex_mem catches up" scenario the
  // forwarding unit's own self-reference bug — see its comment below —
  // stems from). `ex_mem_needs_mem` is a static property of *which*
  // instruction sits in ex_mem, not of whether its access has already
  // succeeded — so as long as ex_mem never actually advances (because
  // id_ex, its only source of new content, is itself frozen), `!dmem_stall`
  // keeps reading true every single cycle (the same load re-evaluates as
  // "ready" forever, never actually retiring), and mem_wants_port never
  // clears. That permanently defers the very itlb-triggered walk id_ex
  // needs to un-freeze — a genuine circular deadlock, confirmed via
  // +MWPTRACE: `class_irqdesc_lock_destructor`'s own `lw a1,4(a5)` sat
  // duplicated in both id_ex and ex_mem indefinitely (every signal frozen
  // identically for 300M+ cycles), `itlb_miss=1` permanently, `ptw_state`
  // never leaving IDLE. Confirmed this is a distinct issue from the
  // forwarding self-reference bug, not caused by it: this specific
  // instruction's own rd (a1) doesn't match its own rs1 (a5), so the
  // forwarding guard's condition never even applies here — the deadlock is
  // mem_wants_port's own structural gap, independent of forwarding.
  // Fixed by excluding exactly the "id_ex frozen and duplicated into
  // ex_mem" condition (id_ex_fresh, declared near id_ex's own pipeline
  // register above) — once id_ex and ex_mem represent the same static PC
  // *and* id_ex's content isn't a fresh new dynamic instance, ex_mem's
  // apparent "need" for the port is circular, not a genuine independent
  // access to protect, so it's safe (indeed necessary) to let the itlb
  // walk proceed and break the cycle.
  (* mark_debug = "true" *) logic mem_wants_port;
  assign mem_wants_port = ex_mem_needs_mem && !dmem_stall && !ptw_active && !dtlb_miss &&
                          !(!id_ex_fresh && (ex_mem_pc == id_ex_pc));

  logic [31:0] ptw_cause_select;
  assign ptw_cause_select = (ptw_acc == PTW_ACC_FETCH) ? CAUSE_INSTR_PAGE_FAULT :
                             (ptw_acc == PTW_ACC_LOAD)  ? CAUSE_LOAD_PAGE_FAULT  :
                                                           CAUSE_STORE_PAGE_FAULT; // STORE and AMO

  // ptw_pte_view (2026-07-30): during the two _SETTLE states, examine the
  // latched-one-cycle ptw_pte_captured instead of the live dmem_rdata — see
  // PTW_L1_SETTLE/PTW_L2_SETTLE's own comment above for why. Harmless to
  // read dmem_rdata directly during plain PTW_L1/PTW_L2 (nothing branches
  // on ptw_l1_is_leaf/ptw_l1_fault/ptw_l2_fault during those states anymore
  // — they only matter once the corresponding _SETTLE state is reached).
  logic [31:0] ptw_pte_view;
  assign ptw_pte_view = (ptw_state == PTW_L1_SETTLE || ptw_state == PTW_L2_SETTLE)
                        ? ptw_pte_captured : dmem_rdata;

  // ptw_l1_is_leaf (2026-07-16, superpage support): R=1 or X=1 at level 1
  // means this PTE is a leaf — a 4MB superpage — rather than a pointer to a
  // level-0 table. Split out from the old ptw_l1_fault (which used to fault
  // unconditionally on this case) so the PTW_L1 FSM state below can tell
  // "stop and translate as a superpage" apart from "keep walking to level
  // 0" apart from "fault" (V=0 or the reserved W=1,R=0 encoding are still
  // unconditional faults regardless of leaf-ness).
  (* mark_debug = "true" *) logic ptw_l1_is_leaf;
  assign ptw_l1_is_leaf = ptw_pte_view[1] || ptw_pte_view[3];

  // Fault conditions for the PTE currently being examined (ptw_pte_view),
  // shared between the PTW's own state transition and the EX/MEM-abandon
  // logic below so both fire on exactly the same cycle. For L1, a leaf PTE
  // faults only if it fails the same permission/A/D checks a level-0 leaf
  // would (perm_fault_f) — an invalid/reserved encoding always faults
  // regardless of leaf-ness.
  (* mark_debug = "true" *) logic ptw_l1_fault, ptw_l2_fault;
  assign ptw_l1_fault = (!ptw_pte_view[0]) ||                    // V=0
                         (ptw_pte_view[2] && !ptw_pte_view[1]) ||   // reserved: W=1,R=0
                         (ptw_l1_is_leaf &&
                          perm_fault_f(ptw_pte_view, ptw_acc, ptw_perm_priv, mstatus_mxr, mstatus_sum));
  assign ptw_l2_fault = (!ptw_pte_view[0]) ||                     // V=0
                         (ptw_pte_view[2] && !ptw_pte_view[1]) ||   // reserved: W=1,R=0
                         (!ptw_pte_view[1] && !ptw_pte_view[2] && !ptw_pte_view[3]) || // non-leaf
                                                                 // at level 0 is malformed
                                                                 // (level 0 is terminal)
                         perm_fault_f(ptw_pte_view, ptw_acc, ptw_perm_priv, mstatus_mxr, mstatus_sum);

  // True for exactly the one cycle a fault is detected in L1_SETTLE/
  // L2_SETTLE — used to synchronously abandon the EX/MEM-stage instruction
  // that caused a DTLB miss (see the EX/MEM register below). Without this,
  // amo_stall would stay asserted forever for an AMO-triggered fault:
  // amo_stall requires ex_mem_is_amo, and the AMO's own read is blocked
  // from progressing by !ptw_active in the dmem-port arbitration below — a
  // self-deadlock that only breaks once ex_mem_is_amo is cleared on this
  // same edge. No longer gated on !dmem_stall (2026-07-30): the fault
  // decision now happens in the _SETTLE states, which aren't dmem_stall-
  // gated at all — the read they're examining already completed the cycle
  // before.
  logic ptw_fault_now;
  assign ptw_fault_now = (ptw_state == PTW_L1_SETTLE && ptw_l1_fault) ||
                          (ptw_state == PTW_L2_SETTLE && ptw_l2_fault);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ptw_state       <= PTW_IDLE;
      ptw_acc         <= PTW_ACC_FETCH;
      ptw_va          <= '0;
      ptw_epc         <= '0;
      ptw_priv        <= PRIV_M;
      ptw_perm_priv   <= PRIV_M;
      ptw_l1_ppn      <= '0;
      ptw_fault_cause <= '0;
      ptw_pte_captured <= '0;
      itlb_repl_ptr   <= '0;
      dtlb_repl_ptr   <= '0;
      for (int i = 0; i < ITLB_ENTRIES; i++) itlb_valid[i] <= 1'b0;
      for (int i = 0; i < DTLB_ENTRIES; i++) dtlb_valid[i] <= 1'b0;
    end else if (tlb_flush) begin
      for (int i = 0; i < ITLB_ENTRIES; i++) itlb_valid[i] <= 1'b0;
      for (int i = 0; i < DTLB_ENTRIES; i++) dtlb_valid[i] <= 1'b0;
    end else begin
      case (ptw_state)
        PTW_IDLE: begin
          // amo_state==AMO_IDLE gates every trigger: if an AMO has already
          // left AMO_IDLE (read succeeded, now writing back or done), it
          // must never be interrupted mid-flight — the AMO_IDLE guard below
          // (!ptw_active && !dtlb_miss) pins amo_state at AMO_IDLE for the
          // whole walk, so requiring AMO_IDLE here ensures a walk can never
          // start while a write is actually in flight.
          if (dtlb_miss && (amo_state == AMO_IDLE)) begin
            // DTLB miss wins priority over an ITLB miss on the same cycle —
            // the MEM-stage instruction is older.
            ptw_va        <= ex_mem_alu_result;
            ptw_epc       <= ex_mem_pc;
            ptw_priv      <= ex_mem_priv;    // actual (latched with the instr) — for delegation/mstatus_mpp
            ptw_perm_priv <= mem_eff_priv;   // effective — for the permission check
            ptw_acc   <= ex_mem_is_amo ? PTW_ACC_AMO :
                         (ex_mem_mem_write || ex_mem_is_sc) ? PTW_ACC_STORE : PTW_ACC_LOAD;
            ptw_state <= PTW_L1;
          end else if (itlb_miss && (amo_state == AMO_IDLE) && !mem_wants_port) begin
            ptw_va        <= pc_if;
            ptw_epc       <= pc_if;
            ptw_priv      <= priv_mode;
            ptw_perm_priv <= priv_mode;      // MPRV never affects instruction fetch
            ptw_acc   <= PTW_ACC_FETCH;
            ptw_state <= PTW_L1;
          end
        end

        // PTW_L1/PTW_L2 (2026-07-30, revised): no longer inspect dmem_rdata
        // combinationally the same cycle it first becomes valid — just
        // latch it and defer to the corresponding _SETTLE state one cycle
        // later (see the state enum's own comment for why).
        PTW_L1: begin
          if (!dmem_stall) begin
            ptw_pte_captured <= dmem_rdata;
            ptw_state        <= PTW_L1_SETTLE;
          end
        end

        PTW_L1_SETTLE: begin
          if (ptw_l1_fault) begin
            ptw_fault_cause <= ptw_cause_select;
            ptw_state       <= PTW_FAULT;
          end else if (ptw_l1_is_leaf) begin
            // 4MB superpage (2026-07-16) — this level-1 PTE is itself the
            // leaf, translation is complete without a level-0 walk. Fill
            // the TLB directly, marked itlb_super/dtlb_super so the hit
            // check and address mux both treat it as a 4MB entry. The
            // vpn/ppn/x/u/r/w/super field writes live in their own
            // dedicated always_ff blocks below (itlb_fill_l1_leaf/
            // dtlb_fill_l1_leaf, 2026-08-27) -- see that comment for why.
            if (ptw_acc == PTW_ACC_FETCH) begin
              itlb_valid[itlb_repl_ptr] <= 1'b1;
              itlb_repl_ptr             <= itlb_repl_ptr + 3'd1;
            end else begin
              dtlb_valid[dtlb_repl_ptr] <= 1'b1;
              dtlb_repl_ptr             <= dtlb_repl_ptr + 3'd1;
            end
            ptw_state <= PTW_DONE;
          end else begin
            ptw_l1_ppn <= ptw_pte_captured[29:10]; // pointer to the level-0 table
            ptw_state  <= PTW_L2;
          end
        end

        PTW_L2: begin
          if (!dmem_stall) begin
            ptw_pte_captured <= dmem_rdata;
            ptw_state        <= PTW_L2_SETTLE;
          end
        end

        PTW_L2_SETTLE: begin
          if (ptw_l2_fault) begin
            ptw_fault_cause <= ptw_cause_select;
            ptw_state       <= PTW_FAULT;
          end else begin
            // Success — fill the appropriate TLB (FIFO replacement). See the
            // itlb_fill_l2_leaf/dtlb_fill_l2_leaf always_ff blocks below for
            // the vpn/ppn/x/u/r/w/super field writes (2026-08-27).
            if (ptw_acc == PTW_ACC_FETCH) begin
              itlb_valid[itlb_repl_ptr] <= 1'b1;
              itlb_repl_ptr             <= itlb_repl_ptr + 3'd1;
            end else begin
              dtlb_valid[dtlb_repl_ptr] <= 1'b1;
              dtlb_repl_ptr             <= dtlb_repl_ptr + 3'd1;
            end
            ptw_state <= PTW_DONE;
          end
        end

        // Success: exit condition deliberately excludes amo_stall. When this
        // walk was for an AMO's own DTLB miss, ex_mem_is_amo is still 1 and
        // amo_stall stays asserted throughout — that's intentional (the AMO
        // is meant to resume, not abort), so waiting only on the port-level
        // stalls (not amo_stall, which is itself gated on !ptw_active) is
        // what actually lets ptw_active clear and the AMO proceed next.
        PTW_DONE: begin
          if (!dmem_stall && !imem_stall) ptw_state <= PTW_IDLE;
        end

        // Fault: safe to wait on plain !any_stall here, because by the time
        // this state is reached, ptw_fault_now (below) has already cleared
        // ex_mem_is_amo/mem_read/mem_write for a non-fetch fault on the same
        // edge the fault was detected — so amo_stall can no longer be
        // self-referentially blocking. For an unrelated, still-legitimately
        // in-flight older AMO (an ITLB-triggered fault case), !any_stall
        // correctly waits for it to retire first (in-order semantics).
        PTW_FAULT: begin
          // any_stall_trap, not any_stall: for a fetch-type fault the only
          // thing keeping any_stall high is the icache being held for the
          // faulting fetch itself (see fetch_fault_redirect's declaration) --
          // waiting on that is the self-deadlock. Still waits on a real
          // dmem_stall/amo_stall from an older in-flight instruction.
          if (!any_stall_trap) ptw_state <= PTW_IDLE;
        end

        default: ptw_state <= PTW_IDLE;
      endcase
    end
  end

  // itlb_vpn/ppn/x/u/super and dtlb_vpn/ppn/r/w/x/u/super (2026-08-27):
  // content is only ever trusted when the corresponding _valid bit is also
  // true (set in the PTW always_ff above, on the same cycle these write),
  // so these fields need no reset value of their own. Moved into their own
  // dedicated, reset-free always_ff blocks -- mirroring icache.sv's c_data
  // fix from the same investigation -- instead of living inside the main
  // PTW always_ff above (which does carry an async reset for other
  // signals): that shape produced Vivado's [Synth 8-7137] "Set and reset
  // with same priority... may cause simulation mismatches" warning on every
  // one of these fields (found 2026-08-27). Still exactly one driving
  // always_ff per signal, preserving the single-driver rule from the
  // 2026-07-31 multi-driver fix documented above itlb_valid/dtlb_valid's
  // declaration.
  logic itlb_fill_l1_leaf, itlb_fill_l2_leaf;
  logic dtlb_fill_l1_leaf, dtlb_fill_l2_leaf;
  assign itlb_fill_l1_leaf = (ptw_state == PTW_L1_SETTLE) && !ptw_l1_fault &&
                             ptw_l1_is_leaf && (ptw_acc == PTW_ACC_FETCH);
  assign dtlb_fill_l1_leaf = (ptw_state == PTW_L1_SETTLE) && !ptw_l1_fault &&
                             ptw_l1_is_leaf && (ptw_acc != PTW_ACC_FETCH);
  assign itlb_fill_l2_leaf = (ptw_state == PTW_L2_SETTLE) && !ptw_l2_fault &&
                             (ptw_acc == PTW_ACC_FETCH);
  assign dtlb_fill_l2_leaf = (ptw_state == PTW_L2_SETTLE) && !ptw_l2_fault &&
                             (ptw_acc != PTW_ACC_FETCH);

  always_ff @(posedge clk) begin
    if (itlb_fill_l1_leaf || itlb_fill_l2_leaf) begin
      itlb_vpn[itlb_repl_ptr]   <= ptw_va[31:12];
      itlb_ppn[itlb_repl_ptr]   <= ptw_pte_captured[29:10];
      itlb_x[itlb_repl_ptr]     <= ptw_pte_captured[3];
      itlb_u[itlb_repl_ptr]     <= ptw_pte_captured[4];
      itlb_super[itlb_repl_ptr] <= itlb_fill_l1_leaf; // 1: L1 4MB superpage leaf, 0: L2 4KB leaf
    end
  end

  always_ff @(posedge clk) begin
    if (dtlb_fill_l1_leaf || dtlb_fill_l2_leaf) begin
      dtlb_vpn[dtlb_repl_ptr]   <= ptw_va[31:12];
      dtlb_ppn[dtlb_repl_ptr]   <= ptw_pte_captured[29:10];
      dtlb_r[dtlb_repl_ptr]     <= ptw_pte_captured[1];
      dtlb_w[dtlb_repl_ptr]     <= ptw_pte_captured[2];
      dtlb_x[dtlb_repl_ptr]     <= ptw_pte_captured[3];
      dtlb_u[dtlb_repl_ptr]     <= ptw_pte_captured[4];
      dtlb_d[dtlb_repl_ptr]     <= ptw_pte_captured[7];
      dtlb_super[dtlb_repl_ptr] <= dtlb_fill_l1_leaf; // 1: L1 4MB superpage leaf, 0: L2 4KB leaf
    end
  end

  logic ptw_stall;
  // ptw_will_trigger mirrors the PTW_IDLE case's own trigger condition
  // exactly (including the amo_state==AMO_IDLE gate). Needed because
  // dtlb_miss/itlb_miss are purely combinational (react instantly to
  // ex_mem_alu_result/pc_if) while ptw_active only reflects the decision to
  // walk starting the cycle AFTER ptw_state registers the transition —
  // without this, there's a one-cycle gap where a miss is detected but
  // nothing yet holds the pipeline, letting ex_mem advance past the very
  // instruction whose miss was just found.
  // The itlb_miss half is additionally gated on !mem_wants_port, mirroring
  // the PTW_IDLE case's own itlb_miss branch exactly (see mem_wants_port's
  // own comment above) — an ITLB-triggered walk defers by one cycle rather
  // than racing any pending ex_mem load/store/AMO that also wants the
  // shared dmem port this exact cycle.
  logic ptw_will_trigger;
  assign ptw_will_trigger = (ptw_state == PTW_IDLE) && (amo_state == AMO_IDLE) &&
                             (dtlb_miss || (itlb_miss && !mem_wants_port));

  // Includes PTW_DONE (unlike the state enum's name might suggest) because
  // ptw_active still gates the dmem-port arbitration throughout DONE — the
  // deferred access doesn't actually retry until the cycle after ptw_state
  // reaches IDLE, so any_stall must stay asserted through DONE too or
  // ex_mem would advance past the instruction before its retry ever fires.
  // FAULT is excluded so its own !any_stall-gated exit (see the PTW_FAULT
  // case comment above) can actually be satisfied.
  assign ptw_stall = (ptw_active && (ptw_state != PTW_FAULT)) || ptw_will_trigger;

  // =========================================================================
  // Misprediction check + BTB update
  // =========================================================================
  // ex_real_redirect: true when the IF prediction was wrong and we must correct.
  // Three cases for a misprediction:
  //   (a) Predicted taken + not actually taken   → go to fallthrough (id_ex_pc+4)
  //   (b) Predicted taken + taken to wrong target → go to actual target
  //   (c) Not predicted + actually taken          → go to actual target (old behavior)
  always_comb begin
    if (fence_i_retire) begin
      // FENCE.I (fix #6): unconditionally redirect pc_if to the following
      // instruction so anything already fetched past the FENCE.I (from the
      // now-stale icache) is discarded and re-fetched after the invalidate.
      // Checked ahead of the BTB predict/verify cases: a stale BTB entry
      // that happens to alias the FENCE.I's PC must not be able to suppress
      // this corrective flush. fence_i_retire already excludes a same-cycle
      // trap, so trap redirects still take priority via the paths below.
      ex_real_redirect = 1'b1;
      ex_real_target   = id_ex_pc + 32'd4;
    end else if (id_ex_pred_taken && !ex_redirect) begin
      ex_real_redirect = 1'b1;
      ex_real_target   = id_ex_pc + 32'd4;
    end else if (id_ex_pred_taken && ex_redirect && (ex_target_pc == id_ex_pred_target)) begin
      ex_real_redirect = 1'b0;  // correct prediction — no corrective flush
      ex_real_target   = ex_target_pc;
    end else begin
      ex_real_redirect = ex_redirect;
      ex_real_target   = ex_target_pc;
    end
  end

  // BTB update when a branch or jump retires from EX
  logic [BTB_IDX_BITS-1:0] ex_btb_idx;
  assign ex_btb_idx = id_ex_pc[BTB_IDX_BITS+1:2];

  always_ff @(posedge clk) begin
    if (!any_stall && (id_ex_branch || id_ex_jump || id_ex_jumpr)) begin
      btb_valid[ex_btb_idx]  <= 1'b1;
      btb_tag[ex_btb_idx]    <= id_ex_pc[31:BTB_IDX_BITS+2];
      btb_target[ex_btb_idx] <= ex_target_pc;
      if (ex_redirect)
        btb_cnt[ex_btb_idx] <= (btb_cnt[ex_btb_idx] == 2'b11) ? 2'b11 : btb_cnt[ex_btb_idx] + 2'b01;
      else
        btb_cnt[ex_btb_idx] <= (btb_cnt[ex_btb_idx] == 2'b00) ? 2'b00 : btb_cnt[ex_btb_idx] - 2'b01;
    end
  end

  // =========================================================================
  // EX/MEM Pipeline Register
  // =========================================================================
  logic [31:0] ex_mem_rs2_data;
  logic [2:0]  ex_mem_funct3;
  logic        ex_mem_mem_read, ex_mem_mem_write;
  logic        ex_mem_is_csr;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ex_mem_alu_result <= '0; ex_mem_rs2_data  <= '0;
      ex_mem_pc         <= '0; ex_mem_rd_addr   <= '0;
      ex_mem_priv       <= PRIV_M; ex_mem_eff_priv <= PRIV_M;
      ex_mem_funct3     <= '0; ex_mem_reg_write <= '0;
      ex_mem_mem_read   <= '0; ex_mem_mem_write <= '0;
      ex_mem_wb_sel     <= WB_ALU;
      ex_mem_is_csr     <= '0; ex_mem_csr_rdata <= '0;
      ex_mem_is_lr      <= '0; ex_mem_is_sc     <= '0;
      ex_mem_is_amo     <= '0; ex_mem_amo_funct5 <= '0;
    end else if (ptw_fault_now && (ptw_acc != PTW_ACC_FETCH)) begin
      // The instruction sitting in EX/MEM is the one that caused this DTLB
      // miss/fault — abandon it (it will never complete). Clearing these
      // fields specifically breaks amo_stall's self-dependency on
      // ptw_active for the AMO case (see the PTW_FAULT comment above); for
      // plain load/store it just prevents a stale, already-faulted access
      // from re-issuing once ptw_active eventually clears. Only reachable
      // for a DTLB-triggered fault (ptw_acc != FETCH) — an ITLB-triggered
      // fault must NOT touch EX/MEM, since whatever's there is an older,
      // unrelated instruction that should retire normally.
      ex_mem_reg_write <= 1'b0;
      ex_mem_mem_read  <= 1'b0; ex_mem_mem_write <= 1'b0;
      ex_mem_is_lr     <= 1'b0; ex_mem_is_sc     <= 1'b0;
      ex_mem_is_amo    <= 1'b0;
    end else if (irq_taken_now) begin
      // The instruction sitting in id_ex is being preempted by an interrupt
      // this cycle. Unlike ECALL/MRET/SRET/PTW-faults (pipeline-inert by
      // construction), an arbitrary ADD/SW/CSRRW has real EX/MEM side
      // effects that must not retire, or it would silently execute twice
      // (once here, wrongly, and again after mret/sret re-fetches it from
      // mepc/sepc). Its own CSR write (if any) is already skipped above,
      // since this tier takes priority over the ex_csr_we branch.
      ex_mem_reg_write <= 1'b0;
      ex_mem_mem_read  <= 1'b0; ex_mem_mem_write <= 1'b0;
      ex_mem_is_lr     <= 1'b0; ex_mem_is_sc     <= 1'b0;
      ex_mem_is_amo    <= 1'b0;
    end else if (!any_stall && !dtlb_miss &&
                 !(ptw_fault_pending && ptw_acc != PTW_ACC_FETCH)) begin
      // ptw_fault_pending exclusion (2026-07-20, corrected — see id_ex's
      // own identical fix above for why the original `ex_real_redirect`-
      // based version was wrong: it also covers id_ex being a genuine
      // jal/jalr/branch needing its own misprediction correction,
      // unrelated to any PTW fault, and excluding the advance for THAT
      // case broke ordinary JALR handling — caught immediately by
      // regression, rv32ui-p-jalr and clint_timer_irq_mid_jalr both
      // failed. Scoped to exactly ptw_fault_pending, not the broader
      // redirect): a THIRD bug in the same
      // "ptw_fault_pending mishandled at a stage boundary" family as
      // flush_if_id's/flush_id_ex's own fix above, found the same way.
      // Without this, ex_mem's plain advance still fires on the exact
      // same edge id_ex is being flushed (by flush_id_ex, for this same
      // fault) — so ex_mem "steals" id_ex's pre-flush content
      // one last time instead of it being discarded, exactly defeating
      // the flush's purpose. Confirmed concretely: two consecutive user
      // loads (busybox's `lw a6,12(a5)` / `lw a2,4(a5)`, both reading the
      // same never-mapped struct) sit in ex_mem/id_ex simultaneously; the
      // first faults and is correctly abandoned (existing ptw_fault_now
      // branch above) — but ex_mem then immediately re-advances and steals
      // the SECOND, younger load out of id_ex instead of letting it be
      // discarded, and THAT load's own (entirely real, legitimate) fault
      // for the same unmapped page fires a cycle later — by which point
      // priv_mode has already flipped to S from the FIRST fault's own
      // trap-entry, so `ptw_priv <= priv_mode` (see PTW_IDLE's trigger
      // above) latches the wrong (already-S) privilege for this SECOND
      // walk, corrupting mstatus_spp/mstatus_mpp in the trap frame the
      // kernel reads (RISC-V's own `user_mode(regs)` check reads this
      // bit) — this is what the kernel's own "Unable to handle kernel
      // access to user memory without uaccess routines" panic was
      // actually reporting; the fault handler correctly decided "this
      // looks like it came from S-mode" because, per this bug, it
      // genuinely — if wrongly — did. Excludes ITLB/fetch faults
      // (ptw_acc==PTW_ACC_FETCH) for the same reason flush_id_ex does:
      // those don't flush id_ex at all, so there's nothing to protect
      // against here. load_use_hazard is deliberately NOT part of this
      // exclusion — for that case id_ex's current content is completely
      // legitimate and must still retire normally; only ex_real_redirect
      // means "this is being discarded on purpose."
      // dtlb_miss: don't advance (consume id_ex's content) while ex_mem's
      // *current* instruction is itself the one whose data-side
      // translation is still outstanding — see stall_if/stall_if_id's
      // dtlb_miss comment above for the full mechanism.
      ex_mem_alu_result <= ex_result;    // ex_result = ALU out, or mul_unit/div_unit for an M-op
      ex_mem_rs2_data   <= ex_fwd_rs2;   // forwarded store data
      ex_mem_pc         <= id_ex_pc;
      ex_mem_priv       <= priv_mode;
      ex_mem_eff_priv   <= mstatus_mprv ? mstatus_mpp : priv_mode;
      ex_mem_rd_addr    <= id_ex_rd_addr;
      ex_mem_funct3     <= id_ex_funct3;
      ex_mem_reg_write  <= id_ex_reg_write;
      ex_mem_mem_read   <= id_ex_mem_read;
      ex_mem_mem_write  <= id_ex_mem_write;
      ex_mem_wb_sel     <= id_ex_wb_sel;
      ex_mem_is_csr     <= id_ex_is_csr;
      ex_mem_csr_rdata  <= ex_csr_rdata;
      ex_mem_is_lr      <= id_ex_is_lr;   ex_mem_is_sc      <= id_ex_is_sc;
      ex_mem_is_amo     <= id_ex_is_amo;  ex_mem_amo_funct5 <= id_ex_amo_funct5;
    end
  end

  // Forwarding value from EX/MEM accounts for wb_sel (not just ALU result)
  always_comb begin
    case (ex_mem_wb_sel)
      WB_PC4:  ex_mem_fwd_data = ex_mem_pc + 32'd4;
      WB_CSR:  ex_mem_fwd_data = ex_mem_csr_rdata;
      WB_SC:   ex_mem_fwd_data = sc_result;  // sc_result computable from registered lr state
      default: ex_mem_fwd_data = ex_mem_alu_result; // WB_ALU, WB_MEM (stall prevents WB_MEM from needing fwd)
    endcase
  end

  // =========================================================================
  // MEM — Memory Access  (LR.W / SC.W / AMO* + normal loads/stores)
  // =========================================================================

  // LR/SC reservation
  logic        lr_valid;
  logic [31:0] lr_addr;

  // AMO three-phase FSM: READ → WRITE → DONE
  typedef enum logic [1:0] {
    AMO_IDLE  = 2'd0,
    AMO_WRITE = 2'd1,
    AMO_DONE  = 2'd2
  } amo_state_t;
  (* mark_debug = "true" *) amo_state_t  amo_state;
  logic [31:0] amo_rdata_latch;

  // SC result: 0=success, 1=failure  (word-aligned comparison)
  logic sc_success;
  assign sc_success = lr_valid && (ex_mem_alu_result[31:2] == lr_addr[31:2]);
  assign sc_result  = sc_success ? 32'd0 : 32'd1;

  // AMO write-data: computed from latched memory word and rs2
  logic [31:0] amo_wdata;
  always_comb begin
    case (ex_mem_amo_funct5)
      5'b00001: amo_wdata = ex_mem_rs2_data;                                                               // AMOSWAP
      5'b00000: amo_wdata = amo_rdata_latch + ex_mem_rs2_data;                                             // AMOADD
      5'b00100: amo_wdata = amo_rdata_latch ^ ex_mem_rs2_data;                                             // AMOXOR
      5'b01100: amo_wdata = amo_rdata_latch & ex_mem_rs2_data;                                             // AMOAND
      5'b01000: amo_wdata = amo_rdata_latch | ex_mem_rs2_data;                                             // AMOOR
      5'b10000: amo_wdata = ($signed(amo_rdata_latch) < $signed(ex_mem_rs2_data)) ? amo_rdata_latch : ex_mem_rs2_data; // AMOMIN
      5'b10100: amo_wdata = ($signed(amo_rdata_latch) > $signed(ex_mem_rs2_data)) ? amo_rdata_latch : ex_mem_rs2_data; // AMOMAX
      5'b11000: amo_wdata = (amo_rdata_latch < ex_mem_rs2_data) ? amo_rdata_latch : ex_mem_rs2_data;      // AMOMINU
      5'b11100: amo_wdata = (amo_rdata_latch > ex_mem_rs2_data) ? amo_rdata_latch : ex_mem_rs2_data;      // AMOMAXU
      default:  amo_wdata = ex_mem_rs2_data;
    endcase
  end

  // AMO FSM + LR/SC reservation update
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      lr_valid        <= 1'b0;
      lr_addr         <= '0;
      amo_state       <= AMO_IDLE;
      amo_rdata_latch <= '0;
    end else begin
      // LR/SC reservation must be invalidated by any trap entry or
      // return — per spec, an SC may only pair with the most recent LR,
      // and a trap taken in between (interrupt, exception, or xRET)
      // invalidates it. Found via a real bug: with no invalidation here,
      // a timer interrupt landing on a stranded `sc.w` (already past its
      // paired `lr.w`, which committed on an earlier cycle — a real
      // window on this non-superscalar pipeline) let the reservation
      // survive the trap; natural resumption (mepc untouched) then
      // re-executed that same stranded SC, which could spuriously
      // succeed using a value computed *before* the trap and silently
      // clobber whatever the trap handler itself wrote to the same
      // address — see sim/clint-tests/clint_timer_irq_lrsc_reservation.S.
      // Checked with priority over the ordinary LR-sets/SC-clears cases
      // below, mirroring the CSR-update block's own priority order
      // (ptw_fault_pending > irq_taken_now > only-if-!any_stall normal
      // commit) so a trap taken the same cycle an unrelated LR happens
      // to retire in EX/MEM can't leave a stale reservation behind.
      if (ptw_fault_pending || irq_taken_now) begin
        lr_valid <= 1'b0;
      end else if (!any_stall && (id_ex_is_ecall || id_ex_is_mret || id_ex_is_sret)) begin
        lr_valid <= 1'b0;
      end else begin
        // LR: record reservation when MEM stage commits (pipeline advances)
        if (ex_mem_is_lr && !any_stall) begin
          lr_valid <= 1'b1;
          lr_addr  <= ex_mem_alu_result;
        end
        // SC: always clear reservation when SC commits
        if (ex_mem_is_sc && !any_stall)
          lr_valid <= 1'b0;
      end

      case (amo_state)
        AMO_IDLE: begin
          // amo_wants_start (!ptw_active && !dtlb_miss, among other terms):
          // don't let the AMO's read fire against an untranslated address
          // while the walker owns the dmem port (or is about to) — without
          // this guard a DTLB miss on this very AMO would let it silently
          // read/write the wrong physical location.
          if (amo_wants_start) begin
            // READ phase complete (dcache returned data combinationally)
            amo_rdata_latch <= dmem_rdata;
            amo_state       <= AMO_WRITE;
          end
        end
        AMO_WRITE: begin
          if (!dmem_stall)   // write-through cache: writes never stall, always true
            amo_state <= AMO_DONE;
        end
        AMO_DONE: begin
          if (!any_stall)    // pipeline advancing — reset FSM
            amo_state <= AMO_IDLE;
        end
        default: amo_state <= AMO_IDLE;
      endcase
    end
  end

  // amo_stall: assert while AMO READ or WRITE phase is in progress
  assign amo_stall = ex_mem_is_amo && (amo_state != AMO_DONE);

  // dmem interface — unified combinational control
  // Translation mux: inert until mem_translate_en is true AND the DTLB
  // actually holds a matching entry (never true before the PTW can fill it).
  logic [31:0] dmem_addr_normal;
  assign dmem_addr_normal = (mem_translate_en && dtlb_hit) ?
                               (dtlb_super[dtlb_hit_idx] ? {dtlb_ppn[dtlb_hit_idx][19:10], ex_mem_alu_result[21:0]}
                                                          : {dtlb_ppn[dtlb_hit_idx], ex_mem_alu_result[11:0]})
                                                            : ex_mem_alu_result;

  // While the PTW owns the port (ptw_active), it drives the address: level-1
  // PTE at {satp_ppn, VA[31:22], 2'b00}, level-0 PTE at {ptw_l1_ppn,
  // VA[21:12], 2'b00}. During PTW_DONE/PTW_FAULT this value is unused (no
  // request is issued — see the always_comb below) but stays well-formed.
  assign dmem_addr = ptw_active
    ? {(ptw_state == PTW_L1) ? satp_ppn : ptw_l1_ppn,
       (ptw_state == PTW_L1) ? ptw_va[31:22] : ptw_va[21:12], 2'b00}
    : dmem_addr_normal;

  // dmem_write_fired (2026-07-24): a plain store's/SC's dmem_wen is
  // re-derived combinationally from ex_mem every cycle, with no memory of
  // whether it already fired. That's fine while ex_mem is advancing every
  // cycle, but when any_stall holds ex_mem frozen for a reason that has
  // NOTHING to do with this store (e.g. an icache miss on a LATER fetch),
  // the store's dmem_wen keeps re-asserting identically every stalled
  // cycle instead of firing exactly once. For a plain RAM store this was
  // already invisible: dcache.sv's own wr_done_pulse mechanism (see its
  // header comment) already treats a repeated/stale cpu_wen as the same
  // write, and re-writing the same value to the same address has no
  // observable effect anyway. But mmio_decoder.sv models UART/CLINT/PLIC
  // as always single-cycle (cpu_stall tied to 0 for all non-RAM
  // destinations — see mmio_decoder.sv), so any held-multi-cycle wen
  // reaching them is *guaranteed* to be this same stale-repeat case, never
  // a legitimate multi-cycle request — and uart.sv's THR write has a real,
  // externally-visible side effect (transmit one more byte) each time wen
  // asserts, unlike a RAM overwrite. Found via mmu_uart_translated_basic.S:
  // a store to UART's THR register whose ex_mem cycle happened to overlap
  // an icache-miss stall on the next instruction's fetch retransmitted the
  // same character 6 times. Fixed generally (not just for UART) by
  // latching "this store already fired" and gating both the plain-store
  // and SC write conditions on it below, cleared whenever ex_mem actually
  // advances (!any_stall) so a genuinely new instruction's store isn't
  // suppressed. Safe for RAM: dcache only needs dmem_wen asserted for the
  // one cycle it takes to latch the request into its own ST_WRITE FSM
  // (see dcache.sv), not held for the whole multi-cycle completion.
  logic dmem_write_fired;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)             dmem_write_fired <= 1'b0;
    else if (!any_stall)    dmem_write_fired <= 1'b0;
    else if (dmem_wen)      dmem_write_fired <= 1'b1;
  end

  always_comb begin
    dmem_ren   = 1'b0;
    dmem_wen   = 1'b0;
    dmem_wmask = 4'b0000;
    dmem_wdata = ex_mem_rs2_data;

    if (ptw_active) begin
      // Page-table walker owns the port: read-only PTE fetch. No traffic at
      // all during the DONE/FAULT terminal states.
      dmem_ren = (ptw_state == PTW_L1) || (ptw_state == PTW_L2);
    end else if (amo_state == AMO_WRITE) begin
      // AMO write phase: store computed result back to memory
      dmem_wen   = 1'b1;
      dmem_wmask = 4'b1111;
      dmem_wdata = amo_wdata;
    end else if (amo_state == AMO_DONE) begin
      // AMO complete — no memory traffic
    end else if (ex_mem_is_amo) begin
      // AMO read phase (AMO_IDLE). Gated on !dtlb_miss for the same reason as
      // the plain-load path below (2026-08-28): on a DTLB miss dmem_addr
      // falls through to the raw untranslated VA, and issuing the read for it
      // wedges the D-side AXI master on real hardware if that VA is out of
      // DRAM range (a high-half alias). The AMO simply retries once the walk
      // installs the DTLB entry.
      dmem_ren = !dtlb_miss;
    end else if (ex_mem_is_sc) begin
      // SC: conditional store — only write if reservation holds. Also
      // gated on !dtlb_miss (see the normal-store comment below) even
      // though sc_success already implies a resolved address in practice
      // today — kept for the same one-cycle-race reason and to stay
      // symmetric with the plain-store gating. !dmem_write_fired guards
      // against the same repeated-write-during-an-unrelated-stall issue
      // described above dmem_write_fired's declaration.
      if (sc_success && !dtlb_miss && !dmem_write_fired) begin
        dmem_wen   = 1'b1;
        dmem_wmask = 4'b1111;
        dmem_wdata = ex_mem_rs2_data;
      end
    end else begin
      // Normal load / store. Neither the read nor the write may fire on a
      // DTLB miss: on the very cycle a miss is first detected, ptw_active is
      // still 0 (the PTW FSM only registers PTW_L1 on the *next* clock edge),
      // so without this gate we'd fall through to dmem_addr_normal's
      // untranslated-VA fallback (dtlb_hit==0) for at least one cycle and
      // hand the dcache the raw virtual address instead of the translated
      // physical one.
      //   - Store side (2026-07-24): committed a store to the raw VA — a
      //     real, if rare, in-the-wild corruption (a kernel text-patching
      //     store through the linear map wrote to VA instead of PA on its
      //     DTLB-miss cycle).
      //   - Load side (2026-08-28): the dcache misses on the raw VA and
      //     issues a D-side AXI read for it; for a high-half alias that VA is
      //     outside DRAM, the interconnect accepts the AR and never returns
      //     RVALID, the dcache wedges, dmem_stall sticks, and the PTW's own
      //     PTE read (which shares the D-side port) never completes — a hard
      //     hang. Exactly the icache/req_hold bug (see imem_req_hold), one
      //     cycle earlier and on the data side. The load simply retries once
      //     the walk installs the DTLB entry and dtlb_miss clears.
      // !dtlb_miss is 1 whenever translation is off (Bare mode) or the DTLB
      // already has a hit, so this doesn't change the common (non-miss) path.
      dmem_ren = ex_mem_mem_read && !dtlb_miss;
      if (ex_mem_mem_write && !dtlb_miss && !dmem_write_fired) begin
        case (ex_mem_funct3)
          3'b000: begin // SB
            dmem_wen   = 1'b1;
            dmem_wdata = {4{ex_mem_rs2_data[7:0]}};
            case (ex_mem_alu_result[1:0])
              2'b00: dmem_wmask = 4'b0001;
              2'b01: dmem_wmask = 4'b0010;
              2'b10: dmem_wmask = 4'b0100;
              default: dmem_wmask = 4'b1000;
            endcase
          end
          3'b001: begin // SH
            dmem_wen = 1'b1;
            if (!ex_mem_alu_result[1]) begin
              dmem_wmask = 4'b0011;
              dmem_wdata = {16'b0, ex_mem_rs2_data[15:0]};
            end else begin
              dmem_wmask = 4'b1100;
              dmem_wdata = {ex_mem_rs2_data[15:0], 16'b0};
            end
          end
          default: begin // SW
            dmem_wen   = 1'b1;
            dmem_wmask = 4'b1111;
            dmem_wdata = ex_mem_rs2_data;
          end
        endcase
      end
    end
  end

  // Load: sign/zero extension (also used as AMO return value before write)
  logic [31:0] mem_load_data;
  always_comb begin
    case (ex_mem_funct3)
      3'b000: begin // LB
        case (ex_mem_alu_result[1:0])
          2'b00: mem_load_data = {{24{dmem_rdata[7]}},  dmem_rdata[7:0]};
          2'b01: mem_load_data = {{24{dmem_rdata[15]}}, dmem_rdata[15:8]};
          2'b10: mem_load_data = {{24{dmem_rdata[23]}}, dmem_rdata[23:16]};
          default: mem_load_data = {{24{dmem_rdata[31]}}, dmem_rdata[31:24]};
        endcase
      end
      3'b001: begin // LH
        if (!ex_mem_alu_result[1])
          mem_load_data = {{16{dmem_rdata[15]}}, dmem_rdata[15:0]};
        else
          mem_load_data = {{16{dmem_rdata[31]}}, dmem_rdata[31:16]};
      end
      3'b010:  mem_load_data = dmem_rdata; // LW
      3'b100: begin // LBU
        case (ex_mem_alu_result[1:0])
          2'b00: mem_load_data = {24'b0, dmem_rdata[7:0]};
          2'b01: mem_load_data = {24'b0, dmem_rdata[15:8]};
          2'b10: mem_load_data = {24'b0, dmem_rdata[23:16]};
          default: mem_load_data = {24'b0, dmem_rdata[31:24]};
        endcase
      end
      3'b101: begin // LHU
        if (!ex_mem_alu_result[1])
          mem_load_data = {16'b0, dmem_rdata[15:0]};
        else
          mem_load_data = {16'b0, dmem_rdata[31:16]};
      end
      default: mem_load_data = dmem_rdata;
    endcase
  end

  // WB data mux — resolved in MEM so result is ready for MEM/WB register
  logic [31:0] mem_wb_rd_mux;
  always_comb begin
    case (ex_mem_wb_sel)
      WB_ALU:  mem_wb_rd_mux = ex_mem_alu_result;
      WB_MEM:  mem_wb_rd_mux = ex_mem_is_amo ? amo_rdata_latch : mem_load_data;
      WB_PC4:  mem_wb_rd_mux = ex_mem_pc + 32'd4;
      WB_CSR:  mem_wb_rd_mux = ex_mem_csr_rdata;
      WB_SC:   mem_wb_rd_mux = sc_result;
      default: mem_wb_rd_mux = ex_mem_alu_result;
    endcase
  end

  // =========================================================================
  // MEM/WB Pipeline Register
  // =========================================================================
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      mem_wb_rd_data   <= '0;
      mem_wb_rd_addr   <= '0;
      mem_wb_reg_write <= '0;
      mem_wb_pc        <= '0;
    end else if (!any_stall && !dtlb_miss) begin
      // dtlb_miss: don't advance while ex_mem's WB_MEM data (mem_load_data)
      // may still reflect a stale/premature dcache result racing ahead of
      // the real translation — see stall_if/stall_if_id's dtlb_miss
      // comment above. Without this, mem_wb would keep re-sampling
      // whatever the dcache is currently (possibly incoherently) showing
      // for the untranslated address each cycle any_stall reads 0, and
      // could commit garbage to the register file on the last such sample
      // before dtlb_miss finally clears.
      mem_wb_rd_data   <= mem_wb_rd_mux;
      mem_wb_rd_addr   <= ex_mem_rd_addr;
      mem_wb_reg_write <= ex_mem_reg_write;
      mem_wb_pc        <= ex_mem_pc;
    end
  end

  // WB stage: wire through to register file write port
  assign wb_rd_data   = mem_wb_rd_data;
  assign wb_rd_addr   = mem_wb_rd_addr;
  assign wb_reg_write = mem_wb_reg_write;

  // =========================================================================
  // Hazard Detection
  // =========================================================================
  // Load-use: EX stage has a load whose rd is read by ID stage instruction
  assign load_use_hazard = id_ex_mem_read && (id_ex_rd_addr != 5'b0) &&
    ((id_ex_rd_addr == id_rs1_addr) || (id_ex_rd_addr == id_rs2_addr));

  // any_stall: either cache (icache or dcache) is stalling the pipeline.
  // Flushes are suppressed during a stall so in-flight instructions are
  // replayed correctly once the miss is resolved.
  assign any_stall   = dmem_stall || imem_stall || amo_stall || ptw_stall || mul_stall || div_stall;
  // ex_real_redirect overrides a load-use stall so pc_if can reach the correction target
  //
  // itlb_miss (2026-07-20): OR'd into stall_if/stall_if_id specifically —
  // deliberately NOT into any_stall itself (tried that first; it deadlocked
  // full kernel boot, because any_stall also gates PTW_FAULT's exit and the
  // AMO/PTW dmem-port arbitration, and broadening it stalls those on an
  // unrelated in-flight fetch's translation). Root cause: imem_addr's mux
  // (above) falls through to the raw, UNTRANSLATED VA whenever
  // if_translate_en is true but itlb_hit is false — the icache has no
  // notion of "translation pending" and will happily miss/fill/hit against
  // that raw VA as if it were a real physical address. Normally
  // ptw_will_trigger (folded into ptw_stall, hence any_stall) reacts the
  // very same cycle and holds the fetch through the walk. But
  // ptw_will_trigger's itlb_miss branch is deliberately gated on
  // !amo_wants_start, and the whole expression is gated on
  // amo_state==AMO_IDLE (see ptw_will_trigger's own comment) — so when an
  // AMO wants to start, or is already mid-flight, on the exact cycle an
  // ITLB miss is first detected, the real PTW walk is deferred by one or
  // more cycles. The icache's own miss/fill latency for the bogus
  // untranslated-VA lookup can finish (and report a coincidental "hit")
  // *before* the deferred walk actually starts, leaving a one-cycle window
  // where any_stall alone doesn't hold the fetch — if_id would latch
  // whatever garbage the icache served for the wrong address space as if
  // it were the real instruction. Confirmed via direct signal tracing:
  // mnt_drop_write's `addi sp,sp,-32` (c0098ec8) was replaced by a phantom
  // zero-instruction fetched this way (coinciding with an AMO's
  // amo_wants_start the same cycle), silently skipping the stack
  // allocation and later corrupting a caller's saved ra. itlb_miss is purely
  // combinational on pc_if (same cycle as imem_addr's mux), so OR'ing it
  // into just the fetch-side stall signals closes the gap without touching
  // any_stall's other consumers.
  // itlb_miss qualified with !ex_real_redirect here too, mirroring
  // load_use_hazard exactly: pc_if has no flush/override path of its own
  // (unlike if_id/id_ex, which have flush_if_id/flush_id_ex) — it only
  // ever updates via `!stall_if`. An unqualified itlb_miss term here would
  // permanently block a real redirect (e.g. the ITLB-fault trap-entry
  // target computed via ptw_fault_pending, see ex_target_pc above) from
  // ever reaching pc_if, since the very act of trying to redirect away
  // from the faulting PC doesn't change itlb_miss until pc_if itself
  // changes — a real deadlock, confirmed via simulation (pc_if stuck
  // retrying the same faulting fetch for 75M+ cycles, ptw_state cycling
  // PTW_L1->PTW_FAULT->PTW_IDLE forever, the fault-redirect never landing).
  // dtlb_miss (2026-07-20): same bug class as itlb_miss above, but on the
  // data side — dmem_addr_normal (see its mux comment near dmem_addr) falls
  // through to the raw, untranslated ex_mem_alu_result exactly like
  // imem_addr falls through to raw pc_if, and the same AMO-vs-PTW-trigger
  // one-cycle deferral gap applies (dtlb_miss's branch in ptw_will_trigger
  // is gated on amo_state==AMO_IDLE too). Confirmed: a userspace crash
  // (garbage value loaded into a register during busybox's own startup,
  // corrupting `s3`/main's address before `jalr s3`) traced back to this
  // same untranslated-address race on the load side. dtlb_miss must also
  // reach all the way back to stall_if/stall_if_id (not just id_ex/ex_mem/
  // mem_wb below) — otherwise if_id keeps fetching new instructions into
  // its single-entry buffer while id_ex/ex_mem hold their content back,
  // silently skipping whatever if_id held once id_ex finally resumes.
  // jalr_hold (2026-08-28): an unpredicted JALR (no BTB prediction, so IF is
  // about to speculatively fetch its fall-through) is currently in IF or in ID
  // and has not yet resolved in EX. Freeze pc_if so IF issues no wrong-path
  // fetch past it — see `if_is_jalr`'s comment in the IF section for the full
  // rationale (it removes the trigger for the real-hardware icache tag-misread /
  // ST_RRESP boot hang). The `!ex_real_redirect` guard releases pc_if on the
  // cycle the JALR's own redirect fires (identical pattern to the itlb_miss /
  // dtlb_miss / load_use_hazard terms below — an unqualified term here would
  // deadlock the redirect, since pc_if is frozen ON the JALR whose resolution
  // is what clears the hold). BTB-predicted JALRs are excluded via
  // if_pred_taken / if_id_pred_taken: their speculation is already handled by
  // the normal predict/verify path and must not be stalled.
  assign jalr_hold   = (if_is_jalr  && !if_pred_taken)
                    || (if_id_valid && id_jumpr && !if_id_pred_taken);
  assign stall_if    = (load_use_hazard && !ex_real_redirect) || any_stall_trap ||
                        (itlb_miss && !ex_real_redirect) || (dtlb_miss && !ex_real_redirect) ||
                        (jalr_hold && !ex_real_redirect);
  assign stall_if_id = load_use_hazard || any_stall || itlb_miss || dtlb_miss;
  // ptw_acc==PTW_ACC_FETCH exclusion: same reasoning and same bug as
  // flush_id_ex's own exclusion below (mirrors ex_mem's pre-existing one)
  // — if_id may already hold a completely valid, older, unrelated
  // instruction (the very jal whose *target* fetch is what's faulting)
  // that fetched fine and is one cycle from handing off to id_ex normally.
  // Without this, if_id gets cleared to a bubble here (even once
  // flush_id_ex was already fixed to not discard id_ex's content), losing
  // that jal before it ever reaches id_ex at all — confirmed via
  // simulation: fixing flush_id_ex alone did not change anything, because
  // this is where the same jal was actually still being discarded.
  assign flush_if_id = (ex_real_redirect && !(ptw_fault_pending && ptw_acc == PTW_ACC_FETCH))
                        && !any_stall;
  assign dbg_flush_if_id = flush_if_id;
  // itlb_miss (2026-07-20) deliberately NOT added here, despite an earlier
  // version of this fix adding it — that was a real bug, found via
  // simulation: flush_id_ex CLEARS id_ex's current content, but id_ex may
  // already validly hold a completely different, ready-to-retire
  // instruction (e.g. a JAL about to write ra) on the exact cycle
  // itlb_miss becomes true for whatever if_id/pc_if is fetching NEXT —
  // those are unrelated. id_ex's own advance condition below now carries
  // `!itlb_miss` directly instead (simply not advancing, not flushing) —
  // see its own comment for why that's the correct fix shape here,
  // matching dtlb_miss's existing pattern. dtlb_miss was never added here
  // in the first place — see its own comment near id_ex's/ex_mem's/
  // mem_wb's advance conditions below.
  //
  // A second, related, pre-existing bug (not something this session's own
  // itlb_miss/dtlb_miss changes introduced) found the same way: raw
  // `ex_real_redirect` includes `ptw_fault_pending` unconditionally, with
  // no distinction for WHICH fetch/access the underlying PTW walk was
  // even for. ex_mem's own update logic (below) already correctly
  // excludes an ITLB/fetch-triggered fault (`ptw_acc != PTW_ACC_FETCH`)
  // from disturbing whatever's already validly in ex_mem — "an
  // ITLB-triggered fault must NOT touch EX/MEM, since whatever's there is
  // an older, unrelated instruction that should retire normally" per that
  // branch's own comment — but flush_id_ex had no equivalent exclusion.
  // Confirmed via direct cycle-exact tracing: `__init_libc` calling
  // `memset` via `jal 0x129e3c` — a completely cold, never-before-faulted
  // user code page — legitimately, correctly demand-page-faults on first
  // fetch (a genuine, expected instruction page fault, not a bug in
  // itself). At the exact cycle that fault is recognized (ptw_fault_
  // pending goes high), the *calling* `jal` was still sitting in if_id,
  // one cycle away from transitioning into id_ex — flush_id_ex fired
  // (via ex_real_redirect, via ptw_fault_pending) and cleared id_ex to a
  // bubble *instead of* letting it consume if_id's jal that same edge, so
  // the jal was silently discarded, never reaching id_ex/ex_mem/wb at
  // all, and its rd=ra write never happened. `ra` was left holding
  // whatever it held before the call (the caller's own return-into-
  // __init_libc address), so when memset's `ret` later used it, control
  // jumped all the way back past __init_libc's entire remaining body
  // (skipping its own stack-based s0/s1/ra restore) directly to
  // `__libc_start_main`'s return point — exactly matching the userspace
  // segfault this and the prior session chased (`s3`/`a0` ending up
  // holding a stale, unrelated stack-adjacent value instead of main()'s
  // real address). Fixed by excluding the same `ptw_acc == PTW_ACC_FETCH`
  // case from flush_id_ex's own redirect condition, mirroring ex_mem's
  // existing exclusion exactly. Does not affect DTLB-triggered
  // ptw_fault_pending (ptw_acc will be LOAD/STORE/AMO, never FETCH, for
  // those) — a DTLB fault legitimately should still flush id_ex (whatever
  // NEWER instruction if_id/id_ex held after the faulting older
  // instruction is exactly what should be discarded and re-fetched once
  // the fault is handled and the faulting instruction re-executes).
  // Duplicate-instance flush (2026-07-21, third iteration on this bug):
  // gating self-forwarding alone (the fwd_a/fwd_b guards below) is
  // insufficient — some instructions genuinely need forwarding from their
  // own duplicated ex_mem instance because they have a real load-use
  // dependency on the *previous* instruction that ALSO happens to share
  // rd==rs1 (e.g. vsnprintf's own jump-table dispatch: `lw a4,0(a4)`
  // immediately followed by `add a4,a4,s10`, a completely ordinary
  // accumulate-into-a4 idiom). Once id_ex and ex_mem duplicate (id_ex
  // frozen on itlb_miss while ex_mem catches up, see id_ex_fresh's own
  // comment), suppressing the forward for such an instruction doesn't
  // prevent corruption — it CAUSES it, since with no valid forward id_ex
  // falls back to id_ex_rs1_data, a stale snapshot captured before the
  // preceding load ever completed. Confirmed via cycle-exact tracing
  // (+SPWATCH): ex_mem's own duplicate copy already latched the *correct*
  // result (a valid kernel jump target); once id_ex's identical copy lost
  // its forwarding path, it recomputed a completely different, garbage
  // physical-looking address, which vsnprintf then jumped to via `jr a4`.
  // The real fix has to happen one level up: once ex_mem has captured
  // id_ex's content (id_ex_pc==ex_mem_pc, confirmed via id_ex_fresh — NOT
  // a bare PC compare, which would also misfire on an ordinary tight loop
  // revisiting the same PC across genuinely different iterations), id_ex's
  // own copy is entirely redundant — ex_mem's copy is the one instance
  // that will actually retire — so id_ex should be discarded outright
  // rather than left to recompute or forward anything at all. Deliberately
  // NOT gated by !any_stall (unlike the other flush_id_ex terms): this
  // must fire the very cycle duplication is detected, which is exactly
  // when any_stall is typically still asserted (that's what created the
  // duplicate in the first place).
  logic id_ex_duplicate;
  assign id_ex_duplicate = id_ex_valid && !id_ex_fresh && (id_ex_pc == ex_mem_pc);

  // id_ex_duplicate is gated on !id_ex_advance_ok (2026-07-22): see
  // id_ex_advance_ok's own comment near its declaration for the full
  // diagnosis — when id_ex is simultaneously ready to advance (consume
  // if_id's fresh content) on the same cycle it's flagged as a duplicate
  // of ex_mem, advancing is strictly better than bubbling: it replaces the
  // stale duplicate content (resolving the original double-forwarding
  // hazard this flush exists for) while also not discarding whatever
  // if_id currently holds. Whenever id_ex is NOT simultaneously ready to
  // advance (the scenario this duplicate-flush was originally added for —
  // id_ex still frozen on itlb_miss while ex_mem catches up),
  // id_ex_advance_ok is false too, so this still flushes exactly as before.
  assign flush_id_ex = ((load_use_hazard ||
                         (ex_real_redirect && !(ptw_fault_pending && ptw_acc == PTW_ACC_FETCH))
                        ) && !any_stall) || (id_ex_duplicate && !id_ex_advance_ok);

  // =========================================================================
  // Forwarding Unit
  // =========================================================================
  // !id_ex_fresh && ex_mem_pc==id_ex_pc (2026-07-21): a sixth instance of
  // this phase's recurring "value lost/corrupted near a hazard boundary"
  // bug class, but a genuinely new mechanism (a forwarding-unit self-
  // reference, not a PTW/dmem-port race by itself — though see
  // mem_wants_port's own comment above for a second, related structural bug
  // this same root cause exposed). id_ex's own advance is gated on
  // !itlb_miss (see id_ex's advance-condition comment near the top of this
  // file) so a pending ITLB miss for whatever pc_if is currently fetching
  // freezes id_ex in place — but ex_mem's own advance condition does NOT
  // check itlb_miss at all, so it keeps advancing normally. This lets
  // ex_mem "catch up" and latch id_ex's own (still-frozen, still valid)
  // instruction while id_ex continues to hold that exact same instruction,
  // unable to move on yet. The hazard check below only compares register
  // *addresses* (`ex_mem_rd_addr == id_ex_rs1_addr`), which cannot tell "an
  // older instruction in EX/MEM computed a value this newer instruction in
  // ID/EX needs" apart from "EX/MEM and ID/EX are, for the moment, the
  // identical instruction" — in the latter case it forwards the
  // instruction's own about-to-commit result back into itself as an input,
  // silently double-applying the operation. Confirmed via cycle-exact
  // tracing (+SPWATCH): `put_dec`'s own epilogue `addi sp,sp,32` computed
  // the correct result (sp_before+32) into ex_mem, then — while id_ex still
  // held that same `addi` (frozen on an unrelated itlb_miss for the
  // subsequent `put_dec_trunc8` tail-call fetch) — the forwarding unit fed
  // that already-correct ex_mem result back into id_ex's own rs1, so the
  // *same* `addi` retired a second time computing (sp_before+32)+32,
  // permanently shifting `sp` by 32 bytes for the rest of the caller's
  // frame — corrupting an unrelated, later `ra` slot and causing a bogus
  // return address deep in `vsnprintf`'s own call chain.
  //
  // Took three iterations, each checked against the full kernel boot (not
  // just the 86-test regression, which stayed clean all three times):
  //   1. A bare `ex_mem_pc != id_ex_pc` (unconditional) — hung the full
  //      kernel boot solid (no crash, no further console output past
  //      `Ticket spinlock: enabled`, just TIMEOUT). PC equality alone can't
  //      distinguish this bug's "id_ex frozen, ex_mem duplicates its exact
  //      dynamic instance" from an ordinary tight loop revisiting the same
  //      static PC on successive genuine iterations, where EX/MEM correctly
  //      holds the *previous* iteration's result and ID/EX (a new, later
  //      iteration, same address) legitimately needs it forwarded — the
  //      bare PC check silently discarded that real, necessary forward too.
  //   2. Scoped to `itlb_miss && (ex_mem_pc == id_ex_pc)` — regression-clean
  //      and didn't deadlock, but the identical kernel crash (same Oops,
  //      same cycle count via +MEMTRACE) still reproduced — this fix was a
  //      no-op for the case that mattered. Root cause: id_ex can also stay
  //      frozen *after* itlb_miss itself has cleared to 0 —
  //      `ptw_state==PTW_DONE` keeps any_stall asserted for its own
  //      bookkeeping for a few cycles past where the ITLB fill actually
  //      completed (see ptw_stall's own comment), and id_ex remains stale
  //      through that whole tail even though the itlb_miss term
  //      specifically is gone by then.
  //   3. Fixed by using id_ex_fresh (declared near id_ex's own pipeline
  //      register above) instead of raw itlb_miss — this DID stop the
  //      `put_dec` corruption, but on its own exposed a second, distinct,
  //      genuine deadlock in mem_wants_port's own logic (see that signal's
  //      comment for the full diagnosis and its own matching fix) — both
  //      needed the same id_ex_fresh-based exclusion to resolve together;
  //      neither fix alone was safe. Confirmed the two bugs are separate:
  //      the deadlocking instruction (`class_irqdesc_lock_destructor`'s
  //      `lw a1,4(a5)`) doesn't self-reference (rd=a1, rs1=a5, different
  //      registers) so this forwarding guard's condition never even applied
  //      to it — the deadlock was mem_wants_port's own structural gap.
  // mem_wb_pc guard (2026-07-21, added same day as the EX/MEM fix above):
  // the identical duplication hazard is structurally possible one stage
  // further back too — if id_ex stays frozen (itlb_miss or otherwise) long
  // enough, mem_wb can *also* end up holding the exact same instruction
  // id_ex is still stuck on (ex_mem advances into mem_wb while id_ex never
  // moves). mem_wb previously had no pc field to detect this with; added
  // mem_wb_pc (mirrors ex_mem_pc's own update exactly) purely for this
  // comparison. Added proactively after a second, distinct-looking crash
  // (also inside vsnprintf's call tree, a `cause=0xc` instruction-page-
  // fault jump to a garbage, non-symbol address — not yet fully traced to
  // confirm this exact mechanism, but consistent in shape with the same bug
  // class one stage later) — verify against the full kernel boot same as
  // the EX/MEM fix was.
  always_comb begin
    // Forward A (rs1): EX/MEM takes priority over MEM/WB
    if (ex_mem_reg_write && (ex_mem_rd_addr != 5'b0) && (ex_mem_rd_addr == id_ex_rs1_addr) &&
        !(!id_ex_fresh && (ex_mem_pc == id_ex_pc)))
      fwd_a = 2'b10;
    else if (mem_wb_reg_write && (mem_wb_rd_addr != 5'b0) && (mem_wb_rd_addr == id_ex_rs1_addr) &&
             !(!id_ex_fresh && (mem_wb_pc == id_ex_pc)))
      fwd_a = 2'b01;
    else
      fwd_a = 2'b00;

    // Forward B (rs2)
    if (ex_mem_reg_write && (ex_mem_rd_addr != 5'b0) && (ex_mem_rd_addr == id_ex_rs2_addr) &&
        !(!id_ex_fresh && (ex_mem_pc == id_ex_pc)))
      fwd_b = 2'b10;
    else if (mem_wb_reg_write && (mem_wb_rd_addr != 5'b0) && (mem_wb_rd_addr == id_ex_rs2_addr) &&
             !(!id_ex_fresh && (mem_wb_pc == id_ex_pc)))
      fwd_b = 2'b01;
    else
      fwd_b = 2'b00;
  end

  // =========================================================================
  // Next PC
  // =========================================================================
  always_comb begin
    if (ex_real_redirect)
      next_pc = ex_real_target;
    else if (if_pred_taken)
      next_pc = if_pred_target;
    else
      next_pc = pc_if + 32'd4;
  end

endmodule
