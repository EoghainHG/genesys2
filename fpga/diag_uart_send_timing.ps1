# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Eoghain Gray

# One-shot diagnostic (2026-09-05): fpga/uart_send.ps1's first real tests
# gave inconsistent results (2 bytes echoed once, 0 bytes on repeats) sending
# short commands into the already-booted busybox shell. Rather than keep
# guessing blindly, this prints a real time series of $port.BytesToRead
# alongside each write, so a late-arriving vs genuinely-dropped byte can be
# told apart directly instead of inferred from a single pass/fail count.
param(
    [Parameter(Mandatory=$true)][string]$ComPort,
    [int]$BaudRate = 115200,
    [Parameter(Mandatory=$true)][string]$Command
)

$port = New-Object System.IO.Ports.SerialPort $ComPort, $BaudRate, ([System.IO.Ports.Parity]::None), 8, ([System.IO.Ports.StopBits]::One)
$port.ReadTimeout = 100
try { $port.Open() } catch { Write-Output "OPEN_FAILED: $($_.Exception.Message)"; exit 1 }
Write-Output "OPENED: IsOpen=$($port.IsOpen) BaudRate=$($port.BaudRate)"

Start-Sleep -Milliseconds 300
Write-Output "PRE-DISCARD BytesToRead=$($port.BytesToRead)"
$port.DiscardInBuffer()
$port.DiscardOutBuffer()
Write-Output "POST-DISCARD BytesToRead=$($port.BytesToRead)"

$bytesOut = New-Object System.IO.MemoryStream
$buf = New-Object byte[] 4096

$full = $Command + "`r"
foreach ($ch in $full.ToCharArray()) {
    $b = [System.Text.Encoding]::ASCII.GetBytes([string]$ch)
    $port.Write($b, 0, $b.Length)
    Write-Output "WROTE '$ch' (0x$('{0:X2}' -f [byte]$b[0])) BytesToRead=$($port.BytesToRead)"
}

for ($i = 0; $i -lt 40; $i++) {
    Start-Sleep -Milliseconds 250
    $n = $port.BytesToRead
    if ($n -gt 0) {
        $got = New-Object byte[] $n
        $port.Read($got, 0, $n) | Out-Null
        $bytesOut.Write($got, 0, $n)
        $hex = ($got | ForEach-Object { '{0:X2}' -f $_ }) -join ' '
        Write-Output "[$($i*250)ms] +$n bytes: $hex"
    }
}

$port.Close()
$all = $bytesOut.ToArray()
Write-Output "TOTAL_CAPTURED: $($all.Length) bytes"
$allHex = ($all | ForEach-Object { '{0:X2}' -f $_ }) -join ' '
Write-Output "ALL_HEX: $allHex"
