// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Eoghain Gray

// Verilator C++ driver for tb_uart_fifo -- mirrors
// sim/uart-phy-tests/uart_phy_tb.cpp's structure exactly. A 16-byte burst
// plus a full drain over real (scaled-down) UART timing needs more cycles
// than the phy-only loopback test, hence the larger MAX_CYCLES.
//
// Exit: 0 = PASS, 1 = FAIL, 2 = TIMEOUT

#include "Vtb_uart_fifo.h"
#include "verilated.h"
#include <cstdio>

static const uint64_t MAX_CYCLES = 200000ULL;

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);

    auto *top = new Vtb_uart_fifo;

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
                printf("FAIL  (%llu cycles) write_idx=%d read_idx=%d got_byte=0x%02x\n",
                       (unsigned long long)cycle, top->dbg_write_idx, top->dbg_read_idx,
                       top->dbg_got_byte);
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
        printf("dbg_state=%d dbg_write_idx=%d dbg_read_idx=%d\n",
               top->dbg_state, top->dbg_write_idx, top->dbg_read_idx);
        exit_code = 2;
    }

    delete top;
    return exit_code;
}
