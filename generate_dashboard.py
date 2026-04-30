#!/usr/bin/env python3
"""
Generate an interactive HTML dashboard for network diagnostics data.

Reads logs/summary.csv and produces logs/dashboard.html — a self-contained
page with Chart.js line charts, time/target/metric filters, and auto-refresh.

Usage:
    python3 generate_dashboard.py

Then serve the logs directory and open dashboard.html:
    cd logs && python3 -m http.server 8080
    open http://localhost:8080/dashboard.html
"""

import csv
import json
import os
import sys
from datetime import datetime

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
CSV_PATH = os.path.join(SCRIPT_DIR, "logs", "summary.csv")
HTML_PATH = os.path.join(SCRIPT_DIR, "logs", "dashboard.html")


def read_csv(path):
    """Read summary.csv, return rows and metadata."""
    rows = []
    targets = set()
    if not os.path.exists(path):
        print(f"ERROR: {path} not found. Run network_diag.sh first.", file=sys.stderr)
        sys.exit(1)

    with open(path, "r", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        for row in reader:
            rows.append(row)
            targets.add(row.get("target", ""))

    if not rows:
        print("ERROR: summary.csv is empty", file=sys.stderr)
        sys.exit(1)

    timestamps = sorted(set(r["timestamp"] for r in rows))
    targets = sorted(targets)

    return rows, timestamps, targets


def rows_to_json(rows):
    """Convert rows to a compact JSON structure for embedding."""
    return json.dumps(rows, ensure_ascii=False)


def generate_html(timestamps, targets, rows_json):
    """Generate the self-contained dashboard HTML."""
    targets_json = json.dumps(targets, ensure_ascii=False)
    min_ts = timestamps[0] if timestamps else ""
    max_ts = timestamps[-1] if timestamps else ""

    # Convert YYYYMMDD_HHMMSS to datetime-local format
    def ts_to_dt(ts):
        try:
            dt = datetime.strptime(ts, "%Y%m%d_%H%M%S")
            return dt.strftime("%Y-%m-%dT%H:%M:%S")
        except ValueError:
            return ts

    min_dt = ts_to_dt(min_ts)
    max_dt = ts_to_dt(max_ts)

    return f"""<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Network Diagnostics Dashboard</title>
<script src="https://cdn.jsdelivr.net/npm/chart.js@4.4.0/dist/chart.umd.min.js">
</script>
<style>
* {{ box-sizing: border-box; margin: 0; padding: 0; }}
body {{ font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
       background: #1a1a2e; color: #e0e0e0; padding: 20px; }}
h1 {{ text-align: center; margin-bottom: 5px; font-size: 1.4em; }}
.header-bar {{ display: flex; justify-content: space-between; align-items: center;
              flex-wrap: wrap; gap: 10px; margin-bottom: 15px; }}
.status {{ font-size: 0.85em; color: #888; }}
.status .ok {{ color: #4caf50; }}
.status .err {{ color: #f44336; }}
.filters {{ display: flex; flex-wrap: wrap; gap: 15px; align-items: flex-start;
           background: #16213e; padding: 12px 16px; border-radius: 8px; margin-bottom: 20px; }}
.filter-group {{ display: flex; flex-direction: column; gap: 4px; }}
.filter-group label {{ font-size: 0.75em; color: #aaa; text-transform: uppercase; }}
.filter-group input[type="datetime-local"] {{ background: #0f3460; color: #e0e0e0;
    border: 1px solid #333; padding: 4px 8px; border-radius: 4px; font-size: 0.85em; }}
.target-list {{ display: flex; flex-wrap: wrap; gap: 6px; max-width: 600px; }}
.target-chip {{ display: flex; align-items: center; gap: 4px; font-size: 0.8em;
               background: #0f3460; padding: 3px 8px; border-radius: 12px; cursor: pointer;
               user-select: none; transition: background 0.2s; }}
.target-chip.active {{ background: #533483; }}
.target-chip input {{ display: none; }}
.target-chip.wifi {{ border: 1px solid #e94560; }}
.metric-list {{ display: flex; flex-wrap: wrap; gap: 6px; }}
.metric-chip {{ display: flex; align-items: center; gap: 4px; font-size: 0.8em;
               background: #0f3460; padding: 3px 8px; border-radius: 12px; cursor: pointer;
               user-select: none; }}
.metric-chip.active {{ background: #533483; }}
.metric-chip input {{ display: none; }}
.charts-grid {{ display: grid; grid-template-columns: repeat(auto-fit, minmax(500px, 1fr));
               gap: 20px; }}
.chart-box {{ background: #16213e; border-radius: 8px; padding: 12px; }}
.chart-box h3 {{ font-size: 0.9em; margin-bottom: 8px; color: #ccc; text-align: center; }}
.chart-box canvas {{ max-height: 300px; }}
.no-data {{ text-align: center; color: #666; padding: 40px; }}
.refresh-btn {{ background: #533483; color: #fff; border: none; padding: 6px 14px;
               border-radius: 4px; cursor: pointer; font-size: 0.85em; }}
.refresh-btn:hover {{ background: #6c4fa0; }}
.note {{ font-size: 0.75em; color: #666; text-align: center; margin-top: 15px; }}
@media (max-width: 600px) {{ .charts-grid {{ grid-template-columns: 1fr; }} }}
</style>
</head>
<body>

<h1>Network Diagnostics Dashboard</h1>

<div class="header-bar">
  <span class="status">Last updated: <span id="lastUpdate">loading...</span>
    <span id="fetchStatus" class="ok"></span></span>
  <div>
    <label style="font-size:0.8em;margin-right:8px;">
      Auto-refresh <input type="checkbox" id="autoRefresh" checked>
    </label>
    <button class="refresh-btn" onclick="loadData()">Refresh Now</button>
  </div>
</div>

<div class="filters">
  <div class="filter-group">
    <label>Start Time</label>
    <input type="datetime-local" id="timeStart" value="{min_dt}">
  </div>
  <div class="filter-group">
    <label>End Time</label>
    <input type="datetime-local" id="timeEnd" value="">
  </div>
  <div class="filter-group" style="flex:1;min-width:250px;">
    <label>Targets</label>
    <div class="target-list" id="targetList"></div>
  </div>
  <div class="filter-group" style="flex:1;min-width:250px;">
    <label>Ping Metrics</label>
    <div class="metric-list" id="metricList"></div>
  </div>
</div>

<div class="charts-grid" id="chartsGrid"></div>

<p class="note">For auto-refresh to work, serve this directory via HTTP:
  <code>cd logs && python3 -m http.server 8080</code>
  then open <code>http://localhost:8080/dashboard.html</code>
</p>

<script>
// ============================================================
// Embedded fallback data (used when fetch is unavailable)
// ============================================================
const EMBEDDED_DATA = {rows_json};

// ============================================================
// Constants
// ============================================================
const CSV_URL = 'summary.csv';
const REFRESH_INTERVAL_MS = 5 * 60 * 1000; // 5 minutes
const TARGETS_ALL = {targets_json};

const PING_METRICS = [
  {{ key: 'gw_or_target_avg',    label: 'Avg RTT (ms)',  color: '#4fc3f7', yAxisID: 'y' }},
  {{ key: 'gw_or_target_max',    label: 'Max RTT (ms)',  color: '#ef5350', yAxisID: 'y' }},
  {{ key: 'gw_or_target_min',    label: 'Min RTT (ms)',  color: '#66bb6a', yAxisID: 'y' }},
  {{ key: 'gw_or_target_stddev', label: 'StdDev (ms)',   color: '#ab47bc', yAxisID: 'y' }},
  {{ key: 'gw_or_target_jitter', label: 'Jitter (ms)',   color: '#ffa726', yAxisID: 'y' }},
  {{ key: 'gw_or_target_loss',   label: 'Loss (%)',      color: '#ef5350', yAxisID: 'y1' }},
];

const WIFI_METRICS = [
  {{ key: 'rssi',    label: 'RSSI (dBm)',   color: '#4fc3f7' }},
  {{ key: 'noise',   label: 'Noise (dBm)',  color: '#ef5350' }},
  {{ key: 'tx_rate', label: 'Tx Rate (Mbps)', color: '#66bb6a' }},
];

// ============================================================
// State
// ============================================================
let allRows = [];
let charts = {{}};
let activeTargets = new Set();
let activeMetrics = new Set(['gw_or_target_avg', 'gw_or_target_max', 'gw_or_target_min',
                              'gw_or_target_stddev', 'gw_or_target_jitter']);
let refreshTimer = null;

// ============================================================
// CSV parsing (handles simple CSV with no quoted fields)
// ============================================================
function parseCSV(text) {{
    const lines = text.trim().split(/\\n/);
    if (lines.length < 2) return [];
    const headers = lines[0].split(',');
    const rows = [];
    for (let i = 1; i < lines.length; i++) {{
        const vals = lines[i].split(',');
        if (vals.length < headers.length) continue;
        const row = {{}};
        headers.forEach((h, j) => {{ row[h.trim()] = (vals[j] || '').trim(); }});
        rows.push(row);
    }}
    return rows;
}}

// ============================================================
// Time helpers
// ============================================================
function tsToDate(ts) {{
    // YYYYMMDD_HHMMSS -> Date
    const m = ts.match(/^(\\d{{4}})(\\d{{2}})(\\d{{2}})_(\\d{{2}})(\\d{{2}})(\\d{{2}})$/);
    if (!m) return null;
    return new Date(+m[1], +m[2] - 1, +m[3], +m[4], +m[5], +m[6]);
}}

function formatTs(ts) {{
    // YYYYMMDD_HHMMSS -> "HH:MM:SS"
    const m = ts.match(/^(\\d{{4}})(\\d{{2}})(\\d{{2}})_(\\d{{2}})(\\d{{2}})(\\d{{2}})$/);
    if (!m) return ts;
    return `${{m[4]}}:${{m[5]}}:${{m[6]}}`;
}}

function formatTsFull(ts) {{
    // YYYYMMDD_HHMMSS -> "MM-DD HH:MM"
    const m = ts.match(/^(\\d{{4}})(\\d{{2}})(\\d{{2}})_(\\d{{2}})(\\d{{2}})(\\d{{2}})$/);
    if (!m) return ts;
    return `${{m[2]}}-${{m[3]}} ${{m[4]}}:${{m[5]}}`;
}}

function dateToInput(d) {{
    const pad = n => String(n).padStart(2, '0');
    return `${{d.getFullYear()}}-${{pad(d.getMonth()+1)}}-${{pad(d.getDate())}}T${{pad(d.getHours())}}:${{pad(d.getMinutes())}}:${{pad(d.getSeconds())}}`;
}}

// ============================================================
// Data loading
// ============================================================
async function loadData() {{
    const statusEl = document.getElementById('fetchStatus');
    statusEl.textContent = '';
    statusEl.className = '';

    let rows = [];
    try {{
        const resp = await fetch(CSV_URL);
        if (!resp.ok) throw new Error(`HTTP ${{resp.status}}`);
        const text = await resp.text();
        rows = parseCSV(text);
        if (rows.length === 0) throw new Error('empty CSV');
        statusEl.textContent = ' ✓ live';
        statusEl.className = 'ok';
    }} catch (e) {{
        console.warn('Fetch failed, using embedded data:', e.message);
        if (EMBEDDED_DATA && EMBEDDED_DATA.length > 0) {{
            rows = EMBEDDED_DATA;
            statusEl.textContent = ' ⚠ embedded (stale)';
            statusEl.className = 'err';
        }} else {{
            statusEl.textContent = ' ✗ no data';
            statusEl.className = 'err';
            return;
        }}
    }}

    if (rows.length === 0) return;

    allRows = rows;
    document.getElementById('lastUpdate').textContent = new Date().toLocaleString();
    updateTimeRange();
    renderFilters();
    renderAllCharts();
}}

// ============================================================
// Time range
// ============================================================
function updateTimeRange() {{
    if (allRows.length === 0) return;
    const times = allRows.map(r => tsToDate(r.timestamp)).filter(Boolean);
    times.sort((a, b) => a - b);
    if (times.length === 0) return;
    const endEl = document.getElementById('timeEnd');
    if (!endEl.value) {{
        endEl.value = dateToInput(times[times.length - 1]);
    }}
}}

function getTimeFilter() {{
    const startEl = document.getElementById('timeStart');
    const endEl = document.getElementById('timeEnd');
    let start = startEl.value ? new Date(startEl.value) : null;
    let end = endEl.value ? new Date(endEl.value) : null;
    return r => {{
        const d = tsToDate(r.timestamp);
        if (!d) return false;
        if (start && d < start) return false;
        if (end && d > end) return false;
        return true;
    }};
}}

// ============================================================
// Filter UI
// ============================================================
function renderFilters() {{
    renderTargetChips();
    renderMetricChips();
}}

function renderTargetChips() {{
    const container = document.getElementById('targetList');
    container.innerHTML = '';

    // WiFi chip (always first)
    const wifiChip = document.createElement('label');
    wifiChip.className = 'target-chip wifi' + (activeTargets.has('__WIFI__') ? ' active' : '');
    wifiChip.innerHTML = '<input type="checkbox" data-target="__WIFI__">📶 WiFi';
    wifiChip.querySelector('input').checked = activeTargets.has('__WIFI__');
    wifiChip.addEventListener('click', (e) => {{
        e.preventDefault();
        toggleTarget('__WIFI__');
        renderTargetChips();
        renderAllCharts();
    }});
    container.appendChild(wifiChip);

    // Target chips from data
    const seen = new Set();
    allRows.forEach(r => {{
        const t = r.target;
        if (!t || seen.has(t)) return;
        seen.add(t);
    }});

    const sorted = Array.from(seen).sort();
    sorted.forEach(t => {{
        const chip = document.createElement('label');
        chip.className = 'target-chip' + (activeTargets.has(t) ? ' active' : '');
        chip.innerHTML = `<input type="checkbox" data-target="${{t}}"> ${{t}}`;
        chip.querySelector('input').checked = activeTargets.has(t);
        chip.addEventListener('click', (e) => {{
            e.preventDefault();
            toggleTarget(t);
            renderTargetChips();
            renderAllCharts();
        }});
        container.appendChild(chip);
    }});

    // Auto-select first few if nothing selected
    if (activeTargets.size === 0 && sorted.length > 0) {{
        activeTargets.add('__WIFI__');
        sorted.slice(0, 4).forEach(t => activeTargets.add(t));
        renderTargetChips();
    }}
}}

function toggleTarget(target) {{
    if (activeTargets.has(target)) {{
        activeTargets.delete(target);
    }} else {{
        activeTargets.add(target);
    }}
}}

function renderMetricChips() {{
    const container = document.getElementById('metricList');
    container.innerHTML = '';
    PING_METRICS.forEach(m => {{
        const chip = document.createElement('label');
        chip.className = 'metric-chip' + (activeMetrics.has(m.key) ? ' active' : '');
        chip.innerHTML = `<input type="checkbox" data-metric="${{m.key}}">
                          <span style="color:${{m.color}}">●</span> ${{m.label}}`;
        chip.querySelector('input').checked = activeMetrics.has(m.key);
        chip.addEventListener('click', (e) => {{
            e.preventDefault();
            if (activeMetrics.has(m.key)) {{
                activeMetrics.delete(m.key);
            }} else {{
                activeMetrics.add(m.key);
            }}
            renderMetricChips();
            renderAllCharts();
        }});
        container.appendChild(chip);
    }});
}}

// ============================================================
// Chart rendering
// ============================================================
function destroyAllCharts() {{
    Object.values(charts).forEach(c => c.destroy());
    charts = {{}};
}}

function getDataForTarget(rows, targetName) {{
    const timeFilter = getTimeFilter();
    const filtered = rows.filter(r => r.target === targetName && timeFilter(r));
    // Sort by timestamp
    filtered.sort((a, b) => tsToDate(a.timestamp) - tsToDate(b.timestamp));
    return filtered;
}}

function getWifiData(rows) {{
    const timeFilter = getTimeFilter();
    // WiFi data is the same for all targets in a run; dedupe by timestamp
    const seen = new Set();
    const data = [];
    rows.forEach(r => {{
        const ts = r.timestamp;
        if (seen.has(ts)) return;
        if (!timeFilter(r)) return;
        seen.add(ts);
        data.push(r);
    }});
    data.sort((a, b) => tsToDate(a.timestamp) - tsToDate(b.timestamp));
    return data;
}}

// Shared chart options factory
function makeChartOptions() {{
    return {{
        responsive: true,
        maintainAspectRatio: false,
        animation: {{ duration: 200 }},
        plugins: {{
            legend: {{ position: 'bottom', labels: {{ color: '#ccc', boxWidth: 12, padding: 10 }} }},
        }},
        scales: {{
            x: {{
                type: 'category',
                ticks: {{ color: '#888', maxTicksLimit: 15, maxRotation: 45 }},
                grid: {{ color: '#333' }},
            }},
            y: {{
                type: 'linear',
                display: true,
                position: 'left',
                title: {{ display: true, text: 'ms / dBm / Mbps', color: '#888' }},
                ticks: {{ color: '#888' }},
                grid: {{ color: '#333' }},
            }},
            y1: {{
                type: 'linear',
                display: true,
                position: 'right',
                title: {{ display: true, text: 'Loss %', color: '#888' }},
                ticks: {{ color: '#888' }},
                grid: {{ drawOnChartArea: false }},
                min: 0, max: 100,
            }},
        }},
        interaction: {{
            mode: 'index',
            intersect: false,
        }},
    }};
}}

function renderWiFiChart() {{
    const canvasId = 'chart___WIFI__';
    const existing = charts[canvasId];
    if (existing) {{ existing.destroy(); delete charts[canvasId]; }}

    if (!activeTargets.has('__WIFI__')) return;

    const data = getWifiData(allRows);
    if (data.length === 0) return;

    const labels = data.map(r => formatTs(r.timestamp));
    const datasets = WIFI_METRICS.map(m => ({{
        label: m.label,
        data: data.map(r => {{ const v = parseFloat(r[m.key]); return isNaN(v) ? null : v; }}),
        borderColor: m.color,
        backgroundColor: m.color + '33',
        borderWidth: 2,
        pointRadius: 2,
        tension: 0.3,
        yAxisID: 'y',
    }}));

    // Ensure canvas exists
    let canvas = document.getElementById(canvasId);
    if (!canvas) {{
        const grid = document.getElementById('chartsGrid');
        const box = document.createElement('div');
        box.className = 'chart-box';
        box.innerHTML = '<h3>📶 WiFi Metrics</h3><canvas id="' + canvasId + '" height="250"></canvas>';
        grid.appendChild(box);
        canvas = document.getElementById(canvasId);
    }}

    const ctx = document.getElementById(canvasId);
    if (!ctx) return;
    const options = makeChartOptions();
    // WiFi uses only left y-axis (no %)
    delete options.scales.y1;
    options.scales.y.title.text = 'dBm / Mbps';
    const chart = new Chart(ctx, {{
        type: 'line', data: {{ labels, datasets }}, options
    }});
    if (chart) charts[canvasId] = chart;
}}

function renderTargetChart(target) {{
    const canvasId = 'chart_' + target.replace(/[^a-zA-Z0-9]/g, '_');
    const existing = charts[canvasId];
    if (existing) {{ existing.destroy(); delete charts[canvasId]; }}

    if (!activeTargets.has(target)) return;

    const data = getDataForTarget(allRows, target);
    if (data.length === 0) return;

    const activeMetricsList = PING_METRICS.filter(m => activeMetrics.has(m.key));
    const labels = data.map(r => formatTs(r.timestamp));
    const datasets = activeMetricsList.map(m => ({{
        label: m.label,
        data: data.map(r => {{ const v = parseFloat(r[m.key]); return isNaN(v) ? null : v; }}),
        borderColor: m.color,
        backgroundColor: m.color + '33',
        borderWidth: 2,
        pointRadius: 2,
        tension: 0.3,
        yAxisID: m.yAxisID || 'y',
    }}));

    if (datasets.length === 0) return;

    // Ensure canvas exists
    let canvas = document.getElementById(canvasId);
    if (!canvas) {{
        const grid = document.getElementById('chartsGrid');
        const box = document.createElement('div');
        box.className = 'chart-box';
        const displayName = target === 'gateway' ? '🚪 Gateway' : target;
        box.innerHTML = '<h3>' + displayName + '</h3><canvas id="' + canvasId + '" height="250"></canvas>';
        grid.appendChild(box);
        canvas = document.getElementById(canvasId);
    }}

    const ctx = document.getElementById(canvasId);
    if (!ctx) return;
    const chart = new Chart(ctx, {{
        type: 'line', data: {{ labels, datasets }}, options: makeChartOptions()
    }});
    if (chart) charts[canvasId] = chart;
}}

function renderAllCharts() {{
    destroyAllCharts();
    document.getElementById('chartsGrid').innerHTML = '';

    if (allRows.length === 0) {{
        document.getElementById('chartsGrid').innerHTML =
            '<div class="no-data">No data available. Run network_diag.sh first.</div>';
        return;
    }}

    renderWiFiChart();

    // Collect unique targets from data
    const seen = new Set();
    allRows.forEach(r => {{ if (r.target) seen.add(r.target); }});
    const targets = Array.from(seen).sort();
    targets.forEach(t => renderTargetChart(t));

    if (Object.keys(charts).length === 0) {{
        document.getElementById('chartsGrid').innerHTML =
            '<div class="no-data">No targets selected. Use the filter above.</div>';
    }}
}}

// ============================================================
// Auto-refresh
// ============================================================
function setupAutoRefresh() {{
    const checkbox = document.getElementById('autoRefresh');
    function tick() {{
        if (refreshTimer) clearInterval(refreshTimer);
        if (checkbox.checked) {{
            refreshTimer = setInterval(loadData, REFRESH_INTERVAL_MS);
        }}
    }}
    checkbox.addEventListener('change', tick);
    tick();
}}

// Filter change handlers
function setupFilterListeners() {{
    ['timeStart', 'timeEnd'].forEach(id => {{
        document.getElementById(id).addEventListener('change', renderAllCharts);
    }});
}}

// ============================================================
// Init
// ============================================================
window.addEventListener('DOMContentLoaded', () => {{
    setupAutoRefresh();
    setupFilterListeners();
    loadData();
}});
</script>
</body>
</html>"""


def main():
    print(f"Reading {CSV_PATH} ...")
    rows, timestamps, targets = read_csv(CSV_PATH)
    print(f"  {len(rows)} rows, {len(timestamps)} timestamps, {len(targets)} targets")

    rows_json = rows_to_json(rows)

    print(f"Generating {HTML_PATH} ...")
    html = generate_html(timestamps, targets, rows_json)

    os.makedirs(os.path.dirname(HTML_PATH), exist_ok=True)
    with open(HTML_PATH, "w", encoding="utf-8") as f:
        f.write(html)

    print(f"Done. Dashboard written to {HTML_PATH}")
    print()
    print("To view with auto-refresh:")
    print(f"  cd {os.path.dirname(HTML_PATH)} && python3 -m http.server 8080")
    print("  Then open http://localhost:8080/dashboard.html")


if __name__ == "__main__":
    main()
