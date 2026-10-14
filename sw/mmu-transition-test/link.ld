/*
 * SPDX-License-Identifier: Apache-2.0
 * Copyright 2026 Eoghain Gray
 */

OUTPUT_ARCH( "riscv" )
ENTRY(_start)

/* 0x80500000 = FW_TEXT_START (0x80100000) + FW_PAYLOAD_OFFSET (0x00400000),
   matching exactly where OpenSBI's fw_payload jumps for the real kernel
   Image (Domain0 Next Address in the boot banner) -- see Makefile's
   build-opensbi-hw target and mmu_transition_test.S's header. */

SECTIONS
{
  . = 0x80500000;
  .text.init : { *(.text.init) }
  . = ALIGN(0x1000);
  .text : { *(.text) }
  . = ALIGN(0x1000);
  .data : { *(.data) }
  .bss : { *(.bss) }
  _end = .;
}
