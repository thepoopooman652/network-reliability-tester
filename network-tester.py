#!/usr/bin/env python3
"""
Network Reliability Tester v1.0.1c - Python Edition

.CLAUDE_NOTICE
    THIS PROJECT WAS VIBE CODED BY CLAUDE SONNET 4.6 FOR VERSION 1.0
    USE AT YOUR OWN RISK
.VERSION
    Network Reliability Tester Version 1.0.1c
.COPYRIGHT
    Copyright 2026 ProishTheIdiot
    GNU General Public License v3 - See LICENSE file
.GITHUB
    Original repository:
        https://github.com/thepoopooman652/network-reliability-tester/
"""

import sys
import os
import time
import socket
import struct
import select
import threading
import html as htmllib
from datetime import datetime, timedelta
from collections import defaultdict

# -----------------------------------------------------------------
#  DEPENDENCIES - only stdlib + optional requests
# -----------------------------------------------------------------
try:
    import urllib.request
    import urllib.error
except ImportError:
    pass

# -----------------------------------------------------------------
#  CONFIG
# -----------------------------------------------------------------
PING_TARGETS = [
    ("Cloudflare DNS",          "1.1.1.1"),
    ("Cloudflare Workers",      "104.21.0.1"),
    ("Cloudflare CDN Edge",     "104.16.0.1"),
    ("Google DNS",              "8.8.8.8"),
    ("Google Cloud Anycast",    "34.36.0.1"),
    ("Google Cloud DNS",        "8.8.4.4"),
    ("Google Cloud LB US-East", "34.102.136.180"),
    ("Steam (Valve)",           "208.64.200.1"),
    ("Valve CS2 (US East)",     "162.254.193.6"),
    ("Level3 Backbone",         "4.2.2.2"),
    ("PSN (Sony)",              "69.36.135.129"),
    ("Battle.net",              "166.117.114.163"),
    ("Microsoft (Bing)",        "204.79.197.200"),
    ("AWS Global Accelerator",  "99.83.190.102"),
    ("Fastly CDN Edge",         "199.232.0.1"),
    ("Fastly CDN US",           "151.101.0.1"),
    ("Azure Traffic Manager",   "13.107.42.14"),
    ("OVH BHS (Canada)",        "51.79.0.1"),
    ("DigitalOcean NYC1",       "67.205.133.197"),
    ("Cogent Communications",   "38.104.0.1"),
    ("Hurricane Electric",      "216.218.186.2"),
]

PACKET_SIZES    = [32, 128, 512, 1024, 1472]
PING_COUNT      = 10
INTERVAL_SECS   = 90
SPEED_TEST_EVERY = 5
SPEED_TEST_URL  = "https://speed.cloudflare.com/__down?bytes=25000000"
UPLOAD_URL      = "https://speed.cloudflare.com/__up"
UPLOAD_SIZE     = 10 * 1024 * 1024  # 10 MB

COLOR_MAP = {
    "Cloudflare DNS":          "54,162,235",
    "Google DNS":              "255,99,132",
    "Steam (Valve)":           "75,192,192",
    "Valve CS2 (US East)":     "0,220,180",
    "Level3 Backbone":         "255,159,64",
    "PSN (Sony)":              "200,80,255",
    "Battle.net":              "255,80,80",
    "Microsoft (Bing)":        "99,255,132",
    "AWS Global Accelerator":  "255,153,0",
    "Google Cloud DNS":        "66,214,100",
    "Google Cloud LB US-East": "30,180,80",
    "Google Cloud Anycast":    "10,140,60",
    "Fastly CDN Edge":         "255,99,200",
    "Fastly CDN US":           "220,60,160",
    "Cloudflare Workers":      "20,200,255",
    "Cloudflare CDN Edge":     "0,160,220",
    "Azure Traffic Manager":   "0,120,212",
    "OVH BHS (Canada)":        "40,200,180",
    "DigitalOcean NYC1":       "0,105,255",
    "Cogent Communications":   "180,180,60",
    "Hurricane Electric":      "255,120,50",
}

# -----------------------------------------------------------------
#  ANSI COLORS
# -----------------------------------------------------------------
class C:
    RED    = '\033[0;31m'
    YELLOW = '\033[0;33m'
    GREEN  = '\033[0;32m'
    CYAN   = '\033[0;36m'
    MAG    = '\033[0;35m'
    DGRAY  = '\033[1;30m'
    NC     = '\033[0m'

# Windows doesn't support ANSI by default — enable it
if sys.platform == 'win32':
    import ctypes
    kernel32 = ctypes.windll.kernel32
    kernel32.SetConsoleMode(kernel32.GetStdHandle(-11), 7)

# -----------------------------------------------------------------
#  ICMP PING (raw sockets - requires admin/root on most OS)
#  Falls back to TCP connect timing if raw sockets unavailable
# -----------------------------------------------------------------
ICMP_ECHO_REQUEST = 8

def _checksum(data: bytes) -> int:
    s = 0
    n = len(data) % 2
    for i in range(0, len(data) - n, 2):
        s += (data[i]) + ((data[i+1]) << 8)
    if n:
        s += data[-1]
    while s >> 16:
        s = (s & 0xFFFF) + (s >> 16)
    return ~s & 0xFFFF

def _icmp_ping(host: str, size: int, timeout: float = 2.0) -> float | None:
    """Send one ICMP echo and return RTT in ms, or None on timeout/error."""
    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_RAW, socket.IPPROTO_ICMP)
        sock.settimeout(timeout)
    except PermissionError:
        return _tcp_ping(host, timeout)
    except Exception:
        return None

    try:
        pid = os.getpid() & 0xFFFF
        seq = 1
        payload = bytes(size)
        header = struct.pack('bbHHh', ICMP_ECHO_REQUEST, 0, 0, pid, seq)
        chk = _checksum(header + payload)
        header = struct.pack('bbHHh', ICMP_ECHO_REQUEST, 0, socket.htons(chk), pid, seq)
        packet = header + payload

        dest = socket.gethostbyname(host)
        send_time = time.perf_counter()
        sock.sendto(packet, (dest, 1))

        ready = select.select([sock], [], [], timeout)
        recv_time = time.perf_counter()
        if ready[0]:
            raw, _ = sock.recvfrom(1024)
            # Validate ICMP reply type (0 = echo reply)
            icmp_type = raw[20]
            if icmp_type == 0:
                return (recv_time - send_time) * 1000
        return None
    except Exception:
        return None
    finally:
        sock.close()

def _tcp_ping(host: str, timeout: float = 2.0) -> float | None:
    """Fallback: measure TCP connect time to port 80."""
    try:
        start = time.perf_counter()
        s = socket.create_connection((host, 80), timeout=timeout)
        rtt = (time.perf_counter() - start) * 1000
        s.close()
        return rtt
    except Exception:
        return None

def run_ping_test(ip: str, size: int, count: int) -> dict:
    times = []
    lost = 0
    for _ in range(count):
        rtt = _icmp_ping(ip, size)
        if rtt is not None:
            times.append(rtt)
        else:
            lost += 1

    loss_pct = round(lost * 100 / count, 1)
    if times:
        avg_ms  = round(sum(times) / len(times), 1)
        min_ms  = round(min(times), 1)
        max_ms  = round(max(times), 1)
        jitter  = round(max(times) - min(times), 1)
    else:
        avg_ms = min_ms = max_ms = jitter = None

    return {"avg": avg_ms, "min": min_ms, "max": max_ms, "loss": loss_pct, "jitter": jitter}

# -----------------------------------------------------------------
#  SPEED TEST
# -----------------------------------------------------------------
def run_speed_test() -> tuple[float | None, float | None]:
    dl_mbps = ul_mbps = None

    # Download
    try:
        req = urllib.request.Request(SPEED_TEST_URL)
        req.add_header('User-Agent', 'NetworkReliabilityTester/1.0')
        start = time.perf_counter()
        with urllib.request.urlopen(req, timeout=60) as resp:
            data = resp.read()
        elapsed = time.perf_counter() - start
        if elapsed > 0 and len(data) > 0:
            dl_mbps = round(len(data) * 8 / elapsed / 1_048_576, 2)
    except Exception:
        pass

    # Upload
    try:
        payload = bytes(UPLOAD_SIZE)
        req = urllib.request.Request(UPLOAD_URL, data=payload, method='POST')
        req.add_header('Content-Type', 'application/octet-stream')
        req.add_header('User-Agent', 'NetworkReliabilityTester/1.0')
        start = time.perf_counter()
        with urllib.request.urlopen(req, timeout=60) as resp:
            resp.read()
        elapsed = time.perf_counter() - start
        if elapsed > 0:
            ul_mbps = round(UPLOAD_SIZE * 8 / elapsed / 1_048_576, 2)
    except Exception:
        pass

    return dl_mbps, ul_mbps

# -----------------------------------------------------------------
#  HTML REPORT BUILDER
# -----------------------------------------------------------------
LEGEND_CLICK = "function(e,legendItem,legend){const index=legendItem.datasetIndex;const ci=legend.chart;if(ci.isDatasetVisible(index)){ci.hide(index);legendItem.hidden=true;}else{ci.show(index);legendItem.hidden=false;}}"
TOOLTIP_COMMON = "backgroundColor:'#1a1f2e',borderColor:'#2d3748',borderWidth:1,titleColor:'#e2e8f0',bodyColor:'#a0aec0',padding:10,"

def build_report(results: list, speed_results: list, start_time: datetime,
                 duration_minutes: int, total_rounds: int, report_path: str) -> None:
    start_str = start_time.strftime('%A, %B %d %Y  %H:%M:%S')
    gen_time  = datetime.now().strftime('%Y-%m-%d %H:%M:%S')

    # KPIs
    valid_pings = [r['avg'] for r in results if r['avg'] is not None]
    overall_avg = round(sum(valid_pings)/len(valid_pings), 1) if valid_pings else 'N/A'
    avg_loss    = round(sum(r['loss'] for r in results)/len(results), 2) if results else 0
    valid_dl    = [s['dl'] for s in speed_results if s['dl'] is not None]
    valid_ul    = [s['ul'] for s in speed_results if s['ul'] is not None]
    avg_dl      = round(sum(valid_dl)/len(valid_dl), 2) if valid_dl else 'N/A'
    avg_ul      = round(sum(valid_ul)/len(valid_ul), 2) if valid_ul else 'N/A'

    # Summary stats
    summary = []
    for name, _ in PING_TARGETS:
        for size in PACKET_SIZES:
            subset = [r for r in results if r['name'] == name and r['size'] == size and r['avg'] is not None]
            if subset:
                s_avg  = round(sum(r['avg'] for r in subset)/len(subset), 1)
                s_peak = round(max(r['avg'] for r in subset), 1)
                s_loss = round(sum(r['loss'] for r in subset)/len(subset), 1)
            else:
                s_avg = s_peak = s_loss = None
            summary.append((name, size, s_avg, s_peak, s_loss))

    # Chart data
    unique_ts = list(dict.fromkeys(r['ts'] for r in results))
    chart_labels = ','.join(f"'{t}'" for t in unique_ts)

    datasets = []
    for name, _ in PING_TARGETS:
        vals = []
        for ts in unique_ts:
            match = next((r for r in results if r['name'] == name and r['size'] == 32 and r['ts'] == ts), None)
            vals.append(str(match['avg']) if match and match['avg'] is not None else 'null')
        c = COLOR_MAP.get(name, '128,128,128')
        datasets.append(f"{{label:'{name}',data:[{','.join(vals)}],borderColor:'rgba({c},1)',backgroundColor:'rgba({c},0.1)',tension:0.3,fill:false}}")
    chart_datasets = ','.join(datasets)

    speed_labels  = ','.join(f"'{s['ts']}'" for s in speed_results)
    speed_dl_vals = ','.join(str(s['dl']) if s['dl'] is not None else 'null' for s in speed_results)
    speed_ul_vals = ','.join(str(s['ul']) if s['ul'] is not None else 'null' for s in speed_results)

    # Summary table
    summary_rows = ''
    for name, size, s_avg, s_peak, s_loss in summary:
        lc  = '#ff4444' if (s_loss or 0) > 5 else ('#ffaa00' if (s_loss or 0) > 0 else '#22cc66')
        pc  = 'inherit' if s_avg is None else ('#ff4444' if s_avg > 150 else ('#ffaa00' if s_avg > 80 else '#22cc66'))
        ad  = f'{s_avg} ms' if s_avg  is not None else 'N/A'
        pd  = f'{s_peak} ms' if s_peak is not None else 'N/A'
        ld  = f'{s_loss}%' if s_loss  is not None else 'N/A'
        summary_rows += f"<tr><td>{htmllib.escape(name)}</td><td>{size} B</td><td style='color:{pc};font-weight:600'>{ad}</td><td>{pd}</td><td style='color:{lc};font-weight:600'>{ld}</td></tr>\n"

    # Raw rows (last 200)
    raw_rows = ''
    for r in results[-200:]:
        lc = '#ff4444' if r['loss'] > 5 else ('#ffaa00' if r['loss'] > 0 else 'inherit')
        ad = str(r['avg']) if r['avg'] is not None else 'TIMEOUT'
        delta_disp = f"+{r['delta']}" if r['delta'] is not None else ''
        raw_rows += (f"<tr><td>{r['ts']}</td><td>{htmllib.escape(r['name'])}</td><td>{r['size']}</td>"
                     f"<td>{ad}</td><td>{r['min']}</td><td>{r['max']}</td><td>{r['jitter']}</td>"
                     f"<td style='color:{lc}'>{r['loss']}%</td><td>{delta_disp}</td></tr>\n")

    html = f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>WiFi Reliability Report</title>
<script src="https://cdn.jsdelivr.net/npm/chart.js@4/dist/chart.umd.min.js"></script>
<style>
*{{box-sizing:border-box;margin:0;padding:0}}
body{{font-family:"Segoe UI",system-ui,sans-serif;background:#0f1117;color:#e2e8f0;line-height:1.6}}
header{{background:linear-gradient(135deg,#1a1f2e 0%,#0d1117 100%);padding:2rem;border-bottom:1px solid #2d3748}}
header h1{{font-size:1.8rem;color:#63b3ed;margin-bottom:.25rem}}
header p{{color:#718096;font-size:.9rem}}
.container{{max-width:1400px;margin:0 auto;padding:1.5rem}}
.kpi-grid{{display:grid;grid-template-columns:repeat(auto-fit,minmax(200px,1fr));gap:1rem;margin-bottom:2rem}}
.kpi{{background:#1a1f2e;border:1px solid #2d3748;border-radius:12px;padding:1.25rem;text-align:center}}
.kpi .val{{font-size:2rem;font-weight:700;color:#63b3ed}}
.kpi .lbl{{font-size:.8rem;color:#718096;margin-top:.25rem}}
.card{{background:#1a1f2e;border:1px solid #2d3748;border-radius:12px;padding:1.5rem;margin-bottom:1.5rem}}
.card h2{{color:#90cdf4;margin-bottom:1rem;font-size:1.1rem;border-bottom:1px solid #2d3748;padding-bottom:.5rem}}
.chart-wrap{{position:relative;height:320px}}
table{{width:100%;border-collapse:collapse;font-size:.85rem}}
th{{background:#2d3748;color:#a0aec0;padding:.6rem .8rem;text-align:left;font-weight:600;position:sticky;top:0}}
td{{padding:.5rem .8rem;border-bottom:1px solid #1e2535;color:#e2e8f0}}
tr:hover td{{background:#1e2535}}
.table-scroll{{max-height:400px;overflow-y:auto;border-radius:8px;border:1px solid #2d3748}}
footer{{text-align:center;padding:2rem;color:#4a5568;font-size:.8rem}}
footer a{{color:#4a5568}}
</style>
</head>
<body>
<header>
<h1>WiFi Reliability Report</h1>
<p>Test started: {start_str} &nbsp;|&nbsp; Duration: {duration_minutes} minute(s) &nbsp;|&nbsp; {total_rounds} rounds completed &nbsp;|&nbsp; Python Edition</p>
</header>
<div class="container">
<div class="kpi-grid">
<div class='kpi'><div class='val'>{overall_avg}<small style='font-size:1rem'> ms</small></div><div class='lbl'>Overall Avg Ping (32B)</div></div>
<div class='kpi'><div class='val'>{avg_loss}<small style='font-size:1rem'>%</small></div><div class='lbl'>Avg Packet Loss</div></div>
<div class='kpi'><div class='val'>{avg_dl}<small style='font-size:1rem'> Mbps</small></div><div class='lbl'>Avg Download Speed</div></div>
<div class='kpi'><div class='val'>{avg_ul}<small style='font-size:1rem'> Mbps</small></div><div class='lbl'>Avg Upload Speed</div></div>
<div class='kpi'><div class='val'>{total_rounds}</div><div class='lbl'>Test Rounds</div></div>
<div class='kpi'><div class='val'>{len(PING_TARGETS)}</div><div class='lbl'>Targets Monitored</div></div>
<div class='kpi'><div class='val'>{len(speed_results)}</div><div class='lbl'>Speed Tests Run</div></div>
</div>
<div class="card"><h2>Ping Over Time (32-byte packets)</h2><div class="chart-wrap"><canvas id="pingChart"></canvas></div></div>
<div class="card"><h2>Download and Upload Speed Over Time</h2><div class="chart-wrap"><canvas id="speedChart"></canvas></div></div>
<div class="card"><h2>Summary by Target and Packet Size</h2><div class="table-scroll"><table>
<thead><tr><th>Target</th><th>Packet Size</th><th>Avg Ping</th><th>Peak Ping</th><th>Avg Loss</th></tr></thead>
<tbody>{summary_rows}</tbody></table></div></div>
<div class="card"><h2>Raw Measurements (last 200 entries)</h2><div class="table-scroll"><table>
<thead><tr><th>Time</th><th>Target</th><th>Bytes</th><th>Avg ms</th><th>Min ms</th><th>Max ms</th><th>Jitter</th><th>Loss%</th><th>Delta from 32B</th></tr></thead>
<tbody>{raw_rows}</tbody></table></div></div>
</div>
<footer>Generated by WiFi Reliability Tester (Python Edition) | {gen_time}<br>Copyright 2026 ProishTheIdiot | <a href='https://github.com/thepoopooman652/network-reliability-tester/blob/main/LICENSE'>License</a></footer>
<script>
const pingCtx=document.getElementById('pingChart').getContext('2d');
new Chart(pingCtx,{{type:'line',data:{{labels:[{chart_labels}],datasets:[{chart_datasets}]}},
  options:{{responsive:true,maintainAspectRatio:false,interaction:{{mode:"index",intersect:false}},
    plugins:{{
      legend:{{labels:{{color:'#a0aec0',usePointStyle:true}},onClick:{LEGEND_CLICK}}},
      tooltip:{{mode:"index",intersect:false,{TOOLTIP_COMMON}
        itemSort:function(a,b){{return(b.raw===null?-Infinity:b.raw)-(a.raw===null?-Infinity:a.raw);}},
        callbacks:{{label:function(ctx){{if(ctx.raw===null)return null;return" "+ctx.dataset.label+": "+ctx.raw+" ms";}}}}
      }}
    }},
    scales:{{x:{{ticks:{{color:'#718096'}},grid:{{color:'#2d3748'}}}},
             y:{{ticks:{{color:'#718096'}},grid:{{color:'#2d3748'}},title:{{display:true,text:'Round-trip time (ms)',color:'#718096'}}}}}}
  }}
}});
const speedCtx=document.getElementById('speedChart').getContext('2d');
new Chart(speedCtx,{{type:'line',
  data:{{labels:[{speed_labels}],datasets:[
    {{label:'Download Mbps',data:[{speed_dl_vals}],borderColor:'rgba(104,211,145,1)',backgroundColor:'rgba(104,211,145,0.1)',tension:0.3,fill:true}},
    {{label:'Upload Mbps',data:[{speed_ul_vals}],borderColor:'rgba(99,179,237,1)',backgroundColor:'rgba(99,179,237,0.1)',tension:0.3,fill:true}}
  ]}},
  options:{{responsive:true,maintainAspectRatio:false,interaction:{{mode:"index",intersect:false}},
    plugins:{{
      legend:{{labels:{{color:'#a0aec0',usePointStyle:true}},onClick:{LEGEND_CLICK}}},
      tooltip:{{mode:"index",intersect:false,{TOOLTIP_COMMON}
        callbacks:{{label:function(ctx){{if(ctx.raw===null)return null;return" "+ctx.dataset.label+": "+ctx.raw+" Mbps";}}}}
      }}
    }},
    scales:{{x:{{ticks:{{color:'#718096'}},grid:{{color:'#2d3748'}}}},
             y:{{ticks:{{color:'#718096'}},grid:{{color:'#2d3748'}},title:{{display:true,text:'Mbps',color:'#718096'}}}}}}
  }}
}});
</script>
</body>
</html>"""

    with open(report_path, 'w', encoding='utf-8') as f:
        f.write(html)

# -----------------------------------------------------------------
#  MAIN
# -----------------------------------------------------------------
def main() -> None:
    os.system('cls' if sys.platform == 'win32' else 'clear')
    print()
    print(f"{C.CYAN}  +--------------------------------------------------+{C.NC}")
    print(f"{C.CYAN}  |        WiFi Reliability Tester v1.0.1c           |{C.NC}")
    print(f"{C.CYAN}  +--------------------------------------------------+{C.NC}")
    print()

    # Prompt for duration
    while True:
        try:
            raw = input("  Enter test duration in minutes (1 - 1440): ").strip()
            duration = int(raw)
            if 1 <= duration <= 1440:
                break
        except (ValueError, KeyboardInterrupt):
            pass
        print(f"{C.RED}  Invalid input. Please enter a number between 1 and 1440.{C.NC}")

    total_seconds    = duration * 60
    estimated_rounds = total_seconds // INTERVAL_SECS

    print()
    print(f"{C.GREEN}  > Duration  : {duration} minute(s){C.NC}")
    print(f"{C.GREEN}  > Interval  : every {INTERVAL_SECS} seconds (~{estimated_rounds} rounds){C.NC}")
    print(f"{C.GREEN}  > Speed test: every {SPEED_TEST_EVERY} rounds{C.NC}")
    print()
    print(f"{C.YELLOW}  Starting in 3 seconds... Press Ctrl+C to abort early.{C.NC}")
    time.sleep(3)

    results: list[dict]       = []
    speed_results: list[dict] = []
    start_time   = datetime.now()
    end_time     = start_time + timedelta(minutes=duration)
    script_dir   = os.path.dirname(os.path.abspath(__file__))
    ts_str       = start_time.strftime('%Y%m%d_%H%M%S')
    report_path  = os.path.join(script_dir/output, f"WiFi-Report_{ts_str}.html")
    round_num    = 0

    print()
    print(f"{C.CYAN}  {'Target':<36} {'Size':<10} {'Avg ms':>8} {'Loss%':>8} {'Min ms':>8} {'Max ms':>8}{C.NC}")
    print(f"{C.DGRAY}  {'-'*86}{C.NC}")

    try:
        while datetime.now() < end_time:
            round_num += 1
            round_time     = datetime.now()
            round_time_str = round_time.strftime('%H:%M:%S')
            mins_left      = round((end_time - datetime.now()).total_seconds() / 60, 1)

            print()
            print(f"{C.YELLOW}  [Round {round_num} | {round_time_str} | {mins_left} min remaining]{C.NC}")

            # Speed test
            if round_num % SPEED_TEST_EVERY == 1 or round_num == 1:
                print(f"{C.MAG}  >> Running speed test...{C.NC}", end='', flush=True)
                dl_mbps, ul_mbps = run_speed_test()
                speed_results.append({'ts': round_time_str, 'dl': dl_mbps, 'ul': ul_mbps})
                dl_str = f"DL: {dl_mbps} Mbps" if dl_mbps else "DL: FAILED"
                ul_str = f"UL: {ul_mbps} Mbps" if ul_mbps else "UL: FAILED"
                print(f"\r{C.MAG}  >> {dl_str}  |  {ul_str}{C.NC}")

            # Ping all targets
            for name, ip in PING_TARGETS:
                base_avg = None

                for size in PACKET_SIZES:
                    r     = run_ping_test(ip, size, PING_COUNT)
                    delta = None
                    if base_avg is not None and r['avg'] is not None:
                        delta = round(r['avg'] - base_avg, 1)
                    if size == PACKET_SIZES[0]:
                        base_avg = r['avg']

                    results.append({
                        'ts':    round_time_str,
                        'round': round_num,
                        'name':  name,
                        'ip':    ip,
                        'size':  size,
                        **r,
                        'delta': delta,
                    })

                    loss_f = r['loss']
                    avg_f  = r['avg'] or 0
                    if loss_f > 5 or avg_f > 150:
                        color = C.RED
                    elif loss_f > 0 or avg_f > 80:
                        color = C.YELLOW
                    else:
                        color = C.GREEN

                    avg_disp   = f"{r['avg']} ms" if r['avg'] is not None else "TIMEOUT"
                    delta_disp = f"(+{delta})" if delta is not None and size != PACKET_SIZES[0] else ""

                    print(f"{color}  {name:<36} {str(size)+'B':<10} {avg_disp:>8} {str(r['loss'])+'%':>8} "
                          f"{str(r['min'])+'ms' if r['min'] else 'N/A':>8} "
                          f"{str(r['max'])+'ms' if r['max'] else 'N/A':>8} {delta_disp}{C.NC}")

            # Wait for next interval
            elapsed = (datetime.now() - round_time).total_seconds()
            wait    = max(0, INTERVAL_SECS - elapsed)
            if datetime.now() + timedelta(seconds=wait) < end_time:
                time.sleep(wait)
            else:
                break

    except KeyboardInterrupt:
        print(f"\n{C.YELLOW}  Aborted by user. Generating report with collected data...{C.NC}")

    # Build report
    print()
    print(f"{C.GREEN}  Test complete. Generating report...{C.NC}")
    build_report(results, speed_results, start_time, duration, round_num, report_path)

    # Summary
    valid_pings = [r['avg'] for r in results if r['avg'] is not None]
    overall_avg = round(sum(valid_pings)/len(valid_pings), 1) if valid_pings else 'N/A'
    avg_loss    = round(sum(r['loss'] for r in results)/len(results), 2) if results else 0
    valid_dl    = [s['dl'] for s in speed_results if s['dl'] is not None]
    valid_ul    = [s['ul'] for s in speed_results if s['ul'] is not None]
    avg_dl      = round(sum(valid_dl)/len(valid_dl), 2) if valid_dl else 'N/A'
    avg_ul      = round(sum(valid_ul)/len(valid_ul), 2) if valid_ul else 'N/A'

    print()
    print(f"{C.DGRAY}  ----------------------------------------------------------------{C.NC}")
    print(f"{C.CYAN}  Report saved to:{C.NC}")
    print(f"     {report_path}")
    print()
    print(f"{C.CYAN}  Quick Summary:{C.NC}")
    print(f"     Overall Avg Ping : {overall_avg} ms")
    print(f"     Avg Packet Loss  : {avg_loss}%")
    print(f"     Avg Download     : {avg_dl} Mbps")
    print(f"     Avg Upload       : {avg_ul} Mbps")
    print(f"{C.DGRAY}  ----------------------------------------------------------------{C.NC}")
    print()

    # Open report
    import subprocess, shutil
    try:
        if sys.platform == 'win32':
            os.startfile(report_path)
        elif shutil.which('xdg-open'):
            subprocess.Popen(['xdg-open', report_path])
        elif shutil.which('open'):
            subprocess.Popen(['open', report_path])
    except Exception:
        pass

if __name__ == '__main__':
    main()
