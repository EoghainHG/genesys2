# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Eoghain Gray

# uart_send.ps1 -- send one or more commands to the Genesys 2's UART console
# and capture whatever comes back (echo + real output), raw. Sibling of
# uart_capture.ps1 (receive-only) -- built 2026-09-05 once a real interactive
# busybox shell was confirmed booted on real hardware, to actually use it
# instead of only ever watching it boot.
#
# Same raw-byte-safe discipline as uart_capture.ps1 for the READ side (see
# that script's own header: SerialPort.ReadExisting()'s default ASCIIEncoding
# silently mangles any byte >= 0x80 into '?', which looked exactly like a
# hardware bug the first time it was hit) -- a byte array + BinaryWriter-style
# MemoryStream is used here too, never a string buffer for received data.
# The WRITE side uses plain ASCII encoding, which is fine: this script only
# ever sends real shell command text, not arbitrary binary.
#
# Each command is sent followed by a bare CR (0x0D) -- Linux's tty layer
# translates CR to LF on input by default (ICRNL), matching how a real
# terminal emulator sends Enter; NOT LF alone, which more restrictive tty
# configs may not translate.
#
# Usage (from an elevated or normal PowerShell):
#   .\uart_send.ps1 -ComPort COM5 -Commands 'uname -a','free' -DurationSec 10 -OutFile build\shell.log
#
# Run from WSL via the same interop pattern as vivado.bat/uart_capture.ps1:
#   powershell.exe -NoProfile -NonInteractive -Command \
#     'Set-Location "C:\Users\Eoghain\vivado_work\genesys2"; & ".\fpga\uart_send.ps1" -ComPort COM5 -Commands "uname -a" -DurationSec 5 -OutFile build\shell.log'
#
# CharDelayMs (2026-09-05, real bug found on this script's first real-hardware
# test): sending a whole command in one SerialPort.Write() call streams every
# byte back-to-back at full baud-rate timing (~86us/byte at 115200) -- far
# faster than a human typing. rtl/bridge/uart_phy.sv's own header already
# documents its RX side has no FIFO and silently drops any byte that arrives
# before uart.sv's single-byte `rbr` holding register has been read by the
# guest -- on this ~18.75MHz core, a full interrupt-driven RX round trip in
# Linux (PLIC claim, generic IRQ framework, tty flip buffer insert, PLIC
# complete) can easily exceed that ~86us window. Confirmed live: sending
# "uname -a" in one shot echoed back only "un" -- every byte after the second
# silently vanished. A real person typing (naturally >>86us between
# keystrokes) never hits this; this script sends one byte at a time with a
# real delay between each to stay in that same safe regime, rather than
# treating this as an RTL bug to fix (uart_phy.sv's own header already calls
# this exact tradeoff out as accepted for a bring-up console).
param(
    [Parameter(Mandatory=$true)][string]$ComPort,
    [int]$BaudRate = 115200,
    [Parameter(Mandatory=$true)][string[]]$Commands,
    [int]$CharDelayMs = 15,
    [int]$SettleMs = 800,
    [int]$DurationSec = 5,
    [Parameter(Mandatory=$true)][string]$OutFile
)

$port = New-Object System.IO.Ports.SerialPort $ComPort, $BaudRate, ([System.IO.Ports.Parity]::None), 8, ([System.IO.Ports.StopBits]::One)
# ReadTimeout deliberately short (not uart_capture.ps1's 250ms): Drain-For's
# $port.Read() call blocks for up to this long when nothing is pending,
# regardless of Drain-For's own requested window -- with a 250ms value here,
# a small CharDelayMs (e.g. 15ms) was silently stretched to ~250ms per
# character in practice (harmless, just slower than requested -- confirmed
# 2026-09-05 once the real bug this uncovered turned out to be elsewhere,
# rtl/periph/uart.sv's IIR register, not send pacing).
$port.ReadTimeout = 20

try {
    $port.Open()
} catch {
    Write-Output "UART_SEND_FAILED: could not open $ComPort -- $($_.Exception.Message)"
    exit 1
}

# Well-known .NET SerialPort gotcha: writes issued immediately after Open()
# can be silently dropped before the underlying driver buffer stabilizes.
# Settle briefly and discard anything stale before sending real data.
Start-Sleep -Milliseconds 300
$port.DiscardInBuffer()
$port.DiscardOutBuffer()

$buf = New-Object byte[] 4096
$bytesOut = New-Object System.IO.MemoryStream

function Drain-For([int]$ms) {
    $deadline = (Get-Date).AddMilliseconds($ms)
    while ((Get-Date) -lt $deadline) {
        try {
            $n = $port.Read($buf, 0, $buf.Length)
            if ($n -gt 0) { $bytesOut.Write($buf, 0, $n) }
        } catch [System.TimeoutException] {
            # no data available in this poll window -- expected, keep waiting
        }
        Start-Sleep -Milliseconds 20
    }
}

foreach ($cmd in $Commands) {
    foreach ($ch in ($cmd + "`r").ToCharArray()) {
        $chBytes = [System.Text.Encoding]::ASCII.GetBytes([string]$ch)
        $port.Write($chBytes, 0, $chBytes.Length)
        Drain-For $CharDelayMs
    }
    Drain-For $SettleMs
}

Drain-For ($DurationSec * 1000)

$port.Close()

$captured = $bytesOut.ToArray()
[System.IO.File]::WriteAllBytes($OutFile, $captured)
Write-Output "UART_SEND_COMPLETE: sent $($Commands.Count) command(s), $($captured.Length) bytes captured, written to $OutFile"
