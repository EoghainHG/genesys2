// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Eoghain Gray

// Verilator C++ driver for the RISC-V simulation testbench.
// Drives clock and reset, monitors tohost, and reports pass/fail.
//
// Usage:  ./build/sim_riscv +HEX=<test.hex> [+TOHOST=<hex_addr>] [+MAXCYCLES=<n>]
// Exit:   0 = PASS,  1 = FAIL,  2 = TIMEOUT

#include "Vtb_riscv.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <unistd.h>
#include <sys/select.h>

static const uint64_t MAX_CYCLES_DEFAULT = 10000000ULL;

// stdin_byte_ready() (2026-07-22): non-blocking check for a pending byte on
// the host's own stdin, used only when +STDIN_UART is passed (see below) —
// feeds scripted (piped) or interactive keyboard input into the simulated
// UART's RX path, so the sim-boot-to-shell milestone can actually be
// exercised (run a command, see its output) rather than just observed once
// at the `/ #` prompt. Zero-timeout select(), so it never blocks the sim
// loop waiting for input that may never come.
static bool stdin_byte_ready() {
    fd_set fds;
    FD_ZERO(&fds);
    FD_SET(STDIN_FILENO, &fds);
    struct timeval tv = {0, 0};
    return select(STDIN_FILENO + 1, &fds, nullptr, nullptr, &tv) > 0;
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);

    uint64_t max_cycles = MAX_CYCLES_DEFAULT;
    const char *maxcycles_match = Verilated::commandArgsPlusMatch("MAXCYCLES=");
    if (maxcycles_match && maxcycles_match[0] != '\0') {
        std::string arg(maxcycles_match);
        max_cycles = strtoull(arg.substr(strlen("+MAXCYCLES=")).c_str(), nullptr, 0);
    }

    // +STDIN_UART (2026-07-22): opt-in only -- existing regression/test
    // invocations never pass this, so stdin is never touched unless
    // explicitly requested. See stdin_byte_ready()'s own comment above.
    bool stdin_uart = Verilated::commandArgsPlusMatch("STDIN_UART") != nullptr;

    auto *top = new Vtb_riscv;
    top->host_rx_valid = 0;
    top->host_rx_data  = 0;

    // -- Reset sequence: hold rst_n low for 4 clock cycles -----------------
    top->rst_n = 0;
    for (int i = 0; i < 8; i++) {          // 4 full cycles = 8 half-cycles
        top->clk = i & 1;
        top->eval();
    }
    top->rst_n = 1;

    // -- Main simulation loop ----------------------------------------------
    bool     done        = false;
    int      exit_code   = 2;              // default: TIMEOUT
    uint64_t cycle       = 0;

    // stdin_check_interval (2026-07-22): a select() syscall every single
    // cycle turned out to be catastrophically slow (confirmed: a 200M-cycle
    // boot that normally completes in well under a minute made almost no
    // progress after over a minute of CPU time with +STDIN_UART checking
    // every cycle). 1000 cycles is a tiny fraction of a second of simulated
    // device time even at a modest clock rate -- far below any human typing
    // or piped-script latency that would actually matter -- while cutting
    // the syscall count by 1000x.
    static const uint64_t STDIN_CHECK_INTERVAL = 1000;

    while (!done && cycle < max_cycles) {
        // +STDIN_UART: check for a pending host byte before the rising edge,
        // so tb_riscv.sv's registered rx_inject logic samples it this same
        // edge. See stdin_byte_ready()'s own comment above.
        //
        // host_rx_ready gating (2026-07-22): the UART's rbr is a single-byte
        // holding register, no FIFO -- injecting a new byte before the guest
        // has read the previous one silently overwrites it. Confirmed via a
        // real scripted test: "echo HELLO_FROM_SIM_SHELL" arrived at the
        // shell as "eho_FROM_SIM_HELL" without this check. select() only
        // *peeks* readiness, so it's safe to defer the actual read() until
        // the guest signals ready -- no host-side data is lost by waiting.
        if (stdin_uart && top->host_rx_ready &&
            (cycle % STDIN_CHECK_INTERVAL) == 0 && stdin_byte_ready()) {
            unsigned char c;
            if (read(STDIN_FILENO, &c, 1) == 1) {
                top->host_rx_valid = 1;
                top->host_rx_data  = c;
            } else {
                top->host_rx_valid = 0;
            }
        } else {
            top->host_rx_valid = 0;
        }

        // Rising edge
        top->clk = 1;
        top->eval();

        // Sample UART TX immediately after rising edge — console visibility
        // for THR writes (de-risks the later OpenSBI boot-banner milestone).
        if (top->uart_tx_valid) {
            int ch = static_cast<int>(top->uart_tx_data);
            putchar(ch);
            fflush(stdout);
            if (ch == '\n')
                fprintf(stderr, "[uart-nl cycle %llu]\n",
                        (unsigned long long)cycle);
        }
        // Coarse progress heartbeat to stderr (diagnostic; harmless).
        if ((cycle % 5000000ULL) == 0ULL)
            fprintf(stderr, "[progress cycle %llu]\n",
                    (unsigned long long)cycle);

        // Sample tohost immediately after rising edge
        if (top->tohost_valid) {
            uint32_t val = top->tohost_data;
            if (val == 1u) {
                printf("\nPASS  (%llu cycles)\n", (unsigned long long)cycle);
                exit_code = 0;
            } else {
                printf("\nFAIL  test=%u  tohost=0x%08x  (%llu cycles)\n",
                       val >> 1, val, (unsigned long long)cycle);
                exit_code = 1;
            }
            done = true;
        }

        // Falling edge
        top->clk = 0;
        top->eval();

        ++cycle;
    }

    if (!done) {
        printf("TIMEOUT after %llu cycles\n", (unsigned long long)cycle);
        exit_code = 2;
    }

    delete top;
    return exit_code;
}
