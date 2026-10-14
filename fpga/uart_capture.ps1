# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Eoghain Gray

# uart_capture.ps1 -- capture N seconds of raw output from the Genesys 2's
# dedicated UART port (NOT the JTAG cable's own second channel -- this board
# exposes UART and JTAG as separate physical ports, confirmed 2026-09-02)
# and write it to a log file, so a session without direct access to a
# Windows terminal can read boot/console output programmatically instead
# of needing a human to relay it.
#
# Usage (from an elevated or normal PowerShell -- no admin needed for a
# COM port the user already has permission to open):
#   .\uart_capture.ps1 -ComPort COM5 -DurationSec 15 -OutFile build\uart_capture.log
#
# Run from WSL via the same interop pattern as vivado.bat:
#   powershell.exe -NoProfile -NonInteractive -Command \
#     'Set-Location "C:\Users\Eoghain\vivado_work\genesys2"; & ".\fpga\uart_capture.ps1" -ComPort COM5 -DurationSec 15 -OutFile build\uart_capture.log'

param(
    [Parameter(Mandatory=$true)][string]$ComPort,
    [int]$BaudRate = 115200,
    [int]$DurationSec = 15,
    [Parameter(Mandatory=$true)][string]$OutFile
)

$port = New-Object System.IO.Ports.SerialPort $ComPort, $BaudRate, ([System.IO.Ports.Parity]::None), 8, ([System.IO.Ports.StopBits]::One)
$port.ReadTimeout = 250

try {
    $port.Open()
} catch {
    Write-Output "UART_CAPTURE_FAILED: could not open $ComPort -- $($_.Exception.Message)"
    exit 1
}

# Raw bytes only -- NOT $port.ReadExisting()/a string buffer. ReadExisting()
# decodes incoming bytes through the SerialPort's Encoding property, which
# defaults to ASCIIEncoding: any byte >= 0x80 silently becomes '?' (0x3F) in
# the resulting string, with no error or warning. Confirmed the hard way,
# 2026-09-02: every byte with bit 6 set (uppercase ASCII letters, 0x41-0x5A)
# came back as '?' while space/CR/LF (all < 0x40) survived intact -- looked
# exactly like a hardware bit-corruption bug at first, and would have sent
# real RTL debugging down a wrong path chasing a bug that was actually here,
# in this script, all along. A byte array + BinaryWriter round-trips every
# value 0-255 losslessly; a string ever entering the picture is exactly the
# risk this class of bug comes from.
$buf = New-Object byte[] 4096
$bytesOut = New-Object System.IO.MemoryStream
$deadline = (Get-Date).AddSeconds($DurationSec)

while ((Get-Date) -lt $deadline) {
    try {
        $n = $port.Read($buf, 0, $buf.Length)
        if ($n -gt 0) {
            $bytesOut.Write($buf, 0, $n)
        }
    } catch [System.TimeoutException] {
        # no data available in this poll window -- expected, keep waiting
    }
    Start-Sleep -Milliseconds 50
}

$port.Close()

$captured = $bytesOut.ToArray()
[System.IO.File]::WriteAllBytes($OutFile, $captured)
Write-Output "UART_CAPTURE_COMPLETE: $($captured.Length) bytes written to $OutFile"
