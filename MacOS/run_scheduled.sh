#!/bin/bash
#
# Network Diagnostics Scheduler
# Runs network_diag.sh every 5 minutes at :00, :05, :10, ..., :55
# Press Ctrl-C to stop gracefully
#

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DIAG_SCRIPT="${SCRIPT_DIR}/network_diag.sh"

RUNNING=true

cleanup() {
    echo ""
    echo "=========================================="
    echo "  Scheduler stopped by user (Ctrl-C)"
    echo "  Logs saved to: ${SCRIPT_DIR}/logs/"
    echo "  Summary CSV : ${SCRIPT_DIR}/logs/summary.csv"
    echo "=========================================="
    RUNNING=false
}

trap cleanup SIGINT SIGTERM

echo "=========================================="
echo "  Network Diagnostics Scheduler"
echo "  Runs every 5 minutes (00, 05, 10, ...)"
echo "  Press Ctrl-C to stop"
echo "  Started at: $(date)"
echo "=========================================="
echo ""

# Run immediately on start
echo ">>> [$(date +%H:%M:%S)] Running diagnostics..."
"$DIAG_SCRIPT"
echo ""

while $RUNNING; do
    # Calculate seconds until the next 5-minute boundary
    current_sec=$(date +%S)
    current_min=$(date +%M)

    # Seconds elapsed within the current 5-minute block
    block_elapsed=$(( (10#$current_min % 5) * 60 + 10#$current_sec ))
    block_total=$(( 5 * 60 ))  # 300 seconds

    if [ "$block_elapsed" -eq 0 ]; then
        # We're exactly at a boundary; run now and sleep full 5 min
        sleep_secs=$block_total
    else
        sleep_secs=$(( block_total - block_elapsed ))
    fi

    echo ">>> Next run in ${sleep_secs}s (at $(date -v+${sleep_secs}S +%H:%M:%S))"

    # Sleep in 1-second increments to remain responsive to Ctrl-C
    for ((i=0; i<sleep_secs; i++)); do
        sleep 1
        $RUNNING || break
    done

    $RUNNING || break

    echo ">>> [$(date +%H:%M:%S)] Running diagnostics..."
    "$DIAG_SCRIPT"
    echo ""
done

exit 0
