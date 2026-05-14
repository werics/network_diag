<#
.SYNOPSIS
Network Diagnostics Script for Windows
Collects Wi-Fi info, IP info, ping quality, and traceroute data.
All ping and traceroute tests run in parallel to reduce total test time.

.REQUIREMENTS
Windows 10/11 with PowerShell 5.1+
#>

$ErrorActionPreference = "Continue"

# --- Configuration ---
$ScriptDir = $PSScriptRoot
$LogBaseDir = Join-Path $ScriptDir "logs"
$PingCount = 100
$PingTimeoutMs = 2000
$TracertMaxHops = 30
$TracertTimeoutMs = 2000

# --- Timestamp ---
$Timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$DateDir = Get-Date -Format "yyyyMMdd"
$RunDir = Join-Path $LogBaseDir $DateDir
New-Item -ItemType Directory -Force -Path $RunDir | Out-Null

$OutputFile = Join-Path $RunDir "$Timestamp.txt"
$SummaryCsv = Join-Path $LogBaseDir "summary.csv"

# Temp directory for parallel task outputs
$TempDir = Join-Path ([System.IO.Path]::GetTempPath()) "network_diag_$([System.Guid]::NewGuid().ToString('N').Substring(0,8))"
New-Item -ItemType Directory -Force -Path $TempDir | Out-Null

# --- Load Targets ---
$TargetsFile = Join-Path $ScriptDir "targets.txt"
$Targets = @()
if (Test-Path $TargetsFile) {
    Get-Content $TargetsFile | ForEach-Object {
        $line = $_ -replace '#.*$', ''       # remove comments
        $line = $line.Trim()                  # trim whitespace
        if ($line) { $Targets += $line }
    }
}
if ($Targets.Count -eq 0) {
    Write-Error "ERROR: No targets found in $TargetsFile"
    exit 1
}

# --- Helper: Log to both console and output file ---
function Write-Log {
    param([string]$Message)
    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Message"
    Write-Host $line
    Add-Content -Path $OutputFile -Value $line
}

# --- Helper: Jitter calculation (mean absolute deviation of consecutive RTTs) ---
function Get-Jitter {
    param([double[]]$Times)
    if ($Times.Count -lt 2) { return 0.0 }
    $sumDiff = 0.0
    for ($i = 1; $i -lt $Times.Count; $i++) {
        $diff = $Times[$i] - $Times[$i-1]
        if ($diff -lt 0) { $diff = -$diff }
        $sumDiff += $diff
    }
    return [math]::Round($sumDiff / ($Times.Count - 1), 3)
}

# --- Helper: Standard deviation calculation ---
function Get-StdDev {
    param([double[]]$Values)
    if ($Values.Count -lt 2) { return 0.0 }
    $avg = ($Values | Measure-Object -Average).Average
    $sumSq = 0.0
    foreach ($v in $Values) {
        $sumSq += [math]::Pow($v - $avg, 2)
    }
    return [math]::Round([math]::Sqrt($sumSq / ($Values.Count - 1)), 3)
}

# --- Helper: Parse ping output ---
function Parse-PingOutput {
    param(
        [string]$TempFile,
        [string]$TargetLabel
    )
    if (-not (Test-Path $TempFile)) {
        Write-Log "ERROR: No ping output file for $TargetLabel"
        return @{ Tx = 0; Rx = 0; Loss = 100; Min = $null; Avg = $null; Max = $null; StdDev = $null; Jitter = $null }
    }

    $raw = Get-Content $TempFile -Raw
    if (-not $raw) {
        Write-Log "ERROR: Empty ping output for $TargetLabel"
        return @{ Tx = 0; Rx = 0; Loss = 100; Min = $null; Avg = $null; Max = $null; StdDev = $null; Jitter = $null }
    }

    # Extract individual RTT values from lines like "time=15ms" or "time<1ms"
    $rttTimes = [double[]]@()
    $lines = $raw -split "`r`n|`n"
    foreach ($l in $lines) {
        if ($l -match 'time[=<]\s*(\d+)\s*ms') {
            $rttTimes += [double]$Matches[1]
        } elseif ($l -match 'time<1ms') {
            $rttTimes += 0.5
        }
    }

    # Parse summary statistics
    # "Packets: Sent = 100, Received = 100, Lost = 0 (0% loss),"
    $tx = 0; $rx = 0; $loss = 100.0
    if ($raw -match 'Packets:\s*Sent\s*=\s*(\d+).*?Received\s*=\s*(\d+).*?Lost\s*=\s*(\d+)\s*\((\d+)%') {
        $tx = [int]$Matches[1]
        $rx = [int]$Matches[2]
        $loss = [double]$Matches[4]
    }

    # "Minimum = 13ms, Maximum = 408ms, Average = 22ms"
    $min = $null; $max = $null; $avg = $null
    if ($raw -match 'Minimum\s*=\s*(\d+)\s*ms.*?Maximum\s*=\s*(\d+)\s*ms.*?Average\s*=\s*(\d+)\s*ms') {
        $min = [double]$Matches[1]
        $max = [double]$Matches[2]
        $avg = [double]$Matches[3]
    }

    # Calculate jitter and stddev from individual RTT values
    $jitter = Get-Jitter -Times $rttTimes
    $stddev = Get-StdDev -Values $rttTimes

    $result = @{
        Tx     = $tx
        Rx     = $rx
        Loss   = $loss
        Min    = $min
        Avg    = $avg
        Max    = $max
        StdDev = $stddev
        Jitter = $jitter
    }

    Write-Log ""
    Write-Log "========== Ping: $TargetLabel =========="
    Write-Log "Sent      : $($result.Tx)"
    Write-Log "Received  : $($result.Rx)"
    Write-Log "Loss      : $($result.Loss)%"
    Write-Log "RTT Min   : $(if($result.Min){$result.Min}else{'N/A'}) ms"
    Write-Log "RTT Avg   : $(if($result.Avg){$result.Avg}else{'N/A'}) ms"
    Write-Log "RTT Max   : $(if($result.Max){$result.Max}else{'N/A'}) ms"
    Write-Log "RTT StdDev: $(if($result.StdDev){$result.StdDev}else{'N/A'}) ms"
    Write-Log "Jitter    : $($result.Jitter) ms"

    return $result
}

# --- Helper: Safe CSV field (replace commas with underscores) ---
function Format-CsvField {
    param([string]$Value)
    if (-not $Value -or $Value -eq '') { return 'N/A' }
    return $Value.Replace(',', '_')
}

# --- Helper: Format number or N/A ---
function Format-NumOrNA {
    param($Value)
    if ($null -eq $Value -or $Value -eq '') { return 'N/A' }
    return [string]$Value
}

# =====================================================================
# PHASE 1: Sequential collection (Wi-Fi + IP)
# =====================================================================

# --- Wi-Fi Information ---
Write-Log "========== Wi-Fi Information =========="

$WifiSSID = "N/A"
$WifiBSSID = "N/A"
$WifiRSSI = "N/A"
$WifiNoise = "N/A"
$WifiChannel = "N/A"
$WifiTxRate = "N/A"
$WifiPhyMode = "N/A"

# Try netsh wlan show interfaces
$wlanOut = netsh wlan show interfaces 2>$null | Out-String
if ($wlanOut -match 'SSID\s*:\s*(.+)') {
    $WifiSSID = $Matches[1].Trim()
}
if ($wlanOut -match 'BSSID\s*:\s*(.+)') {
    $WifiBSSID = $Matches[1].Trim()
}
if ($wlanOut -match 'Signal\s*:\s*(\d+)%') {
    $signalPct = [int]$Matches[1]
    # Approximate conversion: RSSI ≈ (signal% × 0.7) - 100
    $WifiRSSI = [string][math]::Round($signalPct * 0.7 - 100)
}
if ($wlanOut -match 'Channel\s*:\s*(\d+)') {
    $WifiChannel = $Matches[1].Trim()
}
if ($wlanOut -match 'Transmit rate \(Mbps\)\s*:\s*(\d+)') {
    $WifiTxRate = $Matches[1].Trim()
}
if ($wlanOut -match 'Radio type\s*:\s*(.+)') {
    $radioType = $Matches[1].Trim()
    # Normalize: 802.11ac, 802.11n, 802.11ax, etc.
    $WifiPhyMode = $radioType
}
if ($wlanOut -match 'Receive rate \(Mbps\)\s*:\s*(\d+)') {
    # Use receive rate as Tx rate if Tx rate not found
    if ($WifiTxRate -eq "N/A") {
        $WifiTxRate = $Matches[1].Trim()
    }
}

Write-Log "SSID      : $WifiSSID"
Write-Log "BSSID     : $WifiBSSID"
Write-Log "RSSI      : $WifiRSSI dBm"
Write-Log "Noise     : $WifiNoise dBm"
Write-Log "Channel   : $WifiChannel"
Write-Log "Tx Rate   : $WifiTxRate Mbps"
Write-Log "PHY Mode  : $WifiPhyMode"

# --- IP / Gateway / MAC Information ---
Write-Log ""
Write-Log "========== IP Information =========="

$WifiIface = "N/A"
$IPAddr = "N/A"
$Netmask = "N/A"
$Gateway = "N/A"
$MacAddr = "N/A"

# Detect Wi-Fi adapter
$wifiAdapter = Get-NetAdapter -Physical -ErrorAction SilentlyContinue |
    Where-Object { $_.MediaType -eq 'Native 802.11' -or $_.Name -like '*Wi-Fi*' -or $_.Name -like '*Wireless*' } |
    Select-Object -First 1

if ($wifiAdapter) {
    $WifiIface = $wifiAdapter.Name
    $MacAddr = $wifiAdapter.MacAddress

    # Get IP and netmask
    $ipConfig = Get-NetIPAddress -InterfaceIndex $wifiAdapter.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($ipConfig) {
        $IPAddr = $ipConfig.IPAddress
        $Netmask = "0x$([Convert]::ToString([Convert]::ToInt64($ipConfig.PrefixLength), 16).PadLeft(8, '0'))"
    }

    # Get gateway
    $route = Get-NetRoute -InterfaceIndex $wifiAdapter.InterfaceIndex -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($route) {
        $Gateway = $route.NextHop
    }
} else {
    # Fallback: try ipconfig parsing
    Write-Log "NOTE: No Wi-Fi adapter detected via Get-NetAdapter, trying ipconfig fallback..."
    $ipconfigOut = ipconfig 2>$null | Out-String

    # Try to find Wi-Fi or Wireless adapter section
    $sections = $ipconfigOut -split "`r`n`r`n"
    foreach ($section in $sections) {
        if ($section -match 'Wireless|Wi-Fi|WLAN') {
            if ($section -match 'IPv4 Address[.\s]*:\s*([\d.]+)') {
                $IPAddr = $Matches[1].Trim()
            }
            if ($section -match 'Subnet Mask[.\s]*:\s*([\d.]+)') {
                $mask = $Matches[1].Trim()
                $octets = $mask -split '\.'
                $hex = ''
                foreach ($o in $octets) { $hex += ([Convert]::ToString([int]$o, 16).PadLeft(2, '0')) }
                $Netmask = "0x$hex"
            }
            if ($section -match 'Default Gateway[.\s]*:\s*([\d.]+)') {
                $Gateway = $Matches[1].Trim()
            }
            if ($section -match 'Physical Address[.\s]*:\s*([\dA-Fa-f-]+)') {
                $MacAddr = ($Matches[1].Trim() -replace '-', ':').ToLower()
            }
            break
        }
    }
}

Write-Log "Interface : $WifiIface"
Write-Log "IP Addr   : $IPAddr"
Write-Log "Netmask   : $Netmask"
Write-Log "Gateway   : $Gateway"
Write-Log "MAC Addr  : $MacAddr"

# =====================================================================
# PHASE 2: Launch parallel tests
# =====================================================================

Write-Log ""
Write-Log "========== Launching Parallel Tests =========="
Write-Log "Starting $(Get-Date -Format 'HH:mm:ss'): ping (gateway + $($Targets.Count) targets) + $($Targets.Count) traceroutes + public IP"

$Jobs = @()

# Gateway ping
if ($Gateway -and $Gateway -ne "N/A") {
    $gwFile = Join-Path $TempDir "ping_gateway.out"
    $Jobs += Start-Job -Name "PingGateway" -ArgumentList $Gateway, $PingCount, $PingTimeoutMs, $gwFile -ScriptBlock {
        param($gw, $cnt, $timeout, $outFile)
        & ping -n $cnt -w $timeout $gw 2>&1 | Out-File -FilePath $outFile -Encoding utf8
    }
    $PingGwLabel = "Gateway"
    $PingGwTarget = $Gateway
} else {
    "SKIP:no_gateway" | Out-File -FilePath (Join-Path $TempDir "ping_gateway.out") -Encoding utf8
    $PingGwLabel = "Gateway"
    $PingGwTarget = $Gateway
}

# Target pings
$TargetPingFiles = @()
foreach ($target in $Targets) {
    $safeName = $target -replace '[^a-zA-Z0-9_\-]', '_'
    $outFile = Join-Path $TempDir "ping_${safeName}.out"
    $TargetPingFiles += @{ Target = $target; File = $outFile }
    $Jobs += Start-Job -Name "Ping_$safeName" -ArgumentList $target, $PingCount, $PingTimeoutMs, $outFile -ScriptBlock {
        param($t, $cnt, $timeout, $outFile)
        & ping -n $cnt -w $timeout $t 2>&1 | Out-File -FilePath $outFile -Encoding utf8
    }
}

# Target traceroutes
$TargetTraceFiles = @()
foreach ($target in $Targets) {
    $safeName = $target -replace '[^a-zA-Z0-9_\-]', '_'
    $outFile = Join-Path $TempDir "tr_${safeName}.out"
    $TargetTraceFiles += @{ Target = $target; File = $outFile }
    $Jobs += Start-Job -Name "Trace_$safeName" -ArgumentList $target, $TracertMaxHops, $TracertTimeoutMs, $outFile -ScriptBlock {
        param($t, $maxHops, $timeout, $outFile)
        & tracert -d -h $maxHops -w $timeout $t 2>&1 | Out-File -FilePath $outFile -Encoding utf8
    }
}

# Public IP
$publicIpFile = Join-Path $TempDir "public_ip.out"
$Jobs += Start-Job -Name "PublicIP" -ArgumentList $publicIpFile -ScriptBlock {
    param($outFile)
    $ip = $null
    try {
        $ip = (Invoke-WebRequest -Uri "https://ifconfig.me" -TimeoutSec 5 -UseBasicParsing).Content.Trim()
    } catch {}
    if (-not $ip) {
        try {
            $ip = (Invoke-WebRequest -Uri "https://api.ipify.org" -TimeoutSec 5 -UseBasicParsing).Content.Trim()
        } catch {}
    }
    if (-not $ip) {
        try {
            $ip = (Invoke-WebRequest -Uri "https://ipinfo.io/ip" -TimeoutSec 5 -UseBasicParsing).Content.Trim()
        } catch {}
    }
    if ($ip) { $ip } else { "N/A" } | Out-File -FilePath $outFile -Encoding utf8
}

# =====================================================================
# PHASE 3: Wait and collect results
# =====================================================================

Write-Log "Waiting for all parallel tests to complete..."
$Jobs | Wait-Job | Out-Null
Write-Log "All parallel tests completed at $(Get-Date -Format 'HH:mm:ss')"

# Collect Public IP
Write-Log ""
Write-Log "========== Public IP =========="
$PublicIP = "N/A"
if (Test-Path $publicIpFile) {
    $PublicIP = (Get-Content $publicIpFile -Raw).Trim()
}
Write-Log "Public IP : $PublicIP"

# Collect Gateway Ping
$gwFile = Join-Path $TempDir "ping_gateway.out"
if (Test-Path $gwFile) {
    $skipContent = Get-Content $gwFile -Raw
    if ($skipContent -match 'SKIP:no_gateway') {
        Write-Log ""
        Write-Log "========== Ping Gateway: SKIPPED (no gateway) =========="
        $GwResult = @{ Tx = 0; Rx = 0; Loss = 100; Min = $null; Avg = $null; Max = $null; StdDev = $null; Jitter = $null }
    } else {
        $GwResult = Parse-PingOutput -TempFile $gwFile -TargetLabel "$Gateway (Gateway)"
    }
} else {
    $GwResult = @{ Tx = 0; Rx = 0; Loss = 100; Min = $null; Avg = $null; Max = $null; StdDev = $null; Jitter = $null }
}

# Collect Target Pings
$TargetResults = [ordered]@{}
foreach ($tf in $TargetPingFiles) {
    $target = $tf.Target
    $result = Parse-PingOutput -TempFile $tf.File -TargetLabel $target
    $TargetResults[$target] = $result
}

# Collect Traceroutes
foreach ($tf in $TargetTraceFiles) {
    $target = $tf.Target
    Write-Log ""
    Write-Log "========== Traceroute: $target =========="
    Write-Log "Probing path (ICMP, no DNS resolution)..."
    if (Test-Path $tf.File) {
        $trOut = Get-Content $tf.File -Raw
        if ($trOut) {
            Write-Log ($trOut.Trim())
        } else {
            Write-Log "ERROR: No traceroute output for $target"
        }
    } else {
        Write-Log "ERROR: No traceroute output file for $target"
    }
}

# Clean up jobs
$Jobs | Remove-Job -Force 2>$null

# =====================================================================
# PHASE 4: Write CSV
# =====================================================================

Write-Log ""
Write-Log "========== Writing CSV Summary =========="

# Build CSV header if file doesn't exist
if (-not (Test-Path $SummaryCsv)) {
    $header = @(
        "timestamp", "ssid", "bssid", "rssi", "noise", "channel", "tx_rate", "phy_mode",
        "iface", "ip_addr", "netmask", "gateway", "mac_addr", "public_ip",
        "target", "gw_or_target_tx", "gw_or_target_rx", "gw_or_target_loss",
        "gw_or_target_min", "gw_or_target_avg", "gw_or_target_max",
        "gw_or_target_stddev", "gw_or_target_jitter"
    ) -join ","
    Add-Content -Path $SummaryCsv -Value $header -Encoding UTF8
}

# Common prefix fields
$csvPrefix = @(
    $Timestamp,
    (Format-CsvField $WifiSSID),
    (Format-CsvField $WifiBSSID),
    $WifiRSSI,
    $WifiNoise,
    (Format-CsvField $WifiChannel),
    $WifiTxRate,
    (Format-CsvField $WifiPhyMode),
    (Format-CsvField $WifiIface),
    $IPAddr,
    $Netmask,
    $Gateway,
    $MacAddr,
    $PublicIP
) -join ","

# Gateway row
$gwCsvLine = "$csvPrefix,gateway,$($GwResult.Tx),$($GwResult.Rx),$($GwResult.Loss),$(Format-NumOrNA $GwResult.Min),$(Format-NumOrNA $GwResult.Avg),$(Format-NumOrNA $GwResult.Max),$(Format-NumOrNA $GwResult.StdDev),$($GwResult.Jitter)"
Add-Content -Path $SummaryCsv -Value $gwCsvLine -Encoding UTF8

# Target rows
foreach ($target in $Targets) {
    $r = $TargetResults[$target]
    $targetCsvLine = "$csvPrefix,$target,$($r.Tx),$($r.Rx),$($r.Loss),$(Format-NumOrNA $r.Min),$(Format-NumOrNA $r.Avg),$(Format-NumOrNA $r.Max),$(Format-NumOrNA $r.StdDev),$($r.Jitter)"
    Add-Content -Path $SummaryCsv -Value $targetCsvLine -Encoding UTF8
}

Write-Log "CSV summary written to: $SummaryCsv"

# =====================================================================
# Cleanup temp files
# =====================================================================
Remove-Item -Recurse -Force $TempDir -ErrorAction SilentlyContinue

Write-Log ""
Write-Log "========== Diagnostics Complete =========="
Write-Host ""
Write-Host "Detailed log : $OutputFile"
Write-Host "Summary CSV  : $SummaryCsv"
