// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Eoghain Gray

// Simulation testbench: 5-stage pipelined RV32IM CPU + direct-mapped icache/dcache + unified memory.
// Clock and reset are driven by the C++ driver (riscv_tb.cpp).
// Load a test image with Verilog plusarg:  +HEX=<file.hex>
// Override tohost address with:            +TOHOST=<hex_addr>

module tb_riscv (
  input  logic        clk,
  input  logic        rst_n,
  // Test pass/fail observation
  output logic        tohost_valid,
  output logic [31:0] tohost_data,
  // UART TX console visibility (Phase 2) — mirrors the tohost_valid/data
  // pattern above. Fires for one cycle whenever the UART's THR is written.
  output logic        uart_tx_valid,
  output logic [7:0]  uart_tx_data,
  // host_rx_valid/host_rx_data (2026-07-22): host-driven UART RX injection,
  // from the C++ driver's own stdin (only when +STDIN_UART is passed —
  // riscv_tb.cpp never touches these otherwise, so this is inert by
  // default). OR'd into the same rx_inject_valid/data path the existing
  // sim-only software backdoor (RX_INJECT_ADDR) already uses — added to
  // let a scripted or interactive test actually exercise the sim-boot-to-
  // shell milestone (type a command, see its output), not just observe the
  // shell prompt appearing once.
  input  logic        host_rx_valid,
  input  logic [7:0]  host_rx_data,
  // host_rx_ready (2026-07-22): direct passthrough of the UART's own
  // dr_status (true = rbr still holds an unread byte) -- riscv_tb.cpp
  // checks this is FALSE before injecting a new host byte, since a single-
  // byte holding register with no FIFO silently drops/overwrites an
  // unread byte if written again too soon. See uart.sv's dr_status comment
  // for the full diagnosis (this fixes real, confirmed dropped characters
  // in scripted shell-interaction tests).
  output logic        host_rx_ready
);
  assign host_rx_ready = !uart_dr_status;

  // -----------------------------------------------------------------------
  // Parameters
  // -----------------------------------------------------------------------
  localparam MEM_WORDS   = 33554432;       // 128 MB (bumped from 64MB same
                                            // day — 64MB left too little
                                            // free RAM after OpenSBI+kernel+
                                            // FDT overhead (~48MB), causing
                                            // a genuine kernel OOM panic
                                            // during boot, not a bug)
  localparam BASE_ADDR   = 32'h80000000;
  localparam TOHOST_DEF  = 32'h80001000;

  // Phase 2 peripheral base addresses (see mmio_decoder for the exact
  // ranges). Sim-only RX-inject backdoor sits just past the UART's 4KB
  // window, never inside it — not a real 16550 register/pin.
  localparam logic [31:0] CLINT_BASE     = 32'h0200_0000;
  localparam logic [31:0] PLIC_BASE      = 32'h0C00_0000;
  localparam logic [31:0] UART_BASE      = 32'h1000_0000;
  localparam logic [31:0] RX_INJECT_ADDR = 32'h1000_1000;
  // SPI_BASE (2026-09-06, SD-card-over-SPI storage effort, see
  // rtl/periph/spi_master.sv): sits past UART's own window and the
  // sim-only RX_INJECT_ADDR just past it.
  localparam logic [31:0] SPI_BASE       = 32'h1000_2000;

  // -----------------------------------------------------------------------
  // Memory model (word-addressed, 32-bit wide)
  // -----------------------------------------------------------------------
  logic [31:0] mem [0:MEM_WORDS-1];

  // CPU ↔ decoder signals (pre-cache; decoder routes to RAM or a peripheral)
  logic [31:0] cpu_dmem_addr, cpu_dmem_wdata, cpu_dmem_rdata;
  logic [3:0]  cpu_dmem_wmask;
  logic        cpu_dmem_wen, cpu_dmem_ren, cpu_dmem_stall;

  // Decoder ↔ dcache signals (RAM path only — MMIO never reaches the cache)
  logic [31:0] ram_addr, ram_wdata, ram_rdata;
  logic [3:0]  ram_wmask;
  logic        ram_wen, ram_ren, ram_stall;

  // Decoder ↔ CLINT/PLIC/UART signals
  logic [31:0] clint_addr, clint_wdata, clint_rdata;
  logic [3:0]  clint_wmask;
  logic        clint_wen, clint_ren;
  logic [31:0] plic_addr, plic_wdata, plic_rdata;
  logic [3:0]  plic_wmask;
  logic        plic_wen, plic_ren;
  logic [31:0] uart_addr, uart_wdata, uart_rdata;
  logic [3:0]  uart_wmask;
  logic        uart_wen, uart_ren;
  logic        uart_dr_status;
  logic [31:0] spi_addr, spi_wdata, spi_rdata;
  logic [3:0]  spi_wmask;
  logic        spi_wen, spi_ren;
  logic        spi_sclk, spi_mosi, spi_miso, spi_cs_n;

  // Peripheral interrupt lines -> CPU
  logic        clint_mtip, clint_msip_irq, plic_meip, plic_seip, uart_irq;

  // Sim-only RX-inject backdoor (see RX_INJECT_ADDR above)
  logic        rx_inject_valid;
  logic [7:0]  rx_inject_data;

  // Cache ↔ memory signals
  logic [31:0] cmem_addr, cmem_wdata, cmem_rdata;
  logic [3:0]  cmem_wmask;
  logic        cmem_wen, cmem_ren;

  // Instruction fetch signals
  logic [31:0] imem_addr, imem_data;
  logic        imem_stall;
  logic        imem_req_hold;
  logic        imem_fence;

  // Icache ↔ memory signals
  logic [31:0] icmem_addr, icmem_rdata;
  logic        icmem_ren;

  // Icache fill memory read — combinational
  logic [24:0] icmem_idx;
  assign icmem_idx   = icmem_addr[26:2];
  assign icmem_rdata = icmem_ren ? mem[icmem_idx] : 32'b0;

  // Data read (cache-to-memory) — combinational
  logic [24:0] cmem_idx;
  assign cmem_idx   = cmem_addr[26:2];
  assign cmem_rdata = cmem_ren ? mem[cmem_idx] : 32'b0;

  // Optional artificial backing-memory latency (+MEMLATENCY=N, default 0 =
  // the pre-existing always-ready/zero-latency behavior below, so every
  // existing test is unaffected). Real DDR/AXI round-trip latency is many
  // cycles, unlike this testbench's combinational RAM -- added 2026-07-23
  // to test whether dcache.sv/icache.sv's documented "hold the request
  // stable until mem_ready pulses, arbitrarily many cycles later" contract
  // actually holds up under more-than-trivial latency, since no existing
  // test (86-test regression or otherwise) had ever exercised it above 0
  // cycles before today (2026-07-23 real-hardware attempt): a kernel/
  // MMU-enable hang reproducible on real hardware but, until this
  // addition, not in sim.
  logic [31:0] mem_latency;
  initial begin
    longint unsigned ml;
    if ($value$plusargs("MEMLATENCY=%d", ml)) mem_latency = ml[31:0];
    else mem_latency = 32'd0;
  end

  logic [31:0] dmem_lat_cnt, imem_lat_cnt;
  logic        dmem_ready_delayed, imem_ready_delayed;

  assign dmem_ready_delayed = (cmem_ren || cmem_wen) && (dmem_lat_cnt >= mem_latency);
  assign imem_ready_delayed = icmem_ren && (imem_lat_cnt >= mem_latency);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)
      dmem_lat_cnt <= 32'd0;
    else if ((cmem_ren || cmem_wen) && !dmem_ready_delayed)
      dmem_lat_cnt <= dmem_lat_cnt + 32'd1;
    else
      dmem_lat_cnt <= 32'd0;
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)
      imem_lat_cnt <= 32'd0;
    else if (icmem_ren && !imem_ready_delayed)
      imem_lat_cnt <= imem_lat_cnt + 32'd1;
    else
      imem_lat_cnt <= 32'd0;
  end

  // Data write — registered, byte-enables
  always_ff @(posedge clk) begin
    if (cmem_wen) begin
      if (cmem_wmask[0]) mem[cmem_idx][7:0]   <= cmem_wdata[7:0];
      if (cmem_wmask[1]) mem[cmem_idx][15:8]  <= cmem_wdata[15:8];
      if (cmem_wmask[2]) mem[cmem_idx][23:16] <= cmem_wdata[23:16];
      if (cmem_wmask[3]) mem[cmem_idx][31:24] <= cmem_wdata[31:24];
    end
  end

  // -----------------------------------------------------------------------
  // CPU instance
  // -----------------------------------------------------------------------
  cpu #(.PC_RESET(BASE_ADDR)) u_cpu (
    .clk        (clk),
    .rst_n      (rst_n),
    .imem_addr  (imem_addr),
    .imem_data  (imem_data),
    .imem_req_hold (imem_req_hold),
    .imem_fence (imem_fence),
    .dmem_addr  (cpu_dmem_addr),
    .dmem_wdata (cpu_dmem_wdata),
    .dmem_wmask (cpu_dmem_wmask),
    .dmem_wen   (cpu_dmem_wen),
    .dmem_ren   (cpu_dmem_ren),
    .dmem_rdata (cpu_dmem_rdata),
    .dmem_stall (cpu_dmem_stall),
    .imem_stall (imem_stall),
    .irq_mtip   (clint_mtip),
    .irq_meip   (plic_meip),
    .irq_msip   (clint_msip_irq),
    .irq_seip   (plic_seip)
  );

  // -----------------------------------------------------------------------
  // MMIO address decoder — sits between the CPU's dmem port and the dcache.
  // MMIO addresses never reach the dcache (so they're never wrongly
  // cached); every other address passes through to RAM unchanged.
  // -----------------------------------------------------------------------
  mmio_decoder #(
    .CLINT_BASE(CLINT_BASE), .PLIC_BASE(PLIC_BASE), .UART_BASE(UART_BASE),
    .SPI_BASE(SPI_BASE)
  ) u_mmio_decoder (
    .cpu_addr    (cpu_dmem_addr),
    .cpu_wdata   (cpu_dmem_wdata),
    .cpu_wmask   (cpu_dmem_wmask),
    .cpu_wen     (cpu_dmem_wen),
    .cpu_ren     (cpu_dmem_ren),
    .cpu_rdata   (cpu_dmem_rdata),
    .cpu_stall   (cpu_dmem_stall),
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
    .spi_rdata   (spi_rdata)
  );

  clint #(.BASE_ADDR(CLINT_BASE)) u_clint (
    .clk      (clk),
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
    .clk         (clk),
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

  uart #(.BASE_ADDR(UART_BASE)) u_uart (
    .clk             (clk),
    .rst_n           (rst_n),
    .addr            (uart_addr),
    .wdata           (uart_wdata),
    .wmask           (uart_wmask),
    .wen             (uart_wen),
    .ren             (uart_ren),
    .rdata           (uart_rdata),
    .tx_valid        (uart_tx_valid),
    .tx_data         (uart_tx_data),
    .tx_busy         (1'b0),          // no ps_uart0_bridge in this sim chain
    .rx_inject_valid (rx_inject_valid),
    .rx_inject_data  (rx_inject_data),
    .irq             (uart_irq),
    .dr_status       (uart_dr_status)
  );

  // SD-card-over-SPI storage effort (2026-09-06): spi_master.sv wired to a
  // behavioral SD card model (sim/spi-sd-tests/sd_card_model.sv) via real
  // spi_sclk/spi_mosi/spi_miso/spi_cs_n signals, not a shortcut register
  // peek -- see that model's own header for what it does and doesn't check.
  spi_master #(.BASE_ADDR(SPI_BASE)) u_spi_master (
    .clk      (clk),
    .rst_n    (rst_n),
    .addr     (spi_addr),
    .wdata    (spi_wdata),
    .wmask    (spi_wmask),
    .wen      (spi_wen),
    .ren      (spi_ren),
    .rdata    (spi_rdata),
    .spi_sclk (spi_sclk),
    .spi_mosi (spi_mosi),
    .spi_miso (spi_miso),
    .spi_cs_n (spi_cs_n)
  );

  sd_card_model u_sd_card_model (
    .spi_sclk (spi_sclk),
    .spi_mosi (spi_mosi),
    .spi_miso (spi_miso),
    .spi_cs_n (spi_cs_n)
  );

  // Sim-only RX-inject backdoor: a store to RX_INJECT_ADDR pulses the
  // UART's rx_inject_valid/data one cycle later. Not a real register —
  // deterministic, test-controlled substitute for an actual RX wire.
  // host_rx_valid (2026-07-22): OR'd in alongside the pre-existing
  // software-triggered path — see host_rx_valid's own port comment above.
  // Given priority on a same-cycle conflict (won't happen in practice: the
  // two sources are never driven the same cycle by anything this project
  // actually runs).
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rx_inject_valid <= 1'b0;
      rx_inject_data  <= 8'h0;
    end else if (host_rx_valid) begin
      rx_inject_valid <= 1'b1;
      rx_inject_data  <= host_rx_data;
    end else begin
      rx_inject_valid <= cpu_dmem_wen && (cpu_dmem_addr == RX_INJECT_ADDR) && (|cpu_dmem_wmask);
      rx_inject_data  <= cpu_dmem_wdata[7:0];
    end
  end

  // -----------------------------------------------------------------------
  // Direct-mapped data cache (256 sets, 4 words/line = 4 KB)
  // -----------------------------------------------------------------------
  dcache #(.SETS(256), .WORDS_PER_LINE(4)) u_dcache (
    .clk        (clk),
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
    .mem_ready  (dmem_ready_delayed) // see +MEMLATENCY above (0 = old always-ready)
  );

  // -----------------------------------------------------------------------
  // Direct-mapped instruction cache (256 sets, 4 words/line = 4 KB)
  // -----------------------------------------------------------------------
  icache #(.SETS(256), .WORDS_PER_LINE(4)) u_icache (
    .clk        (clk),
    .rst_n      (rst_n),
    .cpu_addr   (imem_addr),
    .cpu_rdata  (imem_data),
    .cache_stall(imem_stall),
    .req_hold   (imem_req_hold),
    .fence_i    (imem_fence),
    .mem_addr   (icmem_addr),
    .mem_ren    (icmem_ren),
    .mem_rdata  (icmem_rdata),
    .mem_ready  (imem_ready_delayed) // see +MEMLATENCY above (0 = old always-ready)
  );

  // -----------------------------------------------------------------------
  // tohost detection — observe the CPU's store before it reaches memory.
  // Stores are write-through so cpu_dmem_wen fires on the same cycle as cmem_wen.
  // -----------------------------------------------------------------------
  logic [31:0] tohost_addr;

  assign tohost_valid = cpu_dmem_wen && (cpu_dmem_addr == tohost_addr) && (|cpu_dmem_wmask);
  assign tohost_data  = cpu_dmem_wdata;

  // -----------------------------------------------------------------------
  // Debug: PC trace (+TRACE) and backing-memory read/write trace
  // (+MEMTRACE), both off by default (zero cost otherwise). Useful for
  // diagnosing "nothing prints" boot failures (OpenSBI, later a kernel)
  // where tohost/UART give no signal at all, and for distinguishing a
  // genuine data-path bug from a CPU-internal pipeline/hazard bug when a
  // memory-side backing-store timing change is in play (see dcache.sv's
  // mem_ready handshake, added for Phase 3's AXI/DDR bridge work).
  //
  // dbg_cycle (2026-07-18, temporary): free-running cycle counter tagged
  // onto every TRACE/MEMTRACE/UARTW line so a cheap MEMTRACE-only pass can
  // pin an exact cycle number for a console marker (e.g. a kernel pr_err),
  // which a later +TRACE run can then bound tightly with +MAXCYCLES
  // instead of guessing a window from line position alone. Remove once
  // the current ETXTBSY investigation concludes.
  // -----------------------------------------------------------------------
  logic [63:0] dbg_cycle;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) dbg_cycle <= 64'd0;
    else        dbg_cycle <= dbg_cycle + 64'd1;
  end

  // dbg_trace_start (2026-07-18, temporary): optional +TRACESTART=<n> floor
  // so a +TRACE dump can be bounded to a tight window (found via a cheap
  // MEMTRACE-only pass first) instead of dumping from cycle 0, which is
  // prohibitively large once boot has run into the hundreds of millions of
  // cycles. Defaults to 0 (dump from the start) when unset.
  logic [63:0] dbg_trace_start;
  initial begin
    longint unsigned ts;
    if ($value$plusargs("TRACESTART=%d", ts)) dbg_trace_start = ts;
    else                                       dbg_trace_start = 64'd0;
  end

  always_ff @(posedge clk) begin
    if ($test$plusargs("TRACE") && dbg_cycle >= dbg_trace_start)
      // idexpc/idexjump/idexjumpr/exredirect/exrealredirect/extargetpc/
      // idexpredtaken/idexpredtarget/anystall (2026-07-19, temporary):
      // re-added to trace a wrong-sp-after-return bug — sp is correct
      // through mnt_drop_write()'s tail-call into percpu_up_read(), but
      // wrong (shifted by exactly one vfs_truncate frame, +32) by the time
      // control returns to vfs_truncate's epilogue. Remove once resolved.
      // fillidx/filltag/fillword/cvalid/ctag (2026-07-20, temporary): added
      // to directly observe the icache's fill FSM and the stored valid/tag
      // for the currently-addressed set, for the wrong-instruction-word
      // bug. Remove once resolved.
      $display("cyc=%0d imemaddr=%08x imemstall=%0d imemdata=%08x icstate=%0d ichit=%0d icaddridx=%02x icaddrtag=%05x cvalid=%0d ctag=%05x fillidx=%02x filltag=%05x fillword=%0d ifidpc=%08x ifidinstr=%08x ifidvalid=%0d anystall=%0d",
                dbg_cycle, imem_addr, imem_stall, imem_data,
                u_icache.state, u_icache.cache_hit, u_icache.addr_idx, u_icache.addr_tag,
                u_icache.c_valid[u_icache.addr_idx], u_icache.c_tag[u_icache.addr_idx],
                u_icache.fill_idx, u_icache.fill_tag, u_icache.fill_word,
                u_cpu.if_id_pc, u_cpu.if_id_instr, u_cpu.if_id_valid, u_cpu.any_stall);
    if ($test$plusargs("MEMTRACE")) begin
      if (cmem_wen)
        $display("cyc=%0d MEMW addr=%08x data=%08x wmask=%b", dbg_cycle, cmem_addr, cmem_wdata, cmem_wmask);
      if (cmem_ren)
        $display("cyc=%0d MEMR addr=%08x data=%08x", dbg_cycle, cmem_addr, cmem_rdata);
      // IMEMR (2026-07-19, temporary): icache reads (icmem_ren/icmem_addr/
      // icmem_rdata) were never captured by MEMTRACE before — MEMR only
      // ever checked cmem_ren (the dcache path). Added while diagnosing a
      // wrong-instruction-word bug where the icache appears to serve stale/
      // wrong data for an already-should-be-cached code address. Remove
      // once resolved.
      if (icmem_ren)
        $display("cyc=%0d IMEMR addr=%08x data=%08x", dbg_cycle, icmem_addr, icmem_rdata);
      if (uart_wen)
        $display("cyc=%0d UARTW addr=%08x data=%08x wmask=%b", dbg_cycle, uart_addr, uart_wdata, uart_wmask);
      // UARTR (2026-07-22, temporary): MEMTRACE never logged UART reads
      // before (only cmem_ren/icmem_ren/uart_wen) -- added while
      // diagnosing a silent post-/init hang, to see whether the kernel's
      // tty/serial core ever actually reads LSR/MSR/etc. at all after
      // programming the UART's control registers. Remove once resolved.
      if (uart_ren)
        $display("cyc=%0d UARTR addr=%08x data=%08x", dbg_cycle, uart_addr, uart_rdata);
    end
    // IRQTRACE (2026-07-20, temporary): hypothesis-free sweep — fires every
    // time irq_taken_now squashes a REAL (id_ex_valid=1, non-bubble)
    // control-transfer instruction (jal/jalr/branch) sitting in id_ex, for
    // the whole boot. Tests the general "interrupt lands on an in-flight
    // jump/branch, redo via sepc=id_ex_pc doesn't actually redo it
    // correctly" bug class directly, instead of guessing a specific call
    // site each time this bug resurfaces at a new location. Remove once
    // resolved.
    if ($test$plusargs("IRQTRACE") && u_cpu.irq_taken_now && u_cpu.id_ex_valid &&
        (u_cpu.id_ex_jump || u_cpu.id_ex_jumpr || u_cpu.id_ex_branch))
      $display("cyc=%0d IRQ idexpc=%08x idexjump=%0d idexjumpr=%0d idexbranch=%0d sepc=%08x mepc=%08x extargetpc=%08x",
                dbg_cycle, u_cpu.id_ex_pc, u_cpu.id_ex_jump, u_cpu.id_ex_jumpr, u_cpu.id_ex_branch,
                u_cpu.csr_sepc, u_cpu.csr_mepc, u_cpu.ex_target_pc);
    // JUMPTRACE (2026-07-20, temporary): every retiring jal/jalr in a
    // +TRACESTART-bounded window, source PC -> computed target. Used to scan
    // a narrow (~tens-of-thousands-of-cycles) window between a known-good
    // checkpoint and a later crash for the first call/return target that
    // doesn't correspond to a legitimate function entry/return address.
    // Remove once resolved.
    // PTWTRACE (2026-07-20, temporary): checks whether the ITLB-miss ->
    // PTW-walk trigger actually fires for a specific fetch, or whether the
    // icache's own (wrong-address) miss/fill latency is the only thing
    // holding any_stall, letting the pipeline move on before a real
    // translation ever happens. Bounded via +TRACESTART. Remove once
    // resolved.
    if ($test$plusargs("PTWTRACE") && dbg_cycle >= dbg_trace_start)
      $display("cyc=%0d PTW pcif=%08x itlbhit=%0d itlbmiss=%0d dtlbhit=%0d dtlbmiss=%0d exmempc=%08x exmemneedsmem=%0d exmemaluresult=%08x ptwstate=%0d ptwactive=%0d ptwwilltrig=%0d ptwstall=%0d amostate=%0d amowantsstart=%0d imemstall=%0d anystall=%0d",
                dbg_cycle, u_cpu.pc_if, u_cpu.itlb_hit, u_cpu.itlb_miss,
                u_cpu.dtlb_hit, u_cpu.dtlb_miss, u_cpu.ex_mem_pc, u_cpu.ex_mem_needs_mem,
                u_cpu.ex_mem_alu_result, u_cpu.ptw_state,
                u_cpu.ptw_active, u_cpu.ptw_will_trigger, u_cpu.ptw_stall,
                u_cpu.amo_state, u_cpu.amo_wants_start, u_cpu.imem_stall, u_cpu.any_stall);
    // HAZTRACE (2026-07-20, temporary): every cycle, dump the forwarding
    // unit's inputs/outputs plus id_ex_pc, to catch — cycle-exact — why
    // mnt_drop_write's own `sw ra,28(sp)` (c0098ecc) used a stale
    // (pre-decrement) sp, landing on the exact same physical stack address
    // as its caller's (vfs_truncate's) own already-saved ra and overwriting
    // it (confirmed via MEMTRACE: both writes target the same address).
    // Bounded tightly via +TRACESTART/+MAXCYCLES around the single known
    // failing occurrence. Remove once resolved.
    if ($test$plusargs("HAZTRACE") && dbg_cycle >= dbg_trace_start)
      $display("cyc=%0d HAZ idexpc=%08x idexrs1=%0d fwda=%0d exmemrw=%0d exmemrd=%0d exmemalu=%08x memwbrw=%0d memwbrd=%0d memwbdata=%08x anystall=%0d exalua=%08x exaluresult=%08x sp=%08x",
                dbg_cycle, u_cpu.id_ex_pc, u_cpu.id_ex_rs1_addr, u_cpu.fwd_a,
                u_cpu.ex_mem_reg_write, u_cpu.ex_mem_rd_addr, u_cpu.ex_mem_alu_result,
                u_cpu.mem_wb_reg_write, u_cpu.mem_wb_rd_addr, u_cpu.mem_wb_rd_data,
                u_cpu.any_stall, u_cpu.ex_alu_a, u_cpu.ex_alu_result, u_cpu.u_rf.regs[2]);
    // BBTRACE (2026-07-20, temporary): tracks s3/a0/ra/sp across busybox's
    // init_array-calling loop (0x10ac90, called from 0x10ad0c) leading up
    // to `jalr s3` (0x10ad1c) calling main() — s3 is set once (`mv s3,a0`
    // at 0x10ad08) and must survive the loop untouched (callee-saved) but
    // a later boot crashed there with s3 corrupted. Bounded via
    // +TRACESTART for cheapness. Remove once resolved.
    if ($test$plusargs("BBTRACE") && dbg_cycle >= dbg_trace_start && u_cpu.id_ex_valid && !u_cpu.any_stall &&
        u_cpu.id_ex_pc >= 32'h0010aa90 && u_cpu.id_ex_pc <= 32'h0010ad20)
      $display("cyc=%0d BB idexpc=%08x s0=%08x s1=%08x a0=%08x ra=%08x sp=%08x",
                dbg_cycle, u_cpu.id_ex_pc, u_cpu.u_rf.regs[8], u_cpu.u_rf.regs[9],
                u_cpu.u_rf.regs[10], u_cpu.u_rf.regs[1], u_cpu.u_rf.regs[2]);
    // S1SLOTTRACE (2026-07-20, temporary): watches the exact store
    // (`sw s1,196(sp)` at busybox+0x10aaa0, __init_libc's own prologue
    // saving the caller's s1/main-pointer) and the exact matching restore
    // (`lw s1,196(sp)` at busybox+0x10ac2c, its epilogue) to see whether
    // the stack slot round-trips correctly or gets clobbered in between.
    // Remove once resolved.
    if ($test$plusargs("S1SLOTTRACE") &&
        ((u_cpu.dmem_addr == 32'h806eaef4) && (u_cpu.dmem_wen || u_cpu.dmem_ren)))
      $display("cyc=%0d S1SLOT exmempc=%08x dmemaddr=%08x dmemwdata=%08x dmemwen=%0d dmemren=%0d dmemrdata=%08x",
                dbg_cycle, u_cpu.ex_mem_pc, u_cpu.dmem_addr, u_cpu.dmem_wdata,
                u_cpu.dmem_wen, u_cpu.dmem_ren, u_cpu.dmem_rdata);
    // VARTABWATCH (2026-07-22, temporary): address-watch on the ash vartab
    // bucket slot at physical 0x806eeaec (same template as S1SLOTTRACE
    // above). A +MEMTRACE pass found this slot legitimately written with a
    // real, word-aligned heap pointer (0x886876a0) at cyc=155177310, then
    // clobbered twice in quick succession -- 0x9d30dfd6 at cyc=155191935
    // (11 cycles later) and 0x9d30dfde at cyc=155206082 (~14.7K cycles
    // later) -- both stack-shaped (not word-aligned), the second of which
    // persists and is what crashes ash's hash-chain walk later. This watch
    // adds ex_mem_pc (the source PC) and s2 (setvareq's `vpp` bucket
    // pointer, per prior static disassembly of setvareq+0x19c) to identify
    // exactly which instruction issues the two stray stores -- suspected
    // to be vfork()'d-child argv/envp stack setup miscomputing its
    // destination address and stomping the parent's heap (vfork shares the
    // literal same address space until execve()). Remove once resolved.
    // JALENDOFNAMEWATCH (2026-07-22, temporary): watches the specific
    // `jal endofname` at busybox+0x7f8cc (called from setvar(), targeting
    // 0xf4e10) through every pipeline stage, unconditionally (no
    // +TRACESTART gate), to find exactly when it executes and whether its
    // own rd=ra register writeback (which should set ra=0x7f8d0) actually
    // commits -- suspected dropped due to an ITLB/page-fault on its own
    // jump target's first fetch. Remove once resolved.
    if ($test$plusargs("JALENDOFNAMEWATCH") &&
        (u_cpu.if_id_pc == 32'h0007f8cc || u_cpu.id_ex_pc == 32'h0007f8cc ||
         u_cpu.ex_mem_pc == 32'h0007f8cc || u_cpu.mem_wb_pc == 32'h0007f8cc))
      $display("cyc=%0d JALEON ifidpc=%08x idexpc=%08x exmempc=%08x memwbpc=%08x idexjump=%0d exmemregwrite=%0d exmemrd=%0d itlbmiss=%0d anystall=%0d memwbrw=%0d memwbrd=%0d memwbdata=%08x",
                dbg_cycle, u_cpu.if_id_pc, u_cpu.id_ex_pc, u_cpu.ex_mem_pc, u_cpu.mem_wb_pc,
                u_cpu.id_ex_jump, u_cpu.ex_mem_reg_write, u_cpu.ex_mem_rd_addr,
                u_cpu.itlb_miss, u_cpu.any_stall,
                u_cpu.mem_wb_reg_write, u_cpu.mem_wb_rd_addr, u_cpu.mem_wb_rd_data);
    // INITFRAMEWATCH (2026-07-22, temporary): watches init()'s own
    // prologue save (busybox+0x84824, `sw s0,536(sp)`) and epilogue
    // restore (busybox+0x849c8, `lw s0,536(sp)`) directly by PC, to get
    // the exact physical address of this stack slot (whose restored
    // content was found wrong -- 0x7c instead of the saved G_misc
    // pointer -- via +S0WATCH). Remove once resolved.
    if ($test$plusargs("INITFRAMEWATCH") && u_cpu.dmem_wen &&
        u_cpu.ex_mem_pc == 32'h00084824)
      $display("cyc=%0d INITFRAME_SAVE exmempc=%08x dmemaddr=%08x dmemwdata=%08x",
                dbg_cycle, u_cpu.ex_mem_pc, u_cpu.dmem_addr, u_cpu.dmem_wdata);
    if ($test$plusargs("INITFRAMEWATCH") && u_cpu.dmem_ren &&
        u_cpu.ex_mem_pc == 32'h000849c8)
      $display("cyc=%0d INITFRAME_RESTORE exmempc=%08x dmemaddr=%08x dmemrdata=%08x",
                dbg_cycle, u_cpu.ex_mem_pc, u_cpu.dmem_addr, u_cpu.dmem_rdata);
    // ARG0WATCH (2026-07-22, temporary): watches the two `arg0 = ...`
    // stores in procargs() (busybox+0x8ab40 / +0x8adb4, statically
    // confirmed as ash.c:14929/14968) directly by PC, printing s0 (the
    // base register procargs uses, presumed G_misc but not yet confirmed
    // by direct register capture) alongside the store's actual physical
    // destination and value -- to check whether s0 really does equal
    // G_misc's base (found via +GVARINITWATCH) or something else entirely.
    // Remove once resolved.
    if ($test$plusargs("ARG0WATCH") && u_cpu.dmem_wen &&
        (u_cpu.ex_mem_pc == 32'h0008ab40 || u_cpu.ex_mem_pc == 32'h0008adb4))
      $display("cyc=%0d ARG0W exmempc=%08x dmemaddr=%08x dmemwdata=%08x s0=%08x",
                dbg_cycle, u_cpu.ex_mem_pc, u_cpu.dmem_addr, u_cpu.dmem_wdata,
                u_cpu.u_rf.regs[8]);
    // GVARINITWATCH (2026-07-22, temporary): watches the three back-to-back
    // xzalloc()+store sequences at ash_main's very start (busybox+0x8a964 /
    // +0x8a99c / +0x8a9cc -- INIT_G_misc/INIT_G_memstack/INIT_G_var storing
    // their fresh xzalloc() result into ash_ptr_to_globals_misc/memstack/var
    // respectively, confirmed via static disassembly) directly, to check
    // whether G_misc and G_var (suspected of aliasing per the vartab
    // corruption investigation) really do get the same pointer value back
    // from xzalloc(). Prints the store's destination (dmem_addr, physical,
    // post-DTLB) and the value stored (dmem_wdata, the xzalloc'd pointer).
    // Remove once resolved.
    if ($test$plusargs("GVARINITWATCH") &&
        u_cpu.dmem_wen &&
        (u_cpu.ex_mem_pc == 32'h0008a964 || u_cpu.ex_mem_pc == 32'h0008a99c ||
         u_cpu.ex_mem_pc == 32'h0008a9cc))
      $display("cyc=%0d GVARINIT exmempc=%08x dmemaddr=%08x dmemwdata=%08x",
                dbg_cycle, u_cpu.ex_mem_pc, u_cpu.dmem_addr, u_cpu.dmem_wdata);
    if ($test$plusargs("VARTABWATCH") &&
        ((u_cpu.dmem_addr == 32'h806eeaec) && (u_cpu.dmem_wen || u_cpu.dmem_ren)))
      $display("cyc=%0d VARTABSLOT exmempc=%08x dmemaddr=%08x dmemwdata=%08x dmemwen=%0d dmemren=%0d dmemrdata=%08x sp=%08x s0=%08x s2=%08x",
                dbg_cycle, u_cpu.ex_mem_pc, u_cpu.dmem_addr, u_cpu.dmem_wdata,
                u_cpu.dmem_wen, u_cpu.dmem_ren, u_cpu.dmem_rdata,
                u_cpu.u_rf.regs[2], u_cpu.u_rf.regs[8], u_cpu.u_rf.regs[18]);
    // MWPTRACE (2026-07-21, temporary): unconditional per-cycle dump of
    // mem_wants_port/itlb_miss/dtlb_miss/ptw state plus ex_mem's own
    // memory-op status and mem_wb's commit info, to investigate a NEW
    // regression introduced by the mem_wants_port fix itself (an early
    // kernel-boot "swapper NULL pointer dereference at 0x400" Oops that
    // did not occur before the fix) — an ITLB(FETCH) page fault at
    // sepc=0x804000a0 is the only trap event in the run-up to this crash.
    // Bounded via +TRACESTART. Remove once resolved.
    if ($test$plusargs("MWPTRACE") && dbg_cycle >= dbg_trace_start)
      $display("cyc=%0d MWP pcif=%08x ifidpc=%08x idexpc=%08x exmempc=%08x exmemneedsmem=%0d exmemregwrite=%0d exmemrd=%0d dtlbmiss=%0d itlbmiss=%0d memwantsport=%0d dmemstall=%0d imemstall=%0d ptwstate=%0d ptwacc=%0d ptwfaultpending=%0d anystall=%0d stallif=%0d stallifid=%0d exrealredirect=%0d ifidvalid=%0d dmemaddr=%08x dmemren=%0d dmemrdata=%08x memwbrw=%0d memwbrd=%0d memwbdata=%08x",
                dbg_cycle, u_cpu.pc_if, u_cpu.if_id_pc, u_cpu.id_ex_pc, u_cpu.ex_mem_pc, u_cpu.ex_mem_needs_mem,
                u_cpu.ex_mem_reg_write, u_cpu.ex_mem_rd_addr,
                u_cpu.dtlb_miss, u_cpu.itlb_miss, u_cpu.mem_wants_port, u_cpu.dmem_stall, u_cpu.imem_stall,
                u_cpu.ptw_state, u_cpu.ptw_acc, u_cpu.ptw_fault_pending, u_cpu.any_stall,
                u_cpu.stall_if, u_cpu.stall_if_id, u_cpu.ex_real_redirect, u_cpu.if_id_valid,
                u_cpu.dmem_addr, u_cpu.dmem_ren, u_cpu.dmem_rdata,
                u_cpu.mem_wb_reg_write, u_cpu.mem_wb_rd_addr, u_cpu.mem_wb_rd_data);
    // S0WATCH (2026-07-21, temporary): watches register x8 (s0) at actual
    // write-back commit (program order, unambiguous unlike mid-pipeline
    // snapshots), tagged with the retiring PC and, for loads, the exact
    // dmem address that produced the value — to trace the ash/vartab
    // hash-chain-walk corruption (crash at busybox+0x81598) back to its
    // true origin. Remove once resolved.
    if ($test$plusargs("S0WATCH") && dbg_cycle >= dbg_trace_start &&
        u_cpu.mem_wb_reg_write && (u_cpu.mem_wb_rd_addr == 5'd8))
      $display("cyc=%0d S0W pc=%08x s0=%08x",
                dbg_cycle, u_cpu.mem_wb_pc, u_cpu.mem_wb_rd_data);
    // SPWATCH (2026-07-21, temporary): watches register x2 (sp) every
    // cycle plus flags any register-file write targeting x2, to find
    // exactly when/how `number()`'s own sp drifts from its prologue value
    // (0x8071bcc0) to a different value (0x8071bce0) by the time its
    // epilogue runs — a 32-byte, unexplained shift within what should be a
    // single straight-line function body with no intervening sp adjustment.
    // Remove once resolved.
    if ($test$plusargs("SPWATCH") && dbg_cycle >= dbg_trace_start)
      $display("cyc=%0d SPW idexpc=%08x idexrd=%0d idexvalid=%0d ifidpc=%08x ifidvalid=%0d exmempc=%08x exmemrd=%0d exmemregwrite=%0d exmemalu=%08x sp=%08x memwbrw=%0d memwbrd=%0d memwbdata=%08x anystall=%0d exaluresulta=%08x fwda=%0d",
                dbg_cycle, u_cpu.id_ex_pc, u_cpu.id_ex_rd_addr, u_cpu.id_ex_valid,
                u_cpu.if_id_pc, u_cpu.if_id_valid,
                u_cpu.ex_mem_pc, u_cpu.ex_mem_rd_addr,
                u_cpu.ex_mem_reg_write, u_cpu.ex_mem_alu_result, u_cpu.u_rf.regs[2],
                u_cpu.mem_wb_reg_write, u_cpu.mem_wb_rd_addr, u_cpu.mem_wb_rd_data,
                u_cpu.any_stall, u_cpu.ex_alu_result, u_cpu.fwd_a);
    // TRAPTRACE2 (2026-07-20, temporary): checks whether id_ex's own
    // reg_write/jal properly propagates to ex_mem on the exact cycle an
    // ITLB/fetch ptw_fault_pending fires, to distinguish "ex_mem correctly
    // captured it but id_ex's OWN flush discarded something else" from
    // "ex_mem itself never advanced". Remove once resolved.
    if ($test$plusargs("TRAPTRACE2") && dbg_cycle >= dbg_trace_start)
      $display("cyc=%0d T2 idexpc=%08x idexvalid=%0d idexjump=%0d idexregwrite=%0d idexrd=%0d anystall=%0d dmemstall=%0d imemstall=%0d amostall=%0d ptwstall=%0d ptwfaultpending=%0d ptwacc=%0d flushidex=%0d exmempc=%08x exmemregwrite=%0d exmemrd=%0d",
                dbg_cycle, u_cpu.id_ex_pc, u_cpu.id_ex_valid, u_cpu.id_ex_jump,
                u_cpu.id_ex_reg_write, u_cpu.id_ex_rd_addr, u_cpu.any_stall,
                u_cpu.dmem_stall, u_cpu.imem_stall, u_cpu.amo_stall, u_cpu.ptw_stall,
                u_cpu.ptw_fault_pending, u_cpu.ptw_acc, u_cpu.flush_id_ex,
                u_cpu.ex_mem_pc, u_cpu.ex_mem_reg_write, u_cpu.ex_mem_rd_addr);
    // TRAPTRACE (2026-07-20, temporary): watches every trap-entry event
    // (irq_taken_now, ptw_fault_pending, ecall/mret/sret) with full cause/
    // epc context, bounded via +TRACESTART, to identify exactly what kind
    // of trap redirects execution away from `jal 0x129e3c` (memset) right
    // as it retires. Remove once resolved.
    if ($test$plusargs("TRAPTRACE") && dbg_cycle >= dbg_trace_start &&
        (u_cpu.irq_taken_now || u_cpu.ptw_fault_pending || u_cpu.id_ex_is_ecall ||
         u_cpu.id_ex_is_mret || u_cpu.id_ex_is_sret))
      $display("cyc=%0d TRAP idexpc=%08x irqnow=%0d ptwfaultpending=%0d ecall=%0d mret=%0d sret=%0d scause=%08x sepc=%08x mcause=%08x mepc=%08x irqcause=%08x",
                dbg_cycle, u_cpu.id_ex_pc, u_cpu.irq_taken_now, u_cpu.ptw_fault_pending,
                u_cpu.id_ex_is_ecall, u_cpu.id_ex_is_mret, u_cpu.id_ex_is_sret,
                u_cpu.csr_scause, u_cpu.csr_sepc, u_cpu.csr_mcause, u_cpu.csr_mepc,
                u_cpu.irq_cause);
    // MEMSETCALLTRACE (2026-07-20, temporary): watches the exact
    // `jal 0x129e3c` (busybox+0x10aabc, __init_libc calling memset) —
    // id_ex_jump, ex_target_pc, and the live ra register — to see directly
    // whether this jal's own rd=ra write actually commits. Remove once
    // resolved.
    if ($test$plusargs("MEMSETCALLTRACE") &&
        (u_cpu.id_ex_pc >= 32'h0010aab4 && u_cpu.id_ex_pc <= 32'h0010aac8))
      $display("cyc=%0d MSC idexpc=%08x idexvalid=%0d idexjump=%0d anystall=%0d extargetpc=%08x ra=%08x",
                dbg_cycle, u_cpu.id_ex_pc, u_cpu.id_ex_valid, u_cpu.id_ex_jump,
                u_cpu.any_stall, u_cpu.ex_target_pc, u_cpu.u_rf.regs[1]);
    // BBTRACE2 (2026-07-20, temporary): wider PC range covering
    // __init_libc's own restore/ret (0x10ac2c-0x10ac38) AND
    // __libc_start_main's own body (0x10ad24-0x10ad78) where it reads a0
    // from its own s1 before tail-jumping — the original +BBTRACE's PC
    // range (<=0x10ad20) excluded this second part entirely. Tracks sp/s1
    // together so a mismatched sp between the save and this read (a stack
    // imbalance bug) would show up directly. Remove once resolved.
    if ($test$plusargs("BBTRACE2") && u_cpu.id_ex_valid && !u_cpu.any_stall &&
        ((u_cpu.id_ex_pc >= 32'h0010ac1c && u_cpu.id_ex_pc <= 32'h0010ac90) ||
         (u_cpu.id_ex_pc >= 32'h0010ad24 && u_cpu.id_ex_pc <= 32'h0010ad78)))
      $display("cyc=%0d BB2 idexpc=%08x s0=%08x s1=%08x a0=%08x ra=%08x sp=%08x",
                dbg_cycle, u_cpu.id_ex_pc, u_cpu.u_rf.regs[8], u_cpu.u_rf.regs[9],
                u_cpu.u_rf.regs[10], u_cpu.u_rf.regs[1], u_cpu.u_rf.regs[2]);
    // SPTRACE (2026-07-20, temporary): tracks sp (x2) and ra (x1) across
    // vfs_truncate -> mnt_drop_write -> percpu_up_read (incl. its
    // rcuwait_wake_up slow path) -> back to vfs_truncate's epilogue, the
    // exact call chain a 2026-07-19 comment flagged as having sp "shifted
    // by exactly one vfs_truncate frame, +32" by the time control returns
    // to vfs_truncate's epilogue. Bounded via +TRACESTART for cheapness.
    // Remove once resolved.
    if ($test$plusargs("SPTRACE") && dbg_cycle >= dbg_trace_start && u_cpu.id_ex_valid && !u_cpu.any_stall &&
        ((u_cpu.id_ex_pc >= 32'hc007e5a8 && u_cpu.id_ex_pc <= 32'hc007e6ac) ||
         (u_cpu.id_ex_pc >= 32'hc0098e68 && u_cpu.id_ex_pc <= 32'hc0098eec) ||
         (u_cpu.id_ex_pc >= 32'hc000cb64 && u_cpu.id_ex_pc <= 32'hc000cb84)))
      $display("cyc=%0d SP idexpc=%08x sp=%08x ra=%08x irqnow=%0d",
                dbg_cycle, u_cpu.id_ex_pc, u_cpu.u_rf.regs[2], u_cpu.u_rf.regs[1], u_cpu.irq_taken_now);
    if ($test$plusargs("JUMPTRACE") && dbg_cycle >= dbg_trace_start &&
        u_cpu.id_ex_valid && !u_cpu.any_stall &&
        (u_cpu.id_ex_jump || u_cpu.id_ex_jumpr || u_cpu.id_ex_is_mret || u_cpu.id_ex_is_sret ||
         (u_cpu.id_ex_branch && u_cpu.ex_target_pc != u_cpu.id_ex_pc + 32'd4)))
      $display("cyc=%0d JUMP idexpc=%08x idexjumpr=%0d idexmret=%0d idexsret=%0d idexbranch=%0d extargetpc=%08x sepc=%08x mepc=%08x",
                dbg_cycle, u_cpu.id_ex_pc, u_cpu.id_ex_jumpr, u_cpu.id_ex_is_mret, u_cpu.id_ex_is_sret,
                u_cpu.id_ex_branch, u_cpu.ex_target_pc, u_cpu.csr_sepc, u_cpu.csr_mepc);
  end

  // -----------------------------------------------------------------------
  // Memory initialisation (runs before time 0)
  // -----------------------------------------------------------------------
  initial begin : mem_init
    string  hex_file;
    integer i;
    logic [31:0] tohost_arg;

    for (i = 0; i < MEM_WORDS; i++) mem[i] = 32'b0;

    if ($value$plusargs("HEX=%s", hex_file))
      $readmemh(hex_file, mem);

    tohost_addr = TOHOST_DEF;
    if ($value$plusargs("TOHOST=%h", tohost_arg))
      tohost_addr = tohost_arg;
  end

endmodule
