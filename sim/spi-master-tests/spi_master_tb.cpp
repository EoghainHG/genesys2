// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Eoghain Gray

// Verilator C++ driver for tb_spi_master. Drives clock/reset and reports
// pass/fail from the testbench's test_done/test_pass outputs -- mirrors
// sim/uart-phy-tests/uart_phy_tb.cpp's structure.
//
// Exit: 0 = PASS, 1 = FAIL, 2 = TIMEOUT

#include "Vtb_spi_master.h"
#include "verilated.h"
#include <cstdio>

static const uint64_t MAX_CYCLES = 20000ULL;

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);

    auto *top = new Vtb_spi_master;

    top->rst_n = 0;
    for (int i = 0; i < 8; i++) {
        top->clk = i & 1;
        top->eval();
    }
    top->rst_n = 1;

    bool     done      = false;
    int      exit_code = 2;
    uint64_t cycle     = 0;

    while (!done && cycle < MAX_CYCLES) {
        top->clk = 1;
        top->eval();

        if (top->test_done) {
            if (top->test_pass) {
                printf("PASS  (%llu cycles)\n", (unsigned long long)cycle);
                exit_code = 0;
            } else {
                printf("FAIL  (%llu cycles)\n", (unsigned long long)cycle);
                exit_code = 1;
            }
            done = true;
        }

        top->clk = 0;
        top->eval();

        ++cycle;
    }

    if (!done) {
        printf("TIMEOUT after %llu cycles\n", (unsigned long long)cycle);
        printf("dbg_step=%d\n", top->dbg_step);
        exit_code = 2;
    }

    delete top;
    return exit_code;
}
