<#
.SYNOPSIS
Network Diagnostics Scheduler for Windows
Runs network_diag.ps1 every 5 minutes at :00, :05, :10, ..., :55
Press Ctrl-C to stop gracefully
#>

$ErrorActionPreference = "Continue"

$ScriptDir = $PSScriptRoot
$DiagScript = Join-Path $ScriptDir "network_diag.ps1"

Write-Host "=========================================="
Write-Host "  Network Diagnostics Scheduler"
Write-Host "  Runs every 5 minutes (00, 05, 10, ...)"
Write-Host "  Press Ctrl-C to stop"
Write-Host "  Started at: $(Get-Date)"
Write-Host "=========================================="
Write-Host ""

# Run immediately on start
Write-Host ">>> [$(Get-Date -Format 'HH:mm:ss')] Running diagnostics..."
& powershell.exe -ExecutionPolicy Bypass -File $DiagScript
Write-Host ""

while ($true) {
    # Calculate seconds until the next 5-minute boundary
    $now = Get-Date
    $currentSec = $now.Second
    $currentMin = $now.Minute

    # Seconds elapsed within the current 5-minute block
    $blockElapsed = (($currentMin % 5) * 60) + $currentSec
    $blockTotal = 5 * 60

    if ($blockElapsed -eq 0) {
        $sleepSecs = $blockTotal
    } else {
        $sleepSecs = $blockTotal - $blockElapsed
    }

    $nextRun = $now.AddSeconds($sleepSecs)
    Write-Host ">>> Next run in ${sleepSecs}s (at $(Get-Date $nextRun -Format 'HH:mm:ss'))"

    Start-Sleep -Seconds $sleepSecs

    Write-Host ">>> [$(Get-Date -Format 'HH:mm:ss')] Running diagnostics..."
    & powershell.exe -ExecutionPolicy Bypass -File $DiagScript
    Write-Host ""
}
