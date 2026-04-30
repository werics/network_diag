# Network Diagnostics

Comprehensive network performance monitoring toolkit. Collects Wi-Fi metrics, ping statistics (latency, jitter, loss), traceroute data, and public IP — then visualizes everything in an interactive HTML dashboard.

> **Current**: macOS | **Planned**: Windows

## Features

- **Wi-Fi monitoring** — SSID, BSSID, RSSI, noise, channel, Tx rate, PHY mode
- **Ping statistics** — min/avg/max/stddev RTT, jitter, and packet loss for gateway + configurable targets
- **Traceroute** — ICMP path probing to each target
- **Parallel execution** — all ping and traceroute tests run simultaneously (~20s per cycle)
- **Scheduled runs** — built-in scheduler runs every 5 minutes
- **CSV output** — tidy long-format data, one row per target per run, ready for analysis
- **Interactive dashboard** — HTML page with Chart.js line charts, time/target/metric filters, auto-refresh

## Project Structure

```
├── MacOS/                   # macOS version
│   ├── network_diag.sh      # Main diagnostics script
│   ├── run_scheduled.sh     # 5-minute scheduler
│   ├── wifi_info.swift      # CoreWLAN Wi-Fi helper
│   ├── generate_dashboard.py # Dashboard HTML generator
│   ├── targets.txt          # Monitor targets (domains or IPs)
│   └── logs/                # Output directory (generated)
│       ├── summary.csv      # Consolidated metrics
│       └── dashboard.html   # Interactive dashboard
├── Windows/                 # Windows version (planned)
└── README.md
```

## Files

| File | Description |
|------|-------------|
| `MacOS/network_diag.sh` | Main diagnostics script. Collects Wi-Fi, IP, ping, traceroute, public IP. |
| `MacOS/run_scheduled.sh` | Scheduler. Runs `network_diag.sh` every 5 minutes. Press Ctrl-C to stop. |
| `MacOS/wifi_info.swift` | Swift helper using CoreWLAN to get unredacted Wi-Fi info on macOS. |
| `MacOS/generate_dashboard.py` | Python script that reads `logs/summary.csv` and generates `logs/dashboard.html`. |
| `MacOS/targets.txt` | Monitor targets, one per line. Supports domains and IPs. `#` for comments. |

## Requirements

- **macOS** with Swift (built-in) and `bc` (built-in)
- **Python 3** (for `generate_dashboard.py`)
- For Wi-Fi SSID/BSSID: grant **Location Services** permission to Terminal (System Settings → Privacy & Security → Location Services)

## Quick Start

### 1. Configure targets

Edit `MacOS/targets.txt` — one target per line:

```
www.google.com
www.apple.com
8.8.8.8
# lines starting with # are ignored
```

### 2. Run once

```bash
cd MacOS && ./network_diag.sh
```

Output written to `MacOS/logs/YYYYMMDD/HHMMSS.txt` and `MacOS/logs/summary.csv`.

### 3. Run on schedule

```bash
cd MacOS && ./run_scheduled.sh
```

Runs immediately, then every 5 minutes at :00, :05, :10... Press Ctrl-C to stop.

### 4. View dashboard

```bash
cd MacOS && python3 generate_dashboard.py
cd MacOS/logs && python3 -m http.server 8080
```

Open `http://localhost:8080/dashboard.html` in a browser. The dashboard auto-refreshes every 5 minutes as new data arrives.

## Dashboard

![Dashboard](screenshots/dashboard.png)

- **WiFi chart** — RSSI, Noise, Tx Rate over time
- **Per-target charts** — avg/max/min/stddev RTT, jitter (left axis) + packet loss % (right axis)
- **Filter chips** — toggle targets and metrics on/off
- **Time range** — zoom into specific time windows
- **Auto-refresh** — fetches new CSV data every 5 minutes

## License

MIT
