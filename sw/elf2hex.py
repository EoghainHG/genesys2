#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Eoghain Gray

"""
Convert an objcopy -O verilog hex file (byte-addressed) to a word-addressed
hex file suitable for Verilog's $readmemh.

Usage:
  riscv64-unknown-elf-objcopy -O verilog test.elf test.vhex
  python3 elf2hex.py test.vhex test.hex [--base 0x80000000]

The output contains one 32-bit word per line (lowercase hex), which
$readmemh loads into a word-indexed memory array with the CPU base address
mapped to index 0.
"""

import sys
import argparse


def convert(input_path: str, output_path: str, base: int) -> None:
    byte_map: dict[int, int] = {}

    with open(input_path, "r") as f:
        current_addr = 0
        for raw in f:
            line = raw.strip()
            if not line:
                continue
            if line.startswith("@"):
                current_addr = int(line[1:], 16)
            else:
                for token in line.split():
                    byte_map[current_addr] = int(token, 16)
                    current_addr += 1

    if not byte_map:
        print("Warning: no data found in input file.", file=sys.stderr)
        return

    # Assemble bytes into little-endian 32-bit words relative to base.
    word_map: dict[int, int] = {}
    for addr, byte_val in byte_map.items():
        offset = addr - base
        if offset < 0:
            continue
        word_idx = offset >> 2
        byte_off = offset & 3
        if word_idx not in word_map:
            word_map[word_idx] = 0
        word_map[word_idx] |= byte_val << (byte_off * 8)

    if not word_map:
        print("Error: no bytes fall within the specified base address range.",
              file=sys.stderr)
        sys.exit(1)

    max_idx = max(word_map)
    with open(output_path, "w") as f:
        for i in range(max_idx + 1):
            f.write(f"{word_map.get(i, 0):08x}\n")

    print(f"Wrote {max_idx + 1} words ({(max_idx + 1) * 4} bytes) "
          f"to {output_path}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("input",  help="objcopy -O verilog hex file")
    parser.add_argument("output", help="output word-addressed hex file")
    parser.add_argument("--base", default="0x80000000",
                        help="base address of the binary (default: 0x80000000)")
    args = parser.parse_args()

    base = int(args.base, 16)
    convert(args.input, args.output, base)


if __name__ == "__main__":
    main()
