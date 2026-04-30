#!/bin/bash
#
# Network Diagnostics Script for macOS
# Collects Wi-Fi info, IP info, ping quality, and traceroute data
# All ping and traceroute tests run in parallel to reduce total test time.
#
# Requirements: macOS, Swift (built-in), bc (built-in)
#

set -o pipefail

# --- Configuration ---
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SWIFT_HELPER="${SCRIPT_DIR}/wifi_info.swift"
LOG_BASE_DIR="${SCRIPT_DIR}/logs"
PING_COUNT=100
TARGETS_FILE="${SCRIPT_DIR}/targets.txt"
TARGETS=()
if [ -f "$TARGETS_FILE" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%%#*}"
        line="${line//$'\r'/}"
        line="${line##*( )}"
        line="${line%%*( )}"
        [ -n "$line" ] && TARGETS+=("$line")
    done < "$TARGETS_FILE"
fi
if [ ${#TARGETS[@]} -eq 0 ]; then
    echo "ERROR: No targets found in ${TARGETS_FILE}" | tee -a "$OUTPUT_FILE"
    exit 1
fi
WIFI_IFACE=""

# --- Timestamp ---
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
DATE_DIR=$(date +%Y%m%d)
RUN_DIR="${LOG_BASE_DIR}/${DATE_DIR}"
mkdir -p "$RUN_DIR"

OUTPUT_FILE="${RUN_DIR}/${TIMESTAMP}.txt"
SUMMARY_CSV="${LOG_BASE_DIR}/summary.csv"

# Temp directory for parallel task outputs
TMP_DIR=$(mktemp -d /tmp/network_diag_XXXXXX)
trap "rm -rf $TMP_DIR" EXIT

# Initialize Wi-Fi variables with defaults
WIFI_SSID="N/A"
WIFI_BSSID="N/A"
WIFI_RSSI="N/A"
WIFI_NOISE="N/A"
WIFI_CHANNEL="N/A"
WIFI_TX_RATE="N/A"
WIFI_PHY_MODE="N/A"

# --- Log function ---
log() {
    echo "[$(date +%Y-%m-%d\ %H:%M:%S)] $*" | tee -a "$OUTPUT_FILE"
}

# --- Detect Wi-Fi interface ---
detect_wifi_iface() {
    WIFI_IFACE=$(networksetup -listallhardwareports 2>/dev/null \
        | awk '/Wi-Fi/{getline; print $NF}')
    if [ -z "$WIFI_IFACE" ]; then
        WIFI_IFACE="en0"
    fi
}

# --- 1. Wi-Fi Information ---
# Uses multiple methods to get Wi-Fi info on macOS Sequoia+
# Priority: Swift CoreWLAN helper > system_profiler parsing

collect_wifi_info() {
    log "========== Wi-Fi Information =========="

    local wifi_data=""
    local ssid=""
    local bssid=""
    local rssi=""
    local noise=""
    local channel=""
    local tx_rate=""
    local phy_mode=""

    # --- Method 1: Swift CoreWLAN helper ---
    if [ -f "$SWIFT_HELPER" ] && [ -x "$SWIFT_HELPER" ]; then
        wifi_data=$(swift "$SWIFT_HELPER" 2>/dev/null)
        if [ -n "$wifi_data" ]; then
            ssid=$(echo "$wifi_data"     | awk -F':' '/^SSID:/{print $2}')
            bssid=$(echo "$wifi_data"    | awk -F':' '/^BSSID:/{print $2}')
            rssi=$(echo "$wifi_data"     | awk -F':' '/^RSSI:/{print $2}')
            noise=$(echo "$wifi_data"    | awk -F':' '/^Noise:/{print $2}')
            channel=$(echo "$wifi_data"  | awk -F':' '/^Channel:/{print $2}')
            tx_rate=$(echo "$wifi_data"  | awk -F':' '/^TxRate:/{print $2}')
            phy_mode=$(echo "$wifi_data" | awk -F':' '/^PHYMode:/{print $2}')
        fi
    fi

    # --- Method 2: system_profiler fallback for missing fields ---
    local sp_out
    sp_out=$(system_profiler SPAirPortDataType 2>/dev/null)

    # Extract "Current Network Information" block only (stop at next section)
    local cur_net
    cur_net=$(echo "$sp_out" | awk '
        /Current Network Information:/{found=1; next}
        found && /Other Local Wi-Fi Networks:/{exit}
        found{print}
    ')

    if [ -z "$rssi" ] || [ "$rssi" = "N/A" ]; then
        rssi=$(echo "$cur_net" | sed -nE 's/.*Signal \/ Noise:[[:space:]]*(-?[0-9]+) dBm.*/\1/p')
    fi
    if [ -z "$noise" ] || [ "$noise" = "N/A" ]; then
        noise=$(echo "$cur_net" | sed -nE 's/.*Signal \/ Noise:[[:space:]]*-?[0-9]+ dBm \/ (-?[0-9]+) dBm.*/\1/p')
    fi
    if [ -z "$channel" ] || [ "$channel" = "N/A" ]; then
        channel=$(echo "$cur_net" | awk -F': ' '/Channel:/{print $2}')
        channel=${channel:-$(echo "$cur_net" | grep -o "Channel:.*" | cut -d: -f2- | xargs)}
    fi
    if [ -z "$tx_rate" ] || [ "$tx_rate" = "N/A" ]; then
        tx_rate=$(echo "$cur_net" | awk -F': ' '/Transmit Rate:/{print $2}')
    fi
    if [ -z "$phy_mode" ] || [ "$phy_mode" = "N/A" ]; then
        phy_mode=$(echo "$cur_net" | awk -F': ' '/PHY Mode:/{print $2}')
    fi

    # --- Method 3: ssid from networksetup or ipconfig ---
    if [ -z "$ssid" ] || [ "$ssid" = "N/A" ]; then
        ssid=$(networksetup -getairportnetwork en0 2>/dev/null | awk -F': ' '/Current Wi-Fi Network/{print $2}')
    fi
    if [ -z "$ssid" ] || [ "$ssid" = "N/A" ]; then
        local ipc_ssid
        ipc_ssid=$(ipconfig getsummary en0 2>/dev/null | awk -F' : ' '/^  SSID /{print $2}')
        if [ -n "$ipc_ssid" ] && [ "$ipc_ssid" != "<redacted>" ]; then
            ssid="$ipc_ssid"
        fi
    fi

    # --- Method 4: bssid from ipconfig ---
    if [ -z "$bssid" ] || [ "$bssid" = "N/A" ]; then
        local ipc_bssid
        ipc_bssid=$(ipconfig getsummary en0 2>/dev/null | awk -F' : ' '/^  BSSID /{print $2}')
        if [ -n "$ipc_bssid" ] && [ "$ipc_bssid" != "<redacted>" ]; then
            bssid="$ipc_bssid"
        fi
    fi

    # --- Output ---
    WIFI_SSID="${ssid:-N/A}"
    WIFI_BSSID="${bssid:-N/A}"
    WIFI_RSSI="${rssi:-N/A}"
    WIFI_NOISE="${noise:-N/A}"
    WIFI_CHANNEL="${channel:-N/A}"
    WIFI_TX_RATE="${tx_rate:-N/A}"
    WIFI_PHY_MODE="${phy_mode:-N/A}"

    log "SSID      : ${WIFI_SSID}"
    log "BSSID     : ${WIFI_BSSID}"
    log "RSSI      : ${WIFI_RSSI} dBm"
    log "Noise     : ${WIFI_NOISE} dBm"
    log "Channel   : ${WIFI_CHANNEL}"
    log "Tx Rate   : ${WIFI_TX_RATE} Mbps"
    log "PHY Mode  : ${WIFI_PHY_MODE}"

    if [ "$WIFI_SSID" = "N/A" ] || [ "$WIFI_BSSID" = "N/A" ]; then
        log "NOTE      : SSID/BSSID may be redacted by macOS. Grant Terminal 'Location Services' access to resolve."
    fi
}

# --- 2. IP / Gateway / MAC Information ---
collect_ip_info() {
    log ""
    log "========== IP Information =========="

    detect_wifi_iface

    local ip_addr netmask gateway mac_addr
    ip_addr=$(ifconfig "$WIFI_IFACE" 2>/dev/null | awk '/inet /{print $2}')
    netmask=$(ifconfig "$WIFI_IFACE" 2>/dev/null | awk '/inet /{print $4}')
    gateway=$(route -n get default 2>/dev/null | awk '/gateway:/{print $2}')
    mac_addr=$(ifconfig "$WIFI_IFACE" 2>/dev/null | awk '/ether/{print $2}')

    log "Interface : ${WIFI_IFACE}"
    log "IP Addr   : ${ip_addr:-N/A}"
    log "Netmask   : ${netmask:-N/A}"
    log "Gateway   : ${gateway:-N/A}"
    log "MAC Addr  : ${mac_addr:-N/A}"

    IP_ADDR="${ip_addr:-N/A}"
    NETMASK_VAL="${netmask:-N/A}"
    GATEWAY="${gateway:-N/A}"
    MAC_ADDR="${mac_addr:-N/A}"
}

# --- Jitter calculation helper ---
# Computes mean absolute deviation of consecutive RTT values
calc_jitter() {
    local times=("$@")
    local count=${#times[@]}
    if [ "$count" -lt 2 ]; then
        echo "0"
        return
    fi

    local sum_diff=0
    local diff
    for ((i=1; i<count; i++)); do
        diff=$(echo "${times[$i]} - ${times[$((i-1))]}" | bc -l 2>/dev/null)
        diff=${diff#-}  # absolute value
        sum_diff=$(echo "$sum_diff + $diff" | bc -l 2>/dev/null)
    done
    echo "scale=3; $sum_diff / ($count - 1)" | bc -l 2>/dev/null
}

# --- Parse ping output from file, log results, set stats vars ---
# Usage: parse_ping_result <tmpfile> <label> <target>
# Sets global: p_tx, p_rx, p_loss, p_min, p_avg, p_max, p_stddev, p_jitter
parse_ping_result() {
    local tmpfile="$1"
    local label="$2"
    local target="$3"

    log ""
    log "========== Ping: ${label} (${target}) =========="
    log "Sending ${PING_COUNT} ICMP packets..."

    local ping_out
    ping_out=$(cat "$tmpfile" 2>/dev/null)

    if [ -z "$ping_out" ]; then
        log "ERROR: No ping output for ${target}"
        p_tx=0; p_rx=0; p_loss=100
        p_min=N/A; p_avg=N/A; p_max=N/A; p_stddev=N/A; p_jitter=N/A
        return
    fi

    # Parse individual RTT values for jitter
    local rtt_times=()
    while IFS= read -r line; do
        local t
        t=$(echo "$line" | sed -n 's/.*time=\([0-9.]*\) ms.*/\1/p')
        if [ -n "$t" ]; then
            rtt_times+=("$t")
        fi
    done <<< "$ping_out"

    # Parse summary
    local transmitted received pct
    transmitted=$(echo "$ping_out" | awk '/packets transmitted/{print $1}')
    received=$(echo "$ping_out" | awk '/packets received/{print $4}')
    pct=$(echo "$ping_out" | sed -nE 's/.* ([0-9.]+)% packet loss.*/\1/p')

    local rtt_line
    rtt_line=$(echo "$ping_out" | grep "round-trip min/avg/max/stddev")

    local rtt_min rtt_avg rtt_max rtt_stddev
    rtt_min=$(echo "$rtt_line"    | sed -nE 's/.*= ([0-9.]+)\/([0-9.]+)\/([0-9.]+)\/([0-9.]+) ms.*/\1/p')
    rtt_avg=$(echo "$rtt_line"    | sed -nE 's/.*= ([0-9.]+)\/([0-9.]+)\/([0-9.]+)\/([0-9.]+) ms.*/\2/p')
    rtt_max=$(echo "$rtt_line"    | sed -nE 's/.*= ([0-9.]+)\/([0-9.]+)\/([0-9.]+)\/([0-9.]+) ms.*/\3/p')
    rtt_stddev=$(echo "$rtt_line" | sed -nE 's/.*= ([0-9.]+)\/([0-9.]+)\/([0-9.]+)\/([0-9.]+) ms.*/\4/p')

    local jitter
    if [ ${#rtt_times[@]} -ge 2 ]; then
        jitter=$(calc_jitter "${rtt_times[@]}")
    else
        jitter="0"
    fi

    log "Sent      : ${transmitted:-0}"
    log "Received  : ${received:-0}"
    log "Loss      : ${pct:-100}%"
    log "RTT Min   : ${rtt_min:-N/A} ms"
    log "RTT Avg   : ${rtt_avg:-N/A} ms"
    log "RTT Max   : ${rtt_max:-N/A} ms"
    log "RTT StdDev: ${rtt_stddev:-N/A} ms"
    log "Jitter    : ${jitter:-N/A} ms"

    p_tx="${transmitted:-0}"
    p_rx="${received:-0}"
    p_loss="${pct:-100}"
    p_min="${rtt_min:-N/A}"
    p_avg="${rtt_avg:-N/A}"
    p_max="${rtt_max:-N/A}"
    p_stddev="${rtt_stddev:-N/A}"
    p_jitter="${jitter:-N/A}"
}

# --- Parse traceroute output from file, log results ---
parse_traceroute_result() {
    local tmpfile="$1"
    local label="$2"
    local target="$3"

    log ""
    log "========== Traceroute: ${label} (${target}) =========="
    log "Probing path (ICMP, no DNS resolution)..."

    local tr_out
    tr_out=$(cat "$tmpfile" 2>/dev/null)

    if [ -z "$tr_out" ]; then
        log "ERROR: No traceroute output for ${target}"
    else
        log "$tr_out"
    fi
}

# --- Launch a background ping task ---
launch_ping_bg() {
    ping -c "$PING_COUNT" -i 0.2 "$1" >"$2" 2>&1 &
}

# --- Launch a background traceroute task ---
launch_traceroute_bg() {
    traceroute -I -n -m 30 -w 2 "$1" >"$2" 2>&1 &
}

# --- Launch background public IP fetch ---
launch_public_ip_bg() {
    # Multiple fallbacks; redirect stdin to avoid background curl hanging
    { curl -s --connect-timeout 5 --max-time 10 https://ifconfig.me 2>/dev/null \
        || curl -s --connect-timeout 5 --max-time 10 https://api.ipify.org 2>/dev/null \
        || curl -s --connect-timeout 5 --max-time 10 https://ipinfo.io/ip 2>/dev/null ; } \
        > "$1" < /dev/null &
}

# --- Parallel test launcher ---
launch_parallel_tests() {
    log ""
    log "========== Launching Parallel Tests =========="
    log "Starting $(date +%H:%M:%S): ping (gateway + ${#TARGETS[@]} targets) + ${#TARGETS[@]} traceroutes + public IP"
    log ""

    # Gateway ping
    if [ -n "$GATEWAY" ] && [ "$GATEWAY" != "N/A" ]; then
        launch_ping_bg "$GATEWAY" "${TMP_DIR}/ping_gateway.out"
        PING_GW_PID=$!
        GW_LABEL="Gateway"
        GW_TARGET="$GATEWAY"
    else
        # No gateway, create a skipped marker
        echo "SKIP:no_gateway" > "${TMP_DIR}/ping_gateway.out"
        GW_LABEL="Gateway"
        GW_TARGET="$GATEWAY"
    fi

    # Internet target pings
    for target in "${TARGETS[@]}"; do
        local label
        label=$(echo "$target" | tr '.' '_')
        launch_ping_bg "$target" "${TMP_DIR}/ping_${label}.out"
    done

    # Traceroutes
    for target in "${TARGETS[@]}"; do
        local label
        label=$(echo "$target" | tr '.' '_')
        launch_traceroute_bg "$target" "${TMP_DIR}/tr_${label}.out"
    done

    # Public IP
    launch_public_ip_bg "${TMP_DIR}/public_ip.out"
}

# --- Wait for all background jobs and collect results ---
wait_and_collect() {
    log "Waiting for all parallel tests to complete..."
    wait

    log "All parallel tests completed at $(date +%H:%M:%S)"
    log ""

    # --- Collect Public IP ---
    log "========== Public IP =========="
    local pub_ip
    pub_ip=$(cat "${TMP_DIR}/public_ip.out" 2>/dev/null)
    log "Public IP : ${pub_ip:-N/A}"
    PUBLIC_IP="${pub_ip:-N/A}"

    # --- Collect Gateway Ping ---
    if [ -f "${TMP_DIR}/ping_gateway.out" ]; then
        if grep -q "^SKIP:no_gateway" "${TMP_DIR}/ping_gateway.out" 2>/dev/null; then
            log ""
            log "========== Ping Gateway: SKIPPED (no gateway) =========="
            GW_transmitted=0; GW_received=0; GW_loss=100
            GW_min=N/A; GW_avg=N/A; GW_max=N/A; GW_stddev=N/A; GW_jitter=N/A
        else
            parse_ping_result "${TMP_DIR}/ping_gateway.out" "Gateway" "$GATEWAY"
            GW_transmitted="$p_tx"
            GW_received="$p_rx"
            GW_loss="$p_loss"
            GW_min="$p_min"
            GW_avg="$p_avg"
            GW_max="$p_max"
            GW_stddev="$p_stddev"
            GW_jitter="$p_jitter"
        fi
    else
        GW_transmitted=0; GW_received=0; GW_loss=100
        GW_min=N/A; GW_avg=N/A; GW_max=N/A; GW_stddev=N/A; GW_jitter=N/A
    fi

    # --- Collect Internet Target Pings ---
    for i in "${!TARGETS[@]}"; do
        local target="${TARGETS[$i]}"
        local label
        label=$(echo "$target" | tr '.' '_')
        parse_ping_result "${TMP_DIR}/ping_${label}.out" "$target" "$target"
        PING_TX_ARR[$i]="$p_tx"
        PING_RX_ARR[$i]="$p_rx"
        PING_LOSS_ARR[$i]="$p_loss"
        PING_MIN_ARR[$i]="$p_min"
        PING_AVG_ARR[$i]="$p_avg"
        PING_MAX_ARR[$i]="$p_max"
        PING_STDDEV_ARR[$i]="$p_stddev"
        PING_JITTER_ARR[$i]="$p_jitter"
    done

    # --- Collect Traceroutes ---
    for target in "${TARGETS[@]}"; do
        local label
        label=$(echo "$target" | tr '.' '_')
        parse_traceroute_result "${TMP_DIR}/tr_${label}.out" "$target" "$target"
    done
}

# Ping stats for CSV — indexed arrays keyed by position in TARGETS
GW_transmitted=0; GW_received=0; GW_loss=100
GW_min=N/A; GW_avg=N/A; GW_max=N/A; GW_stddev=N/A; GW_jitter=N/A
PING_TX_ARR=();    PING_RX_ARR=();    PING_LOSS_ARR=()
PING_MIN_ARR=();   PING_AVG_ARR=();   PING_MAX_ARR=()
PING_STDDEV_ARR=(); PING_JITTER_ARR=()

# --- Write CSV Summary ---
# Builds the full line as a string, then writes with a single echo to avoid
# the macOS echo -n unreliability that can print "-n" as literal text.
write_csv_summary() {
    local line=""

    if [ ! -f "$SUMMARY_CSV" ]; then
        line="timestamp,ssid,bssid,rssi,noise,channel,tx_rate,phy_mode,"
        line+="iface,ip_addr,netmask,gateway,mac_addr,public_ip,"
        line+="target,gw_or_target_tx,gw_or_target_rx,gw_or_target_loss,gw_or_target_min,gw_or_target_avg,gw_or_target_max,gw_or_target_stddev,gw_or_target_jitter"
        echo "$line" >> "$SUMMARY_CSV"
    fi

    # Gateway row
    line="${TIMESTAMP},${WIFI_SSID//,/_},${WIFI_BSSID//,/_},${WIFI_RSSI},${WIFI_NOISE},${WIFI_CHANNEL//,/_},${WIFI_TX_RATE},${WIFI_PHY_MODE//,/_},"
    line+="${WIFI_IFACE},${IP_ADDR},${NETMASK_VAL},${GATEWAY},${MAC_ADDR},${PUBLIC_IP},"
    line+="gateway,${GW_transmitted},${GW_received},${GW_loss},${GW_min},${GW_avg},${GW_max},${GW_stddev},${GW_jitter}"
    echo "$line" >> "$SUMMARY_CSV"

    # One row per internet target
    for i in "${!TARGETS[@]}"; do
        local target="${TARGETS[$i]}"
        line="${TIMESTAMP},${WIFI_SSID//,/_},${WIFI_BSSID//,/_},${WIFI_RSSI},${WIFI_NOISE},${WIFI_CHANNEL//,/_},${WIFI_TX_RATE},${WIFI_PHY_MODE//,/_},"
        line+="${WIFI_IFACE},${IP_ADDR},${NETMASK_VAL},${GATEWAY},${MAC_ADDR},${PUBLIC_IP},"
        line+="${target},${PING_TX_ARR[$i]},${PING_RX_ARR[$i]},${PING_LOSS_ARR[$i]},${PING_MIN_ARR[$i]},${PING_AVG_ARR[$i]},${PING_MAX_ARR[$i]},${PING_STDDEV_ARR[$i]},${PING_JITTER_ARR[$i]}"
        echo "$line" >> "$SUMMARY_CSV"
    done
}

# --- Main ---
main() {
    echo "Network Diagnostics started at $(date)"
    echo "Output file: ${OUTPUT_FILE}"

    # Phase 1: Fast sequential collection (Wi-Fi, IP)
    collect_wifi_info
    collect_ip_info

    # Phase 2: Launch all network tests in parallel
    launch_parallel_tests

    # Phase 3: Wait for completion and collect results
    wait_and_collect

    # Phase 4: Write CSV
    write_csv_summary

    log ""
    log "========== Diagnostics Complete =========="
    echo ""
    echo "Detailed log : ${OUTPUT_FILE}"
    echo "Summary CSV  : ${SUMMARY_CSV}"
}

main
