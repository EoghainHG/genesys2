# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Eoghain Gray

###############################################################################
# Genesys 2 RISC-V SoC — simulation Makefile
###############################################################################

SHELL := bash
.PHONY: all compile run-example clean run-tests run-riscv-tests check-toolchain \
        build-priv-tests run-priv-tests build-priv-custom-tests run-priv-custom-tests \
        build-mmu-tests run-mmu-tests \
        build-clint-tests run-clint-tests build-uart-tests run-uart-tests \
        build-plic-tests run-plic-tests \
        build-opensbi run-opensbi \
        compile-axi-bridge-test run-axi-bridge-test \
        compile-spi-master-test run-spi-master-test \
        build-sd-tests run-sd-tests \
        build-sd-write-pmon \
        build-opensbi-hw \
        compile-uart-phy-test run-uart-phy-test \
        compile-uart-fifo-test run-uart-fifo-test

VERILATOR   := verilator
PYTHON      := python3
RTL_DIR     := rtl/core
PERIPH_DIR  := rtl/periph
BRIDGE_DIR  := rtl/bridge
SIM_DIR     := sim
BUILD_DIR   := build
ELF2HEX     := sw/elf2hex.py

RISCV_PREFIX ?= riscv64-unknown-elf
RISCV_GCC    := $(RISCV_PREFIX)-gcc
RISCV_OBJCOPY := $(RISCV_PREFIX)-objcopy

SIM_BIN := $(BUILD_DIR)/sim_riscv

TESTS_DIR   := riscv-tests
TESTS_URL   := https://github.com/riscv-software-src/riscv-tests.git

# RV32I test list (rv32ui-p-*)
RV32UI_TESTS := add addi and andi auipc beq bge bgeu blt bltu bne \
                jal jalr lb lbu lh lhu lui lw \
                or ori sb sh simple sll slli slt slti sltiu sltu \
                sra srai srl srli sub sw xor xori fence_i

###############################################################################
# Compile the Verilator simulation
###############################################################################

all: compile

$(BUILD_DIR):
	mkdir -p $@

compile: $(BUILD_DIR)
	$(VERILATOR) \
	  --cc --exe --build --timing \
	  -Wall -Wno-IMPORTSTAR -Wno-UNUSEDSIGNAL -Wno-BLKSEQ -Wno-fatal \
	  --top-module tb_riscv \
	  -I$(RTL_DIR) -I$(PERIPH_DIR) \
	  $(RTL_DIR)/riscv_pkg.sv \
	  $(RTL_DIR)/alu.sv \
	  $(RTL_DIR)/mul_unit.sv \
	  $(RTL_DIR)/div_unit.sv \
	  $(RTL_DIR)/regfile.sv \
	  $(RTL_DIR)/imm_gen.sv \
	  $(RTL_DIR)/control.sv \
	  $(RTL_DIR)/dcache.sv \
	  $(RTL_DIR)/icache.sv \
	  $(RTL_DIR)/cpu.sv \
	  $(PERIPH_DIR)/mmio_decoder.sv \
	  $(PERIPH_DIR)/clint.sv \
	  $(PERIPH_DIR)/plic.sv \
	  $(PERIPH_DIR)/uart.sv \
	  $(PERIPH_DIR)/spi_master.sv \
	  $(SIM_DIR)/spi-sd-tests/sd_card_model.sv \
	  $(SIM_DIR)/tb_riscv.sv \
	  $(CURDIR)/$(SIM_DIR)/riscv_tb.cpp \
	  --Mdir $(BUILD_DIR)/verilator \
	  -o ../../$(SIM_BIN)
	@echo ""
	@echo "Build complete: $(SIM_BIN)"

###############################################################################
# Phase 3 — AXI4-Lite bus-adapter directed test (no CPU, no riscv-tests
# toolchain needed — a standalone SV testbench drives the adapter's
# cache-facing side directly against a behavioral AXI4-Lite slave BFM with
# deliberately variable, multi-cycle, never-aligned AW/W latency).
###############################################################################

AXI_BRIDGE_DIR := sim/axi-bridge-tests
AXI_BRIDGE_BIN := $(BUILD_DIR)/axi_bridge_tb

compile-axi-bridge-test: $(BUILD_DIR)
	$(VERILATOR) \
	  --cc --exe --build \
	  -Wall -Wno-IMPORTSTAR -Wno-UNUSEDSIGNAL -Wno-BLKSEQ -Wno-fatal \
	  --top-module tb_axi4lite_master \
	  -I$(BRIDGE_DIR) \
	  $(BRIDGE_DIR)/axi4lite_master.sv \
	  $(AXI_BRIDGE_DIR)/axi4lite_slave_bfm.sv \
	  $(AXI_BRIDGE_DIR)/tb_axi4lite_master.sv \
	  $(CURDIR)/$(AXI_BRIDGE_DIR)/axi_tb.cpp \
	  --Mdir $(BUILD_DIR)/verilator_axi_bridge \
	  -o ../../$(AXI_BRIDGE_BIN)
	@echo ""
	@echo "Build complete: $(AXI_BRIDGE_BIN)"

run-axi-bridge-test: compile-axi-bridge-test
	@result=$$($(AXI_BRIDGE_BIN) 2>&1); \
	echo "$$result"; \
	if echo "$$result" | grep -q "^PASS"; then \
	  echo "PASS  axi4lite_master"; \
	else \
	  echo "FAIL  axi4lite_master"; \
	  exit 1; \
	fi

###############################################################################
# uart_phy.sv loopback directed test (2026-09-01, new for the Genesys 2
# port — this project's first real UART PHY, see rtl/bridge/uart_phy.sv's
# header). No CPU/uart.sv involved: uart_tx_pin is looped directly to
# uart_rx_pin in the testbench, matching real-hardware external loopback.
###############################################################################

UART_PHY_DIR := sim/uart-phy-tests
UART_PHY_BIN := $(BUILD_DIR)/uart_phy_tb

compile-uart-phy-test: $(BUILD_DIR)
	$(VERILATOR) \
	  --cc --exe --build \
	  -Wall -Wno-IMPORTSTAR -Wno-UNUSEDSIGNAL -Wno-BLKSEQ -Wno-fatal \
	  --top-module tb_uart_phy \
	  -I$(BRIDGE_DIR) \
	  $(BRIDGE_DIR)/uart_phy.sv \
	  $(UART_PHY_DIR)/tb_uart_phy.sv \
	  $(CURDIR)/$(UART_PHY_DIR)/uart_phy_tb.cpp \
	  --Mdir $(BUILD_DIR)/verilator_uart_phy \
	  -o ../../$(UART_PHY_BIN)
	@echo ""
	@echo "Build complete: $(UART_PHY_BIN)"

run-uart-phy-test: compile-uart-phy-test
	@result=$$($(UART_PHY_BIN) 2>&1); \
	echo "$$result"; \
	if echo "$$result" | grep -q "^PASS"; then \
	  echo "PASS  uart_phy"; \
	else \
	  echo "FAIL  uart_phy"; \
	  exit 1; \
	fi

###############################################################################
# uart TX/RX FIFO directed test (2026-09-12) -- the real fix for the vi/top
# interactive-console livelock. uart.sv + uart_phy.sv instantiated together,
# self-loopback, exercised with a real 16-byte back-to-back THR burst (no
# THRE polling in between -- the access pattern the old single-register
# handoff could not survive) followed by a full RBR drain, all through the
# real MMIO register boundary.
###############################################################################

UART_FIFO_DIR := sim/uart-fifo-tests
UART_FIFO_BIN := $(BUILD_DIR)/uart_fifo_tb

compile-uart-fifo-test: $(BUILD_DIR)
	$(VERILATOR) \
	  --cc --exe --build \
	  -Wall -Wno-IMPORTSTAR -Wno-UNUSEDSIGNAL -Wno-BLKSEQ -Wno-fatal \
	  --top-module tb_uart_fifo \
	  -I$(PERIPH_DIR) -I$(BRIDGE_DIR) \
	  $(PERIPH_DIR)/uart.sv \
	  $(BRIDGE_DIR)/uart_phy.sv \
	  $(UART_FIFO_DIR)/tb_uart_fifo.sv \
	  $(CURDIR)/$(UART_FIFO_DIR)/uart_fifo_tb.cpp \
	  --Mdir $(BUILD_DIR)/verilator_uart_fifo \
	  -o ../../$(UART_FIFO_BIN)
	@echo ""
	@echo "Build complete: $(UART_FIFO_BIN)"

run-uart-fifo-test: compile-uart-fifo-test
	@result=$$($(UART_FIFO_BIN) 2>&1); \
	echo "$$result"; \
	if echo "$$result" | grep -q "^PASS"; then \
	  echo "PASS  uart_fifo"; \
	else \
	  echo "FAIL  uart_fifo"; \
	  exit 1; \
	fi

###############################################################################
# spi_master.sv loopback directed test (2026-09-06, new for the Genesys 2
# SD-card-in-SPI-mode storage effort — see rtl/periph/spi_master.sv's
# header). No CPU/SD-card model involved: spi_mosi is looped directly to
# spi_miso in the testbench, matching real-hardware external loopback (same
# pattern as the uart_phy test above).
###############################################################################

SPI_MASTER_DIR := sim/spi-master-tests
SPI_MASTER_BIN := $(BUILD_DIR)/spi_master_tb

compile-spi-master-test: $(BUILD_DIR)
	$(VERILATOR) \
	  --cc --exe --build \
	  -Wall -Wno-IMPORTSTAR -Wno-UNUSEDSIGNAL -Wno-BLKSEQ -Wno-fatal \
	  --top-module tb_spi_master \
	  -I$(PERIPH_DIR) \
	  $(PERIPH_DIR)/spi_master.sv \
	  $(SPI_MASTER_DIR)/tb_spi_master.sv \
	  $(CURDIR)/$(SPI_MASTER_DIR)/spi_master_tb.cpp \
	  --Mdir $(BUILD_DIR)/verilator_spi_master \
	  -o ../../$(SPI_MASTER_BIN)
	@echo ""
	@echo "Build complete: $(SPI_MASTER_BIN)"

run-spi-master-test: compile-spi-master-test
	@result=$$($(SPI_MASTER_BIN) 2>&1); \
	echo "$$result"; \
	if echo "$$result" | grep -q "^PASS"; then \
	  echo "PASS  spi_master"; \
	else \
	  echo "FAIL  spi_master"; \
	  exit 1; \
	fi

###############################################################################
# SD-card-over-SPI init+read/write test (2026-09-06): the full CPU running a
# real bare-metal driver (sw/sd-test/sd_test.S) against spi_master.sv and a
# behavioral SD card model (sim/spi-sd-tests/sd_card_model.sv) wired into
# tb_riscv.sv, via the SIM_BIN regression binary (same convention as
# UART_TESTS/CLINT_TESTS above) rather than a dedicated small testbench --
# this one genuinely needs the full CPU, not just a directed protocol check.
###############################################################################

SD_TESTS := sd_init_read_write
SD_BUILD := $(BUILD_DIR)/sd

$(SD_BUILD): | $(BUILD_DIR)
	mkdir -p $@

build-sd-tests: check-toolchain | $(SD_BUILD)
	@for t in $(SD_TESTS); do \
	  $(RISCV_GCC) -march=$(PRIV_MARCH) -mabi=ilp32 \
	    -static -mcmodel=medany -fvisibility=hidden -nostdlib -nostartfiles \
	    -Isw/sd-test \
	    -Tsw/sd-test/link.ld sw/sd-test/$$t.S \
	    -o $(SD_BUILD)/$$t.elf || exit 1; \
	  $(RISCV_OBJCOPY) -O verilog $(SD_BUILD)/$$t.elf $(SD_BUILD)/$$t.vhex; \
	  $(PYTHON) $(ELF2HEX) $(SD_BUILD)/$$t.vhex $(SD_BUILD)/$$t.hex; \
	done
	@echo "SD tests built."

run-sd-tests: compile build-sd-tests
	@pass=0; fail=0; \
	for t in $(SD_TESTS); do \
	  hex="$(SD_BUILD)/$$t.hex"; \
	  result=$$($(SIM_BIN) +HEX=$$hex 2>&1); \
	  if echo "$$result" | grep -q "^PASS"; then \
	    echo "PASS  $$t"; \
	    pass=$$((pass+1)); \
	  else \
	    echo "FAIL  $$t : $$result"; \
	    fail=$$((fail+1)); \
	  fi; \
	done; \
	echo ""; \
	echo "Results: $$pass passed, $$fail failed"

# sd_write_pmon (2026-09-07): real-hardware-only variant of sd_init_read_write
# that also samples the onboard INA219 VCC3V3 power monitor over I2C at a
# few safe points around CMD24, to test the write-failure power-margin
# theory without an oscilloscope. Deliberately NOT added
# to SD_TESTS/run-sd-tests above -- the Verilator sim has no I2C/INA219
# model at all, so an I2C read there would just hang forever waiting for
# ACK bits nothing ever drives. Build-only target; run via JTAG-AXI on real
# hardware same as sd_init_read_write.
build-sd-write-pmon: check-toolchain | $(SD_BUILD)
	$(RISCV_GCC) -march=$(PRIV_MARCH) -mabi=ilp32 \
	  -static -mcmodel=medany -fvisibility=hidden -nostdlib -nostartfiles \
	  -Isw/sd-test \
	  -Tsw/sd-test/link.ld sw/sd-test/sd_write_pmon.S \
	  -o $(SD_BUILD)/sd_write_pmon.elf
	$(RISCV_OBJCOPY) -O verilog $(SD_BUILD)/sd_write_pmon.elf $(SD_BUILD)/sd_write_pmon.vhex
	$(PYTHON) $(ELF2HEX) $(SD_BUILD)/sd_write_pmon.vhex $(SD_BUILD)/sd_write_pmon.hex
	@echo "sd_write_pmon built (real-hardware-only, not sim-tested)."

###############################################################################
# Sanity smoke test — runs a hand-crafted hex that exercises ADDI / SW
###############################################################################

SMOKE_HEX := $(BUILD_DIR)/smoke.hex

$(SMOKE_HEX): | $(BUILD_DIR)
	@# Minimal RV32I program that writes 1 to tohost (0x80001000):
	@#   addi x1, x0, 1       # x1 = 1
	@#   lui  x2, 0x80001     # x2 = 0x80001000
	@#   sw   x1, 0(x2)       # mem[0x80001000] = 1  -> tohost = 1 -> PASS
	@#   loop: j loop
	@printf '00100093\n' >  $@   # addi x1, x0, 1
	@printf '80001137\n' >> $@   # lui  x2, 0x80001
	@printf '00112023\n' >> $@   # sw   x1, 0(x2)
	@printf 'fe9ff06f\n' >> $@   # jal  x0, -8  (infinite loop)

run-example: compile $(SMOKE_HEX)
	$(SIM_BIN) +HEX=$(SMOKE_HEX)

###############################################################################
# Python-generated RISC-V equivalent tests (no toolchain required)
###############################################################################

RISCV_TESTS_HEX := $(BUILD_DIR)/riscv_tests

$(RISCV_TESTS_HEX): | $(BUILD_DIR)
	mkdir -p $@

run-riscv-tests: compile
	@mkdir -p $(RISCV_TESTS_HEX)
	$(PYTHON) $(SIM_DIR)/gen_riscv_tests.py
	@pass=0; fail=0; \
	for hex in $(RISCV_TESTS_HEX)/*.hex; do \
	  name=$$(basename $$hex .hex); \
	  result=$$($(SIM_BIN) +HEX=$$hex 2>&1); \
	  if echo "$$result" | grep -q "^PASS"; then \
	    printf "PASS  %-30s  $$result\n" "$$name"; \
	    pass=$$((pass+1)); \
	  else \
	    printf "FAIL  %-30s  $$result\n" "$$name"; \
	    fail=$$((fail+1)); \
	  fi; \
	done; \
	echo ""; \
	echo "Results: $$pass passed, $$fail failed"; \
	[ $$fail -eq 0 ]

###############################################################################
# Full RISC-V ISA test suite (requires riscv-gnu-toolchain)
###############################################################################

check-toolchain:
	@which $(RISCV_GCC) > /dev/null 2>&1 || { \
	  echo ""; \
	  echo "ERROR: RISC-V toolchain not found ($(RISCV_GCC))."; \
	  echo ""; \
	  echo "Install options:"; \
	  echo "  Ubuntu/Debian : sudo apt install gcc-riscv64-unknown-elf"; \
	  echo "  macOS         : brew install riscv-gnu-toolchain"; \
	  echo "  From source   : https://github.com/riscv-collab/riscv-gnu-toolchain"; \
	  echo ""; \
	  exit 1; }

$(TESTS_DIR):
	git clone --recursive $(TESTS_URL) $(TESTS_DIR)

build-tests: check-toolchain $(TESTS_DIR)
	$(MAKE) -C $(TESTS_DIR)/isa \
	  XLEN=32 \
	  RISCV_PREFIX=$(RISCV_PREFIX)- \
	  $(addprefix rv32ui-p-,$(RV32UI_TESTS))
	@echo "RISC-V tests built."

HEX_DIR := $(BUILD_DIR)/hex

$(HEX_DIR): | $(BUILD_DIR)
	mkdir -p $@

gen-hex: build-tests | $(HEX_DIR)
	@for t in $(RV32UI_TESTS); do \
	  elf="$(TESTS_DIR)/isa/rv32ui-p-$$t"; \
	  if [ -f "$$elf" ]; then \
	    vhex="$(HEX_DIR)/rv32ui-p-$$t.vhex"; \
	    hex="$(HEX_DIR)/rv32ui-p-$$t.hex"; \
	    $(RISCV_OBJCOPY) -O verilog "$$elf" "$$vhex"; \
	    $(PYTHON) $(ELF2HEX) "$$vhex" "$$hex"; \
	  else \
	    echo "Warning: $$elf not found — skipping"; \
	  fi; \
	done

run-tests: compile gen-hex
	@pass=0; fail=0; skip=0; \
	for t in $(RV32UI_TESTS); do \
	  hex="$(HEX_DIR)/rv32ui-p-$$t.hex"; \
	  if [ ! -f "$$hex" ]; then \
	    echo "SKIP  rv32ui-p-$$t  (no hex file)"; \
	    skip=$$((skip+1)); \
	    continue; \
	  fi; \
	  result=$$($(SIM_BIN) +HEX=$$hex 2>&1); \
	  if echo "$$result" | grep -q "^PASS"; then \
	    echo "PASS  rv32ui-p-$$t"; \
	    pass=$$((pass+1)); \
	  else \
	    echo "FAIL  rv32ui-p-$$t : $$result"; \
	    fail=$$((fail+1)); \
	  fi; \
	done; \
	echo ""; \
	echo "Results: $$pass passed, $$fail failed, $$skip skipped"

###############################################################################
# Privileged-mode tests (rv32mi-p-*) — built directly against the vendored
# riscv-tests sources rather than delegating to riscv-tests/isa/Makefile,
# whose compile_template hardcodes -march=rv32g which fails to link against
# this toolchain's available multilibs (rv32i/rv32im/rv32ia/rv32imac only,
# no F/D). _zicsr_zifencei must be explicit — modern binutils rejects
# csrr/csrw under bare -march=rv32im.
###############################################################################

PRIV_TESTS   := scall mcsr
PRIV_MARCH   := rv32ima_zicsr_zifencei
PRIV_BUILD   := $(BUILD_DIR)/priv

$(PRIV_BUILD): | $(BUILD_DIR)
	mkdir -p $@

build-priv-tests: check-toolchain | $(PRIV_BUILD)
	@for t in $(PRIV_TESTS); do \
	  $(RISCV_GCC) -march=$(PRIV_MARCH) -mabi=ilp32 \
	    -static -mcmodel=medany -fvisibility=hidden -nostdlib -nostartfiles \
	    -I$(TESTS_DIR)/isa/rv32mi -I$(TESTS_DIR)/env/p -I$(TESTS_DIR)/isa/macros/scalar \
	    -T$(TESTS_DIR)/env/p/link.ld $(TESTS_DIR)/isa/rv32mi/$$t.S \
	    -o $(PRIV_BUILD)/rv32mi-p-$$t.elf || exit 1; \
	  $(RISCV_OBJCOPY) -O verilog $(PRIV_BUILD)/rv32mi-p-$$t.elf $(PRIV_BUILD)/rv32mi-p-$$t.vhex; \
	  $(PYTHON) $(ELF2HEX) $(PRIV_BUILD)/rv32mi-p-$$t.vhex $(PRIV_BUILD)/rv32mi-p-$$t.hex; \
	done
	@echo "Privileged-mode tests built."

run-priv-tests: compile build-priv-tests
	@pass=0; fail=0; \
	for t in $(PRIV_TESTS); do \
	  hex="$(PRIV_BUILD)/rv32mi-p-$$t.hex"; \
	  result=$$($(SIM_BIN) +HEX=$$hex 2>&1); \
	  if echo "$$result" | grep -q "^PASS"; then \
	    echo "PASS  rv32mi-p-$$t"; \
	    pass=$$((pass+1)); \
	  else \
	    echo "FAIL  rv32mi-p-$$t : $$result"; \
	    fail=$$((fail+1)); \
	  fi; \
	done; \
	echo ""; \
	echo "Results: $$pass passed, $$fail failed"

###############################################################################
# Hand-written privilege/delegation tests (sim/priv-tests/*.S)
###############################################################################

PRIV_CUSTOM_TESTS := priv_mret_transition priv_delegation_basic \
                      priv_delegation_negative priv_cause_matrix priv_wfi_noop
PRIV_CUSTOM_BUILD := $(BUILD_DIR)/priv-custom

$(PRIV_CUSTOM_BUILD): | $(BUILD_DIR)
	mkdir -p $@

build-priv-custom-tests: check-toolchain | $(PRIV_CUSTOM_BUILD)
	@for t in $(PRIV_CUSTOM_TESTS); do \
	  $(RISCV_GCC) -march=$(PRIV_MARCH) -mabi=ilp32 \
	    -static -mcmodel=medany -fvisibility=hidden -nostdlib -nostartfiles \
	    -Isim/priv-tests \
	    -Tsim/priv-tests/link.ld sim/priv-tests/$$t.S \
	    -o $(PRIV_CUSTOM_BUILD)/$$t.elf || exit 1; \
	  $(RISCV_OBJCOPY) -O verilog $(PRIV_CUSTOM_BUILD)/$$t.elf $(PRIV_CUSTOM_BUILD)/$$t.vhex; \
	  $(PYTHON) $(ELF2HEX) $(PRIV_CUSTOM_BUILD)/$$t.vhex $(PRIV_CUSTOM_BUILD)/$$t.hex; \
	done
	@echo "Custom privilege tests built."

run-priv-custom-tests: compile build-priv-custom-tests
	@pass=0; fail=0; \
	for t in $(PRIV_CUSTOM_TESTS); do \
	  hex="$(PRIV_CUSTOM_BUILD)/$$t.hex"; \
	  result=$$($(SIM_BIN) +HEX=$$hex 2>&1); \
	  if echo "$$result" | grep -q "^PASS"; then \
	    echo "PASS  $$t"; \
	    pass=$$((pass+1)); \
	  else \
	    echo "FAIL  $$t : $$result"; \
	    fail=$$((fail+1)); \
	  fi; \
	done; \
	echo ""; \
	echo "Results: $$pass passed, $$fail failed"

###############################################################################
# Hand-written Sv32 MMU tests (sim/mmu-tests/*.S)
###############################################################################

MMU_TESTS := mmu_identity_basic mmu_walk_nonidentity mmu_perm_fault \
             mmu_invalid_pte mmu_sfence_flush mmu_a_bit_fault \
             mmu_superpage_basic mmu_uart_translated_basic \
             mmu_satp_switch_highva_basic mmu_fetch_fault \
             mmu_tlb_perm_recheck
MMU_BUILD := $(BUILD_DIR)/mmu

$(MMU_BUILD): | $(BUILD_DIR)
	mkdir -p $@

build-mmu-tests: check-toolchain | $(MMU_BUILD)
	@for t in $(MMU_TESTS); do \
	  $(RISCV_GCC) -march=$(PRIV_MARCH) -mabi=ilp32 \
	    -static -mcmodel=medany -fvisibility=hidden -nostdlib -nostartfiles \
	    -Isim/mmu-tests \
	    -Tsim/mmu-tests/link.ld sim/mmu-tests/$$t.S \
	    -o $(MMU_BUILD)/$$t.elf || exit 1; \
	  $(RISCV_OBJCOPY) -O verilog $(MMU_BUILD)/$$t.elf $(MMU_BUILD)/$$t.vhex; \
	  $(PYTHON) $(ELF2HEX) $(MMU_BUILD)/$$t.vhex $(MMU_BUILD)/$$t.hex; \
	done
	@echo "MMU tests built."

run-mmu-tests: compile build-mmu-tests
	@pass=0; fail=0; \
	for t in $(MMU_TESTS); do \
	  hex="$(MMU_BUILD)/$$t.hex"; \
	  result=$$($(SIM_BIN) +HEX=$$hex 2>&1); \
	  if echo "$$result" | grep -q "^PASS"; then \
	    echo "PASS  $$t"; \
	    pass=$$((pass+1)); \
	  else \
	    echo "FAIL  $$t : $$result"; \
	    fail=$$((fail+1)); \
	  fi; \
	done; \
	echo ""; \
	echo "Results: $$pass passed, $$fail failed"

###############################################################################
# Hand-written Phase 2 CLINT tests (sim/clint-tests/*.S)
###############################################################################

CLINT_TESTS := clint_mtime_counts clint_rdtime_counts clint_mtimecmp_basic \
               clint_timer_irq_basic \
               clint_timer_irq_masked clint_timer_irq_mid_instr \
               clint_timer_irq_mid_amo clint_timer_irq_mid_lrsc \
               clint_timer_irq_lrsc_reservation \
               clint_timer_irq_mid_jal clint_timer_irq_mid_jal_icache_miss \
               clint_timer_irq_mid_jalr
CLINT_BUILD := $(BUILD_DIR)/clint

$(CLINT_BUILD): | $(BUILD_DIR)
	mkdir -p $@

build-clint-tests: check-toolchain | $(CLINT_BUILD)
	@for t in $(CLINT_TESTS); do \
	  $(RISCV_GCC) -march=$(PRIV_MARCH) -mabi=ilp32 \
	    -static -mcmodel=medany -fvisibility=hidden -nostdlib -nostartfiles \
	    -Isim/clint-tests \
	    -Tsim/clint-tests/link.ld sim/clint-tests/$$t.S \
	    -o $(CLINT_BUILD)/$$t.elf || exit 1; \
	  $(RISCV_OBJCOPY) -O verilog $(CLINT_BUILD)/$$t.elf $(CLINT_BUILD)/$$t.vhex; \
	  $(PYTHON) $(ELF2HEX) $(CLINT_BUILD)/$$t.vhex $(CLINT_BUILD)/$$t.hex; \
	done
	@echo "CLINT tests built."

run-clint-tests: compile build-clint-tests
	@pass=0; fail=0; \
	for t in $(CLINT_TESTS); do \
	  hex="$(CLINT_BUILD)/$$t.hex"; \
	  result=$$($(SIM_BIN) +HEX=$$hex 2>&1); \
	  if echo "$$result" | grep -q "^PASS"; then \
	    echo "PASS  $$t"; \
	    pass=$$((pass+1)); \
	  else \
	    echo "FAIL  $$t : $$result"; \
	    fail=$$((fail+1)); \
	  fi; \
	done; \
	echo ""; \
	echo "Results: $$pass passed, $$fail failed"

###############################################################################
# Hand-written Phase 2 UART tests (sim/uart-tests/*.S)
###############################################################################

UART_TESTS := uart_thr_lsr_basic uart_rbr_lsr_dr
UART_BUILD := $(BUILD_DIR)/uart

$(UART_BUILD): | $(BUILD_DIR)
	mkdir -p $@

build-uart-tests: check-toolchain | $(UART_BUILD)
	@for t in $(UART_TESTS); do \
	  $(RISCV_GCC) -march=$(PRIV_MARCH) -mabi=ilp32 \
	    -static -mcmodel=medany -fvisibility=hidden -nostdlib -nostartfiles \
	    -Isim/uart-tests \
	    -Tsim/uart-tests/link.ld sim/uart-tests/$$t.S \
	    -o $(UART_BUILD)/$$t.elf || exit 1; \
	  $(RISCV_OBJCOPY) -O verilog $(UART_BUILD)/$$t.elf $(UART_BUILD)/$$t.vhex; \
	  $(PYTHON) $(ELF2HEX) $(UART_BUILD)/$$t.vhex $(UART_BUILD)/$$t.hex; \
	done
	@echo "UART tests built."

run-uart-tests: compile build-uart-tests
	@pass=0; fail=0; \
	for t in $(UART_TESTS); do \
	  hex="$(UART_BUILD)/$$t.hex"; \
	  result=$$($(SIM_BIN) +HEX=$$hex 2>&1); \
	  if echo "$$result" | grep -q "^PASS"; then \
	    echo "PASS  $$t"; \
	    pass=$$((pass+1)); \
	  else \
	    echo "FAIL  $$t : $$result"; \
	    fail=$$((fail+1)); \
	  fi; \
	done; \
	echo ""; \
	echo "Results: $$pass passed, $$fail failed"

###############################################################################
# Hand-written Phase 2 PLIC tests (sim/plic-tests/*.S)
###############################################################################

PLIC_TESTS := plic_uart_rx_irq_basic plic_threshold_masking
PLIC_BUILD := $(BUILD_DIR)/plic

$(PLIC_BUILD): | $(BUILD_DIR)
	mkdir -p $@

build-plic-tests: check-toolchain | $(PLIC_BUILD)
	@for t in $(PLIC_TESTS); do \
	  $(RISCV_GCC) -march=$(PRIV_MARCH) -mabi=ilp32 \
	    -static -mcmodel=medany -fvisibility=hidden -nostdlib -nostartfiles \
	    -Isim/plic-tests \
	    -Tsim/plic-tests/link.ld sim/plic-tests/$$t.S \
	    -o $(PLIC_BUILD)/$$t.elf || exit 1; \
	  $(RISCV_OBJCOPY) -O verilog $(PLIC_BUILD)/$$t.elf $(PLIC_BUILD)/$$t.vhex; \
	  $(PYTHON) $(ELF2HEX) $(PLIC_BUILD)/$$t.vhex $(PLIC_BUILD)/$$t.hex; \
	done
	@echo "PLIC tests built."

run-plic-tests: compile build-plic-tests
	@pass=0; fail=0; \
	for t in $(PLIC_TESTS); do \
	  hex="$(PLIC_BUILD)/$$t.hex"; \
	  result=$$($(SIM_BIN) +HEX=$$hex 2>&1); \
	  if echo "$$result" | grep -q "^PASS"; then \
	    echo "PASS  $$t"; \
	    pass=$$((pass+1)); \
	  else \
	    echo "FAIL  $$t : $$result"; \
	    fail=$$((fail+1)); \
	  fi; \
	done; \
	echo ""; \
	echo "Results: $$pass passed, $$fail failed"

###############################################################################
# Phase 2.5 — OpenSBI boot-banner milestone (sim-only)
#
# Builds OpenSBI's "generic" (FDT-based) platform as a fw_payload image
# (OpenSBI + the vendored S-mode "test" payload from opensbi/firmware/
# payloads/), targeting this project's exact CLINT/PLIC/UART addresses via
# sim/opensbi/genesys2_sim.dtb. fw_jump/fw_dynamic are not usable here:
# fw_jump has nothing to jump to (no bootloader stage places anything at
# FW_JUMP_ADDR) and this core's unimplemented-opcode path is a silent NOP,
# not a trap, so it would never produce any observable signal; fw_dynamic
# expects a real previous boot stage to hand it a fw_dynamic_info struct.
#
# ISA/ABI overrides (rv32ima_zicsr_zifencei/ilp32) avoid OpenSBI's default
# rv32imafdc/ilp32d, which assumes hardware float this core doesn't have.
# FW_PAYLOAD_OFFSET/FW_PAYLOAD_FDT_ADDR are pushed well inside the 64MB sim
# RAM window (see sim/tb_riscv.sv's MEM_WORDS) instead of OpenSBI's default
# offsets, which land far outside it.
#
# FW_PAYLOAD_FDT_ADDR=0x83000000 (2026-07-16, kernel/rootfs debugging,
# found via sim +TRACE): originally 0x80600000, only 2MB past
# FW_PAYLOAD_OFFSET's payload start -- fine for the tiny ~200KB test
# payload this milestone was built for, but a real ~34MB Linux Image
# (FW_PAYLOAD_PATH override) completely overwrites that region, corrupting
# the embedded FDT. Symptom was OpenSBI's boot banner printing fine, then
# hanging forever with zero further output -- traced (not guessed) to an
# infinite loop in libfdt's fdt_next_tag/fdt_check_node_offset_, i.e.
# OpenSBI trying to parse part of the kernel's own binary data as if it
# were a device tree. Moved well past any payload this project is likely
# to embed for a long time.
#
# Pass/fail is judged by grepping stdout for OpenSBI's own banner text and
# the test payload's own print, not by sim_riscv's exit code: OpenSBI has no
# concept of the riscv-tests tohost mechanism, and the test payload
# wfi-loops forever after printing (a no-op today per Phase 2's deferred WFI
# semantics), so every successful run ends in sim/riscv_tb.cpp's MAX_CYCLES
# TIMEOUT — that is the expected outcome, not a failure.
###############################################################################

OPENSBI_DIR   := opensbi
OPENSBI_ELF   := $(OPENSBI_DIR)/build/platform/generic/firmware/fw_payload.elf
OPENSBI_DTB   := $(SIM_DIR)/opensbi/genesys2_sim.dtb
OPENSBI_BUILD := $(BUILD_DIR)/opensbi
OPENSBI_VHEX  := $(OPENSBI_BUILD)/fw_payload.vhex
OPENSBI_HEX   := $(OPENSBI_BUILD)/fw_payload.hex

$(OPENSBI_BUILD): | $(BUILD_DIR)
	mkdir -p $@

# FW_PAYLOAD_PATH (2026-07-16, kernel/rootfs debugging): same optional
# passthrough as build-opensbi-hw -- empty by default (OpenSBI's own
# vendored test.elf smoke-test payload, preserving the existing
# run-opensbi regression check), or point at a Linux Image to sim-boot the
# real kernel for full +TRACE visibility instead of guessing on real
# hardware. sim/tb_riscv.sv's MEM_WORDS/sim/opensbi/genesys2_sim.dts's
# memory node were both grown to 64MB the same day for this reason.
FW_PAYLOAD_PATH ?=

build-opensbi: check-toolchain | $(OPENSBI_BUILD)
	$(MAKE) -C $(OPENSBI_DIR) PLATFORM=generic \
	  CROSS_COMPILE=$(RISCV_PREFIX)- \
	  PLATFORM_RISCV_XLEN=32 \
	  PLATFORM_RISCV_ISA=rv32ima_zicsr_zifencei \
	  PLATFORM_RISCV_ABI=ilp32 \
	  FW_PAYLOAD_OFFSET=0x00400000 \
	  FW_PAYLOAD_FDT_ADDR=0x83000000 \
	  FW_FDT_PATH=$(CURDIR)/$(OPENSBI_DTB) \
	  $(if $(FW_PAYLOAD_PATH),FW_PAYLOAD_PATH=$(FW_PAYLOAD_PATH))
	$(RISCV_OBJCOPY) -O verilog $(OPENSBI_ELF) $(OPENSBI_VHEX)
	$(PYTHON) $(ELF2HEX) $(OPENSBI_VHEX) $(OPENSBI_HEX)

run-opensbi: compile build-opensbi
	@result=$$($(SIM_BIN) +HEX=$(OPENSBI_HEX) 2>&1); \
	echo "$$result"; \
	if echo "$$result" | grep -q "OpenSBI" && echo "$$result" | grep -q "Test payload running"; then \
	  echo ""; \
	  echo "PASS  OpenSBI boot banner + S-mode test payload both observed"; \
	else \
	  echo ""; \
	  echo "FAIL  expected banner text not found in sim output"; \
	  exit 1; \
	fi

###############################################################################
# Phase 4 — OpenSBI build for real hardware (JTAG-loaded via
# load_ddr_program_burst.tcl, not sim +HEX= -- this board has no
# PS/ARM debug port at all)
#
# Same OpenSBI source/payload pipeline as build-opensbi above, targeting
# this project's own fpga/genesys2_hw.dts (1GB real DDR3, real
# 18,753,922Hz clk_core timebase) instead of the sim one, and producing
# the SAME .vhex/elf2hex.py-derived word-per-line .hex format that
# fpga/load_ddr_program_burst.tcl consumes -- NOT a raw objcopy -O binary.
###############################################################################

OPENSBI_HW_ELF   := $(OPENSBI_DIR)/build/platform/generic/firmware/fw_payload.elf
OPENSBI_HW_DTS   := fpga/genesys2_hw.dts
OPENSBI_HW_BUILD := $(BUILD_DIR)/opensbi-hw
OPENSBI_HW_DTB   := $(OPENSBI_HW_BUILD)/genesys2_hw.dtb
OPENSBI_HW_VHEX  := $(OPENSBI_HW_BUILD)/fw_payload.vhex
OPENSBI_HW_HEX   := $(OPENSBI_HW_BUILD)/fw_payload.hex

$(OPENSBI_HW_BUILD): | $(BUILD_DIR)
	mkdir -p $@

$(OPENSBI_HW_DTB): $(OPENSBI_HW_DTS) | $(OPENSBI_HW_BUILD)
	dtc -I dts -O dtb -o $@ $<

# FW_TEXT_START=0x80000000 (unchanged default): genesys2's real,
# unmodified PC_RESET (fpga/genesys2_top_ddr.sv) -- no OCM exists on this
# board, so no FW_TEXT_START shift/offset workaround is needed here.
#
# FW_PAYLOAD=y + FW_PAYLOAD_OFFSET=0x00400000 -> absolute kernel-embed
# address 0x80400000 = 0x201 * 0x400000 exactly -- ALREADY 4MB-aligned,
# satisfying the Sv32 trampoline_pg_dir unconditional-4MB-superpage
# constraint (misalignment here would silently corrupt the kernel mapping
# rather than faulting on this core family -- zero console output,
# indistinguishable from a hardware hang). FW_PAYLOAD=y is REQUIRED:
# without it, objects.mk's
# `firmware-genflags-$(FW_PAYLOAD)` expands empty and every FW_PAYLOAD_*
# override below is silently ignored.
#
# FW_PAYLOAD_FDT_ADDR=0x80A00000 (10MiB from FW_TEXT_START): the current
# kernel Image (~/linux-riscv/build-rv32-min/arch/riscv/boot/Image,
# 3,768,332 bytes as of 2026-09-03) ends at 0x8079800C, leaving 2.406MiB
# of margin before this address -- enough for the kernel to grow to
# ~6.0MB before risking an oversized kernel Image silently overwriting
# an FDT placed too close, hanging
# OpenSBI in an infinite libfdt parse loop with zero console output
# (looks identical to a hardware hang from the outside).
#
# CORRECTED 2026-09-03 (built for real and inspected the resulting ELF):
# this address does NOT affect the size of the .hex file this project's
# JTAG-AXI loader has to transfer -- the FDT is compiled into a small
# `.rodata` blob (`fw_fdt_bin`) near the image's own start, and OpenSBI's
# own startup code copies it to FW_PAYLOAD_FDT_ADDR at BOOT TIME on real
# hardware, after this whole image is already loaded. The real loaded
# payload is only as large as OpenSBI+kernel actually are (confirmed:
# 1,990,662 words / ~7.96MB as built today), independent of how far past
# that FW_PAYLOAD_FDT_ADDR is placed. So the margin chosen here is purely
# about runtime safety (this address must not collide with anything
# Linux itself uses early in boot), not a load-time cost tradeoff -- an
# earlier draft of this comment claimed the latter; it was wrong. If the
# kernel Image is ever rebuilt larger than ~6.0MB, recompute this address
# before reusing this recipe -- don't just bump it blindly.
#
# FW_PAYLOAD_PATH_HW (NOT the same variable as build-opensbi's own
# FW_PAYLOAD_PATH above -- see why below) defaults to the confirmed-good
# tinyconfig kernel Image, which already has busybox baked in via
# CONFIG_INITRAMFS_SOURCE (no separate rootfs step needed -- shared,
# architecture-generic artifact, not project-specific). Use build-rv32-min,
# NOT build-rv32 (no -min suffix) -- that's a stale, oversized pre-fix
# tree.
#
# REAL BUG CAUGHT WHILE WRITING THIS TARGET: build-opensbi above already
# does `FW_PAYLOAD_PATH ?=` earlier in this file. GNU Make's ?= only
# assigns when a variable has NEVER been assigned anywhere in the
# Makefile -- reusing that same variable name here would make THIS
# target's own default silently inert (already "defined" as empty by the
# earlier line), embedding OpenSBI's own vendored test.elf smoke payload
# instead of Linux with zero warning, discovered only after a wasted
# ~60-75 minute load cycle. Using a distinctly-named variable instead.
FW_PAYLOAD_PATH_HW ?= $(HOME)/linux-riscv/build-rv32-min/arch/riscv/boot/Image

build-opensbi-hw: check-toolchain $(OPENSBI_HW_DTB) | $(OPENSBI_HW_BUILD)
	@test -f "$(FW_PAYLOAD_PATH_HW)" || { \
	  echo "ERROR: kernel Image not found at $(FW_PAYLOAD_PATH_HW)"; \
	  echo "  Rebuild it (see ~/linux-riscv build instructions) or override:"; \
	  echo "  make build-opensbi-hw FW_PAYLOAD_PATH_HW=/path/to/Image"; \
	  exit 1; }
	# distclean first: this target and the sim build-opensbi target above
	# share the same opensbi/build output directory but use different
	# FW_TEXT_START/FW_PAYLOAD_OFFSET/FW_FDT_PATH/FW_PAYLOAD_PATH values.
	# OpenSBI's own kbuild change-tracking normally handles this fine, but
	# for this project's FIRST real hardware Linux attempt, remove all
	# doubt for the cost of a sub-minute rebuild rather than debug a
	# stale-object theory after a 60-75 minute load comes back wrong.
	$(MAKE) -C $(OPENSBI_DIR) distclean
	$(MAKE) -C $(OPENSBI_DIR) PLATFORM=generic \
	  CROSS_COMPILE=$(RISCV_PREFIX)- \
	  PLATFORM_RISCV_XLEN=32 \
	  PLATFORM_RISCV_ISA=rv32ima_zicsr_zifencei \
	  PLATFORM_RISCV_ABI=ilp32 \
	  FW_TEXT_START=0x80000000 \
	  FW_PAYLOAD=y \
	  FW_PAYLOAD_OFFSET=0x00400000 \
	  FW_PAYLOAD_ALIGN=0x00400000 \
	  FW_PAYLOAD_FDT_ADDR=0x80A00000 \
	  FW_FDT_PATH=$(CURDIR)/$(OPENSBI_HW_DTB) \
	  FW_PAYLOAD_PATH=$(FW_PAYLOAD_PATH_HW)
	$(RISCV_OBJCOPY) -O verilog $(OPENSBI_HW_ELF) $(OPENSBI_HW_VHEX)
	$(PYTHON) $(ELF2HEX) $(OPENSBI_HW_VHEX) $(OPENSBI_HW_HEX) --base 0x80000000
	@echo ""
	@echo "Build complete: $(OPENSBI_HW_HEX)"
	@echo "Load via: vivado -mode batch -source fpga/load_ddr_program_burst.tcl \\"
	@echo "  -tclargs $(OPENSBI_HW_HEX) 256 -log build/ddr_load_opensbi.log -journal build/ddr_load_opensbi.jou"

###############################################################################
# Clean
###############################################################################

clean:
	rm -rf $(BUILD_DIR)
