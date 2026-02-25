# network-reliability-tester

A PowerShell script that tests the reliability and performance of your WiFi (or any network connection) over a user-defined period of time. Pings multiple targets with varying packet sizes, runs periodic download and upload speed tests, and generates a self-contained dark-themed HTML report at the end.

> **Note:** Version 1.0.0 was vibe coded by [Claude Sonnet 4.6](https://www.anthropic.com/claude). Use at your own risk.

---

## Features

- Prompts for a test duration (1–1440 minutes) and runs automatically
- Pings **8 targets** every 30 seconds including DNS resolvers, gaming infrastructure, and backbone carriers
- Tests **5 packet sizes** per target (32B, 128B, 512B, 1024B, 1472B) to detect MTU/congestion issues and simulate real-world traffic from small game packets up to large file transfers
- Tracks avg/min/max ping, jitter, packet loss, and the ping delta as packet size increases relative to the 32B baseline
- Runs a **25MB download speed test and a 10MB upload speed test** via the Cloudflare speed API every 5 rounds
- Color-coded live console output (green/yellow/red) while the test runs
- Generates a **self-contained HTML report** saved to the same directory as the script, which opens automatically on completion
- The HTML report includes interactive Chart.js line graphs for ping over time and download/upload speed over time, KPI summary cards, a summary table per target and packet size, and a scrollable raw measurements table

---

## Requirements

- Windows 10 or later (PowerShell 5.1+)
- Internet connection
- No external dependencies or modules required

---

## Usage

### Option 1 — Right-click

Right-click `network-report.ps1` and select **Run with PowerShell**.

### Option 2 — Terminal

```powershell
# If needed, allow script execution for this session
Set-ExecutionPolicy -Scope Process Bypass

# Run the script
.\network-report.ps1
```

You will be prompted to enter a duration in minutes. The test starts 3 seconds after you confirm.

---

## Ping Targets

The script pings the following 8 targets. All IPs have been manually verified to respond to ICMP — several publisher IPs were tested and discarded during development because major game companies (Riot Games, Ubisoft, Activision, Akamai, Xbox Live, Epic Games) block ICMP at the network edge.

| Target | IP | Notes |
|---|---|---|
| Cloudflare DNS | `1.1.1.1` | Anycast DNS resolver |
| Google DNS (Primary) | `8.8.8.8` | Anycast DNS resolver |
| Google DNS (Secondary) | `8.8.4.4` | Secondary GCP DNS resolver |
| Steam (Valve) | `208.64.200.1` | Valve data center |
| Valve CS2 (US East) | `162.254.193.6` | Valve SDR relay, US East |
| Level3 Backbone | `4.2.2.2` | Lumen/Level3 Tier-1 carrier |
| PSN (Sony) | `69.36.135.129` | Sony Interactive Entertainment LLC, LA datacenter |
| Battle.net | `166.117.114.163` | Resolved Battle.net IP, confirmed pingable |
| Microsoft (Bing) | `204.79.197.200` | Azure/Microsoft edge, reliably responds to ICMP |
| AWS Global Accelerator | `99.83.190.102` | AWS anycast edge; most other AWS IPs block ICMP |
| Cloudflare CDN Edge | `104.16.0.1` | Cloudflare CDN anycast range (separate from DNS) |
| Cloudflare Workers | `104.21.0.1` | Cloudflare Workers platform edge |
| Fastly CDN | `151.101.0.1` | Fastly anycast CDN — carries Reddit, GitHub, Twitch |
| Fastly CDN (Secondary) | `199.232.0.1` | Fastly secondary anycast range |
| Hurricane Electric | `216.218.186.2` | HE.net Tier-1 backbone, known pingable |
| Linode/Akamai Newark | `45.33.0.1` | Linode NJ (Akamai-owned cloud) |
| Cogent Communications | `38.104.0.1` | Cogent Tier-1 backbone carrier |

---

## Packet Sizes

Each target is pinged **5 times** per size per round, and 5 packet sizes are tested per round:

| Size | Represents |
|---|---|
| 32 B | Typical small game packet (position updates, heartbeats) |
| 128 B | Medium game packet (state sync, chat) |
| 512 B | Large game packet / VoIP |
| 1024 B | Near-MTU — web browsing, streaming |
| 1472 B | Maximum standard MTU payload — large downloads, file transfers |

The delta column in the report shows how much latency increases as packet size grows relative to the 32B baseline. A large delta at 1472B is a strong indicator of congestion, bufferbloat, or a misconfigured MTU on your router or ISP equipment.

---

## Speed Tests

A speed test runs every 5 rounds and measures both download and upload:

- **Download** — fetches a 25MB file from `speed.cloudflare.com`
- **Upload** — POSTs a 10MB payload to `speed.cloudflare.com/__up`

Both are displayed live in the console during the test and graphed separately in the HTML report.

---

## Report

At the end of the test a `WiFi-Report_YYYYMMDD_HHMMSS.html` file is saved to the same directory as the script and opened in your default browser automatically. The file should be around 45KB (5 minutes, ~5-10 rounds), or 100KB (10 minutes, ~10-20 rounds) in size.

The report contains:

- **KPI cards** — overall average ping, average packet loss, average download speed, average upload speed, number of rounds, targets monitored, and speed tests run
- **Ping over time chart** — line graph of 32B ping per target across all rounds
- **Speed over time chart** — combined line graph of download and upload Mbps across all speed test rounds
- **Summary table** — average ping, peak ping, and average packet loss broken down by target and packet size
- **Raw data table** — every individual measurement (last 200 entries) including timestamp, target, packet size, avg/min/max ms, jitter, loss%, and delta from 32B baseline

---

## Configuration

The following variables at the top of the script can be adjusted without breaking anything:

| Variable | Default | Description |
|---|---|---|
| `$PacketSizes` | `32, 128, 512, 1024, 1472` | Packet sizes to test in bytes |
| `$PingCount` | `5` | Number of pings per target per size per round |
| `$IntervalSecs` | `30` | Seconds between measurement rounds |
| `$SpeedTestEvery` | `5` | Run a speed test every N rounds |
| `$SpeedTestUrl` | Cloudflare 25MB | URL used for the download speed test |

To add or change ping targets, edit the `$PingTargets` ordered hashtable at the top of the script. Note that many game publisher IPs block ICMP — if a target shows consistent timeouts, the IP is likely filtered at the source and needs to be swapped out.

---

## Why some game servers are not included

During development, the following were tested and dropped because they block ICMP at the network edge:

- **Riot Games** — all IPs in Riot's ASN block ICMP
- **Ubisoft** — confirmed by IPinfo's live scan that zero IPs in Ubisoft's ASN respond to pings; their i3D.net hosting infrastructure also does not respond
- **Akamai** — filters ICMP on CDN edge nodes
- **Activision / COD** — routes through AWS/Azure, ICMP blocked
- **Epic Games** — routes through AWS, ICMP blocked
- **Xbox Live** — tested and confirmed timing out consistently

If you find a reliable pingable IP for any of these, feel free to open a PR.

---

## License

GNU General Public License v3.0 — see [LICENSE](LICENSE) for details.

Copyright 2026 ProishTheIdiot
