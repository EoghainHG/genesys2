/*
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Copyright (c) 2020 Western Digital Corporation or its affiliates.
 *
 * Authors:
 *   Anup Patel <anup.patel@wdc.com>
 */

#include <sbi_utils/fdt/fdt_helper.h>
#include <sbi_utils/serial/fdt_serial.h>
#include <sbi_utils/serial/uart8250.h>

static int serial_uart8250_init(void *fdt, int nodeoff,
				const struct fdt_match *match)
{
	int rc;
	struct platform_uart_data uart = { 0 };

	rc = fdt_parse_uart_node(fdt, nodeoff, &uart);
	if (rc)
		return rc;

	return uart8250_init(uart.addr, uart.freq, uart.baud,
			     uart.reg_shift, uart.reg_io_width,
			     uart.reg_offset);
}

static const struct fdt_match serial_uart8250_match[] = {
	{ .compatible = "ns16450" },
	{ .compatible = "ns16550" },
	{ .compatible = "ns16550a" },
	{ .compatible = "snps,dw-apb-uart" },
	{ },
};
/*
 * genesys2 local patch (2026-09-09): "ns16450" added so OpenSBI attaches a
 * console to fpga/genesys2_hw.dts's serial@10000000 (which is deliberately
 * "ns16450", not "ns16550a", to force Linux fifosize=1 -- see that DTS's
 * comment block). Without this OpenSBI has no console and console=hvc0
 * (SBI DBCN) emits nothing. uart8250.c only programs a divisor when
 * baudrate != 0 and the DTS has current-speed = <0>, so behaviour is
 * identical to a matching ns16550. Kept as a file in opensbi-patches/.
 */

struct fdt_serial fdt_serial_uart8250 = {
	.match_table = serial_uart8250_match,
	.init = serial_uart8250_init,
};
