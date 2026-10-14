/*
 * SPDX-License-Identifier: Apache-2.0
 * Copyright 2026 Eoghain Gray
 */

OUTPUT_ARCH( "riscv" )
ENTRY(_start)

/* 0x80100000 (not the default 0x80000000): matches this
 * build's PC_RESET (a cpu #(.PC_RESET(32'h8010_0000)) override),
 * moved from the default reset vector -- see the FW_TEXT_START comment in
 * the top-level Makefile for the full real-hardware reason. */
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
