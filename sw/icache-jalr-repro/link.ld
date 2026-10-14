/*
 * SPDX-License-Identifier: Apache-2.0
 * Copyright 2026 Eoghain Gray
 */

OUTPUT_ARCH( "riscv" )
ENTRY(_start)

/* 0x80100000: matches this build's PC_RESET (a
 * cpu #(.PC_RESET(32'h8010_0000)) override), same base as sw/icache-flush-repro/. */
SECTIONS
{
  . = 0x80100000;
  .text.init : { *(.text.init) }
  . = ALIGN(0x1000);
  .text : { *(.text) }
  . = ALIGN(0x1000);
  .data : { *(.data) }
  .bss : { *(.bss) }
  _end = .;
}
