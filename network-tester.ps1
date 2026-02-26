#Requires -Version 5.1
<#
.CLAUDE_NOTICE
    THIS PROJECT WAS VIBE CODED BY CLAUDE SONNET 4.6 FOR VERSION 1.0
    USE AT YOUR OWN RISK
.VERSION
    Version 1.0.1c
.COPYRIGHT
    Copyright 2026 ProishTheIdiot
    GNU General Public License v3 - See LICENSE file (https://github.com/thepoopooman652/network-reliability-tester/blob/main/LICENSE)
.GITHUB
    Original repository:
        https://github.com/thepoopooman652/network-reliability-tester/
.SYNOPSIS
    WiFi Reliability Tester - Tests network stability over a user-defined period.
.DESCRIPTION
    Runs periodic ping tests to multiple targets (Cloudflare DNS, Google DNS, game servers),
    measures ping with varying packet sizes, and runs speed tests via the Cloudflare Speed API.
    Saves a detailed HTML report to the script directory on completion.
#>

# -----------------------------------------------------------------
#  CONFIG
# -----------------------------------------------------------------
$PingTargets = [ordered]@{
    "Cloudflare DNS"      = "1.1.1.1"
    "Google DNS"          = "8.8.8.8"
    "Steam (Valve)"       = "208.64.200.1"
    "Valve CS2 (US East)" = "162.254.193.6"    # Valve SDR US-East, confirmed ICMP
    "Level3 Backbone"     = "4.2.2.2"          # Lumen/Level3 Tier-1 carrier, carries traffic for most game servers, always responds to ICMP
    "PSN (Sony)"          = "69.36.135.129"    # Sony Interactive Entertainment LLC own ASN, LA datacenter
    "Battle.net"          = "166.117.114.163"
    "Microsoft (Bing)"    = "204.79.197.200"
}

$PacketSizes    = @(32, 128, 512, 1024, 1472)  # bytes: small game, med, large, near-MTU, max MTU payload
$PingCount      = 5                  # pings per target per interval
$IntervalSecs   = 30                 # seconds between measurement rounds
$SpeedTestEvery = 5                  # run a speed test every N rounds
$SpeedTestUrl   = "https://speed.cloudflare.com/__down?bytes=25000000"  # 25 MB download

# -----------------------------------------------------------------
#  BANNER
# -----------------------------------------------------------------
Clear-Host
Write-Host ""
Write-Host "  +--------------------------------------------------+" -ForegroundColor Cyan
Write-Host "  |         WiFi Reliability Tester v1.0.1c          |" -ForegroundColor Cyan
Write-Host "  +--------------------------------------------------+" -ForegroundColor Cyan
Write-Host ""

# -----------------------------------------------------------------
#  USER PROMPT: duration
# -----------------------------------------------------------------
$DurationMinutes = 0
do {
    $rawInput = Read-Host "  Enter test duration in minutes (1 - 1440)"
    $parsed = 0
    $isValid = [int]::TryParse($rawInput.Trim(), [ref]$parsed)
    if ($isValid -and $parsed -ge 1 -and $parsed -le 1440) {
        $DurationMinutes = $parsed
    } else {
        Write-Host "  Invalid input. Please enter a number between 1 and 1440." -ForegroundColor Red
    }
} while ($DurationMinutes -lt 1)

$TotalSeconds    = $DurationMinutes * 60
$EstimatedRounds = [Math]::Floor($TotalSeconds / $IntervalSecs)

Write-Host ""
Write-Host "  > Duration  : $DurationMinutes minute(s)" -ForegroundColor Green
Write-Host "  > Interval  : every $IntervalSecs seconds (~$EstimatedRounds rounds)" -ForegroundColor Green
Write-Host "  > Speed test: every $SpeedTestEvery rounds" -ForegroundColor Green
Write-Host ""
Write-Host "  Starting in 3 seconds... Press Ctrl+C to abort early." -ForegroundColor Yellow
Start-Sleep 3

# -----------------------------------------------------------------
#  DATA STORAGE
# -----------------------------------------------------------------
$Results      = [System.Collections.Generic.List[PSCustomObject]]::new()
$SpeedResults = [System.Collections.Generic.List[PSCustomObject]]::new()
$StartTime    = Get-Date
$EndTime      = $StartTime.AddMinutes($DurationMinutes)
$Round        = 0

# -----------------------------------------------------------------
#  HELPER FUNCTIONS
# -----------------------------------------------------------------
function Invoke-PingTest {
    param([string]$Target, [int]$Size, [int]$Count)
    $times = @()
    $lost  = 0
    for ($i = 0; $i -lt $Count; $i++) {
        try {
            $ping   = New-Object System.Net.NetworkInformation.Ping
            $opts   = New-Object System.Net.NetworkInformation.PingOptions
            $opts.DontFragment = $true
            $buffer = [byte[]]::new($Size)
            $reply  = $ping.Send($Target, 2000, $buffer, $opts)
            if ($reply.Status -eq "Success") {
                $times += $reply.RoundtripTime
            } else {
                $lost++
            }
        } catch {
            $lost++
        }
    }
    return [PSCustomObject]@{
        Sent     = $Count
        Received = $Count - $lost
        Lost     = $lost
        LossPct  = [Math]::Round(($lost / $Count) * 100, 1)
        AvgMs    = if ($times.Count -gt 0) { [Math]::Round(($times | Measure-Object -Average).Average, 1) } else { $null }
        MinMs    = if ($times.Count -gt 0) { ($times | Measure-Object -Minimum).Minimum } else { $null }
        MaxMs    = if ($times.Count -gt 0) { ($times | Measure-Object -Maximum).Maximum } else { $null }
        Jitter   = if ($times.Count -gt 1) { [Math]::Round(($times | Measure-Object -Maximum).Maximum - ($times | Measure-Object -Minimum).Minimum, 1) } else { 0 }
    }
}

function Invoke-SpeedTest {
    # -- Download --
    $dlMbps = $null
    $dlStatus = "OK"
    try {
        $dlStart = Get-Date
        $resp    = Invoke-WebRequest -Uri $SpeedTestUrl -UseBasicParsing -TimeoutSec 60
        $dlEnd   = Get-Date
        $bytes   = $resp.RawContentLength
        if ($bytes -le 0) { $bytes = $resp.Content.Length }
        $secs    = ($dlEnd - $dlStart).TotalSeconds
        $dlMbps  = [Math]::Round(($bytes * 8) / $secs / 1MB, 2)
    } catch {
        $dlStatus = "FAILED: $($_.Exception.Message)"
    }

    # -- Upload (POST 10MB of zeros to Cloudflare __up endpoint) --
    $ulMbps = $null
    $ulStatus = "OK"
    try {
        $uploadBytes = [byte[]]::new(10 * 1024 * 1024)   # 10 MB payload
        $ulStart = Get-Date
        $ulResp  = Invoke-WebRequest -Uri "https://speed.cloudflare.com/__up" `
                       -Method POST `
                       -Body $uploadBytes `
                       -ContentType "application/octet-stream" `
                       -UseBasicParsing -TimeoutSec 60
        $ulEnd   = Get-Date
        $ulSecs  = ($ulEnd - $ulStart).TotalSeconds
        $ulMbps  = [Math]::Round(($uploadBytes.Length * 8) / $ulSecs / 1MB, 2)
    } catch {
        $ulStatus = "FAILED: $($_.Exception.Message)"
    }

    return [PSCustomObject]@{
        Timestamp    = Get-Date
        DownloadMbps = $dlMbps
        UploadMbps   = $ulMbps
        DlStatus     = $dlStatus
        UlStatus     = $ulStatus
    }
}

# -----------------------------------------------------------------
#  MAIN LOOP
# -----------------------------------------------------------------
Write-Host ""
Write-Host ("  {0,-22} {1,-18} {2,8} {3,8} {4,8} {5,8}" -f "Target","Size","Avg ms","Loss%","Min ms","Max ms") -ForegroundColor Cyan
Write-Host ("  " + ("-" * 80)) -ForegroundColor DarkGray

while ((Get-Date) -lt $EndTime) {
    $Round++
    $RoundTime    = Get-Date
    $MinRemaining = [Math]::Round(($EndTime - (Get-Date)).TotalMinutes, 1)
    $RoundTimeStr = $RoundTime.ToString('HH:mm:ss')

    Write-Host ""
    Write-Host "  [Round $Round | $RoundTimeStr | $MinRemaining min remaining]" -ForegroundColor Yellow

    # Speed test on interval
    if (($Round % $SpeedTestEvery) -eq 1 -or $Round -eq 1) {
        Write-Host "  >> Running speed test..." -ForegroundColor Magenta -NoNewline
        $st = Invoke-SpeedTest
        $SpeedResults.Add($st)
        $dlStr = if ($st.DownloadMbps) { "DL: $($st.DownloadMbps) Mbps" } else { "DL: FAILED" }
        $ulStr = if ($st.UploadMbps)   { "UL: $($st.UploadMbps) Mbps"   } else { "UL: FAILED" }
        Write-Host " $dlStr  |  $ulStr" -ForegroundColor Magenta
    }

    # Ping each target with each packet size
    foreach ($name in $PingTargets.Keys) {
        $ip      = $PingTargets[$name]
        $baseAvg = $null

        foreach ($size in $PacketSizes) {
            $r     = Invoke-PingTest -Target $ip -Size $size -Count $PingCount
            $delta = $null
            if (($null -ne $baseAvg) -and ($null -ne $r.AvgMs)) {
                $delta = [Math]::Round($r.AvgMs - $baseAvg, 1)
            }
            if ($size -eq $PacketSizes[0]) { $baseAvg = $r.AvgMs }

            $row = [PSCustomObject]@{
                Timestamp     = $RoundTime
                Round         = $Round
                Target        = $name
                IP            = $ip
                PacketSize    = $size
                AvgMs         = $r.AvgMs
                MinMs         = $r.MinMs
                MaxMs         = $r.MaxMs
                Jitter        = $r.Jitter
                LossPct       = $r.LossPct
                DeltaFromBase = $delta
            }
            $Results.Add($row)

            $color        = if ($r.LossPct -gt 5 -or $r.AvgMs -gt 150) { "Red" }
                            elseif ($r.LossPct -gt 0 -or $r.AvgMs -gt 80) { "Yellow" }
                            else { "Green" }
            $avgDisplay   = if ($null -ne $r.AvgMs) { "$($r.AvgMs) ms" } else { "TIMEOUT" }
            $deltaDisplay = if (($null -ne $delta) -and ($size -ne $PacketSizes[0])) { "(+$delta)" } else { "" }

            Write-Host ("  {0,-22} {1,-18} {2,8} {3,8} {4,8} {5,8} {6}" -f `
                $name, "${size}B", $avgDisplay, "$($r.LossPct)%", "$($r.MinMs)ms", "$($r.MaxMs)ms", $deltaDisplay) `
                -ForegroundColor $color
        }
    }

    # Wait for next interval
    $elapsed = ((Get-Date) - $RoundTime).TotalSeconds
    $wait    = [Math]::Max(0, $IntervalSecs - $elapsed)
    if ((Get-Date).AddSeconds($wait) -lt $EndTime) {
        Start-Sleep -Seconds ([int]$wait)
    } else {
        break
    }
}

# -----------------------------------------------------------------
#  COMPUTE SUMMARY STATS
# -----------------------------------------------------------------
Write-Host ""
Write-Host "  Test complete. Generating report..." -ForegroundColor Green

$Summary = foreach ($name in $PingTargets.Keys) {
    foreach ($size in $PacketSizes) {
        $subset  = $Results | Where-Object { $_.Target -eq $name -and $_.PacketSize -eq $size -and $null -ne $_.AvgMs }
        $allAvg  = if ($subset) { ($subset.AvgMs  | Measure-Object -Average).Average } else { $null }
        $allMax  = if ($subset) { ($subset.AvgMs  | Measure-Object -Maximum).Maximum } else { $null }
        $allLoss = if ($subset) { ($subset.LossPct | Measure-Object -Average).Average } else { 100 }
        [PSCustomObject]@{
            Target     = $name
            PacketSize = $size
            AvgMs      = if ($null -ne $allAvg)  { [Math]::Round($allAvg,1)  } else { "N/A" }
            PeakMs     = if ($null -ne $allMax)  { [Math]::Round($allMax,1)  } else { "N/A" }
            AvgLoss    = if ($null -ne $allLoss) { [Math]::Round($allLoss,1) } else { "N/A" }
        }
    }
}

# -----------------------------------------------------------------
#  BUILD HTML REPORT
# -----------------------------------------------------------------
$ScriptDir  = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$ReportName = "WiFi-Report_$(Get-Date -Format 'yyyyMMdd_HHmmss').html"
$ReportPath = Join-Path $ScriptDir $ReportName

# Chart data - ping over time (32B packets)
$chartLabelsArr   = @()
$uniqueTimestamps = $Results | Select-Object -ExpandProperty Timestamp -Unique
foreach ($ts in $uniqueTimestamps) {
    $chartLabelsArr += "'$($ts.ToString('HH:mm:ss'))'"
}
$chartLabels = $chartLabelsArr -join ","

$colorMap = @{
    "Cloudflare DNS"      = "54,162,235"
    "Google DNS"          = "255,99,132"
    "Steam (Valve)"       = "75,192,192"
    "Valve CS2 (US East)" = "0,220,180"
    "Level3 Backbone"     = "255,159,64"
    "PSN (Sony)"          = "200,80,255"
    "Battle.net"          = "255,80,80"
    "Microsoft (Bing)"    = "99,255,132"
}

$datasetParts = @()
foreach ($name in $PingTargets.Keys) {
    $vals = @()
    foreach ($ts in $uniqueTimestamps) {
        $r = $Results | Where-Object { $_.Target -eq $name -and $_.PacketSize -eq 32 -and $_.Timestamp -eq $ts } | Select-Object -First 1
        if ($r -and $null -ne $r.AvgMs) { $vals += $r.AvgMs } else { $vals += "null" }
    }
    $c = if ($colorMap.ContainsKey($name)) { $colorMap[$name] } else { "128,128,128" }
    $datasetParts += "{ label: '$name', data: [$($vals -join ',')], borderColor: 'rgba($c,1)', backgroundColor: 'rgba($c,0.1)', tension: 0.3, fill: false }"
}
$chartDatasets = $datasetParts -join ","

# Speed chart data
$speedLabelArr = @()
$speedDlArr    = @()
$speedUlArr    = @()
foreach ($s in $SpeedResults) {
    $speedLabelArr += "'$($s.Timestamp.ToString('HH:mm:ss'))'"
    $speedDlArr    += if ($null -ne $s.DownloadMbps) { $s.DownloadMbps } else { "null" }
    $speedUlArr    += if ($null -ne $s.UploadMbps)   { $s.UploadMbps   } else { "null" }
}
$speedLabels = $speedLabelArr -join ","
$speedDlVals = $speedDlArr    -join ","
$speedUlVals = $speedUlArr    -join ","

# Summary table rows
$summaryRows = ""
foreach ($row in $Summary) {
    $lossNum = 0
    $pingNum = 0
    [double]::TryParse([string]$row.AvgLoss, [ref]$lossNum) | Out-Null
    [double]::TryParse([string]$row.AvgMs,   [ref]$pingNum) | Out-Null
    $lossColor = if ($lossNum -gt 5) { "#ff4444" } elseif ($lossNum -gt 0) { "#ffaa00" } else { "#22cc66" }
    $pingColor = if ($row.AvgMs -eq "N/A") { "inherit" } elseif ($pingNum -gt 150) { "#ff4444" } elseif ($pingNum -gt 80) { "#ffaa00" } else { "#22cc66" }
    $summaryRows += "<tr><td>$($row.Target)</td><td>$($row.PacketSize) B</td><td style='color:$pingColor;font-weight:600'>$($row.AvgMs) ms</td><td>$($row.PeakMs) ms</td><td style='color:$lossColor;font-weight:600'>$($row.AvgLoss)%</td></tr>`n"
}

# Raw data rows (last 200)
$rawRows = ""
foreach ($row in ($Results | Select-Object -Last 200)) {
    $lc = if ($row.LossPct -gt 5) { "#ff4444" } elseif ($row.LossPct -gt 0) { "#ffaa00" } else { "inherit" }
    $rawRows += "<tr><td>$($row.Timestamp.ToString('HH:mm:ss'))</td><td>$($row.Target)</td><td>$($row.PacketSize)</td><td>$($row.AvgMs)</td><td>$($row.MinMs)</td><td>$($row.MaxMs)</td><td>$($row.Jitter)</td><td style='color:$lc'>$($row.LossPct)%</td><td>$($row.DeltaFromBase)</td></tr>`n"
}

# KPI values
$overallAvgPing = "N/A"
$validPings = $Results | Where-Object { $null -ne $_.AvgMs }
if ($validPings) {
    $overallAvgPing = [Math]::Round(($validPings.AvgMs | Measure-Object -Average).Average, 1)
}
$totalPacketLoss = [Math]::Round(($Results.LossPct | Measure-Object -Average).Average, 2)
$avgDownload = "N/A"
$validSpeeds = $SpeedResults | Where-Object { $null -ne $_.DownloadMbps }
if ($validSpeeds) {
    $avgDownload = [Math]::Round(($validSpeeds.DownloadMbps | Measure-Object -Average).Average, 2)
}
$avgUpload = "N/A"
$validUploads = $SpeedResults | Where-Object { $null -ne $_.UploadMbps }
if ($validUploads) {
    $avgUpload = [Math]::Round(($validUploads.UploadMbps | Measure-Object -Average).Average, 2)
}

$startTimeStr  = $StartTime.ToString('dddd, MMMM dd yyyy  HH:mm:ss')
$reportGenTime = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')

# Build full HTML using .NET StringBuilder to avoid here-string encoding issues
$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine('<!DOCTYPE html>')
[void]$sb.AppendLine('<html lang="en">')
[void]$sb.AppendLine('<head>')
[void]$sb.AppendLine('<meta charset="UTF-8">')
[void]$sb.AppendLine('<meta name="viewport" content="width=device-width,initial-scale=1">')
[void]$sb.AppendLine('<title>WiFi Reliability Report</title>')
[void]$sb.AppendLine('<script src="https://cdn.jsdelivr.net/npm/chart.js@4/dist/chart.umd.min.js"></script>')
[void]$sb.AppendLine('<style>')
[void]$sb.AppendLine('*{box-sizing:border-box;margin:0;padding:0}')
[void]$sb.AppendLine('body{font-family:"Segoe UI",system-ui,sans-serif;background:#0f1117;color:#e2e8f0;line-height:1.6}')
[void]$sb.AppendLine('header{background:linear-gradient(135deg,#1a1f2e 0%,#0d1117 100%);padding:2rem;border-bottom:1px solid #2d3748}')
[void]$sb.AppendLine('header h1{font-size:1.8rem;color:#63b3ed;margin-bottom:.25rem}')
[void]$sb.AppendLine('header p{color:#718096;font-size:.9rem}')
[void]$sb.AppendLine('.container{max-width:1400px;margin:0 auto;padding:1.5rem}')
[void]$sb.AppendLine('.kpi-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(200px,1fr));gap:1rem;margin-bottom:2rem}')
[void]$sb.AppendLine('.kpi{background:#1a1f2e;border:1px solid #2d3748;border-radius:12px;padding:1.25rem;text-align:center}')
[void]$sb.AppendLine('.kpi .val{font-size:2rem;font-weight:700;color:#63b3ed}')
[void]$sb.AppendLine('.kpi .lbl{font-size:.8rem;color:#718096;margin-top:.25rem}')
[void]$sb.AppendLine('.card{background:#1a1f2e;border:1px solid #2d3748;border-radius:12px;padding:1.5rem;margin-bottom:1.5rem}')
[void]$sb.AppendLine('.card h2{color:#90cdf4;margin-bottom:1rem;font-size:1.1rem;border-bottom:1px solid #2d3748;padding-bottom:.5rem}')
[void]$sb.AppendLine('.chart-wrap{position:relative;height:320px}')
[void]$sb.AppendLine('table{width:100%;border-collapse:collapse;font-size:.85rem}')
[void]$sb.AppendLine('th{background:#2d3748;color:#a0aec0;padding:.6rem .8rem;text-align:left;font-weight:600;position:sticky;top:0}')
[void]$sb.AppendLine('td{padding:.5rem .8rem;border-bottom:1px solid #1e2535;color:#e2e8f0}')
[void]$sb.AppendLine('tr:hover td{background:#1e2535}')
[void]$sb.AppendLine('.table-scroll{max-height:400px;overflow-y:auto;border-radius:8px;border:1px solid #2d3748}')
[void]$sb.AppendLine('footer{text-align:center;padding:2rem;color:#4a5568;font-size:.8rem}')
[void]$sb.AppendLine('</style>')
[void]$sb.AppendLine('</head>')
[void]$sb.AppendLine('<body>')
[void]$sb.AppendLine('<header>')
[void]$sb.AppendLine('<h1>WiFi Reliability Report</h1>')
[void]$sb.AppendLine("<p>Test started: $startTimeStr &nbsp;|&nbsp; Duration: $DurationMinutes minute(s) &nbsp;|&nbsp; $Round rounds completed</p>")
[void]$sb.AppendLine('</header>')
[void]$sb.AppendLine('<div class="container">')
[void]$sb.AppendLine('<div class="kpi-grid">')
[void]$sb.AppendLine("<div class='kpi'><div class='val'>$overallAvgPing<small style='font-size:1rem'> ms</small></div><div class='lbl'>Overall Avg Ping (32B)</div></div>")
[void]$sb.AppendLine("<div class='kpi'><div class='val'>$totalPacketLoss<small style='font-size:1rem'>%</small></div><div class='lbl'>Avg Packet Loss</div></div>")
[void]$sb.AppendLine("<div class='kpi'><div class='val'>$avgDownload<small style='font-size:1rem'> Mbps</small></div><div class='lbl'>Avg Download Speed</div></div>")
[void]$sb.AppendLine("<div class='kpi'><div class='val'>$avgUpload<small style='font-size:1rem'> Mbps</small></div><div class='lbl'>Avg Upload Speed</div></div>")
[void]$sb.AppendLine("<div class='kpi'><div class='val'>$Round</div><div class='lbl'>Test Rounds</div></div>")
[void]$sb.AppendLine("<div class='kpi'><div class='val'>$($PingTargets.Count)</div><div class='lbl'>Targets Monitored</div></div>")
[void]$sb.AppendLine("<div class='kpi'><div class='val'>$($SpeedResults.Count)</div><div class='lbl'>Speed Tests Run</div></div>")
[void]$sb.AppendLine('</div>')
[void]$sb.AppendLine('<div class="card"><h2>Ping Over Time (32-byte packets)</h2><div class="chart-wrap"><canvas id="pingChart"></canvas></div></div>')
[void]$sb.AppendLine('<div class="card"><h2>Download and Upload Speed Over Time</h2><div class="chart-wrap"><canvas id="speedChart"></canvas></div></div>')
[void]$sb.AppendLine('<div class="card"><h2>Summary by Target and Packet Size</h2><div class="table-scroll"><table>')
[void]$sb.AppendLine('<thead><tr><th>Target</th><th>Packet Size</th><th>Avg Ping</th><th>Peak Ping</th><th>Avg Loss</th></tr></thead>')
[void]$sb.AppendLine("<tbody>$summaryRows</tbody></table></div></div>")
[void]$sb.AppendLine('<div class="card"><h2>Raw Measurements (last 200 entries)</h2><div class="table-scroll"><table>')
[void]$sb.AppendLine('<thead><tr><th>Time</th><th>Target</th><th>Bytes</th><th>Avg ms</th><th>Min ms</th><th>Max ms</th><th>Jitter</th><th>Loss%</th><th>Delta from 32B</th></tr></thead>')
[void]$sb.AppendLine("<tbody>$rawRows</tbody></table></div></div>")
[void]$sb.AppendLine('</div>')
[void]$sb.AppendLine("<footer>Generated by WiFi Reliability Tester | $reportGenTime<br>Copyright 2026 ProishTheIdiot | <a href='https://github.com/thepoopooman652/network-reliability-tester/blob/main/LICENSE'>License (GNU GPLv3)</a></footer>")
[void]$sb.AppendLine('<script>')
[void]$sb.AppendLine("const pingCtx = document.getElementById('pingChart').getContext('2d');")
[void]$sb.AppendLine('new Chart(pingCtx, {')
[void]$sb.AppendLine("  type: 'line',")
[void]$sb.AppendLine('  data: {')
[void]$sb.AppendLine("    labels: [$chartLabels],")
[void]$sb.AppendLine("    datasets: [$chartDatasets]")
[void]$sb.AppendLine('  },')
[void]$sb.AppendLine('  options: {')
[void]$sb.AppendLine('    responsive: true, maintainAspectRatio: false,')
[void]$sb.AppendLine('    interaction: { mode: "index", intersect: false },')
[void]$sb.AppendLine('    plugins: {')
[void]$sb.AppendLine("      legend: { labels: { color: '#a0aec0', usePointStyle: true }, onClick: function(e, legendItem, legend) { const index = legendItem.datasetIndex; const ci = legend.chart; if (ci.isDatasetVisible(index)) { ci.hide(index); legendItem.hidden = true; } else { ci.show(index); legendItem.hidden = false; } } },")
[void]$sb.AppendLine('      tooltip: {')
[void]$sb.AppendLine('        mode: "index", intersect: false,')
[void]$sb.AppendLine("        backgroundColor: '#1a1f2e', borderColor: '#2d3748', borderWidth: 1,")
[void]$sb.AppendLine("        titleColor: '#e2e8f0', bodyColor: '#a0aec0', padding: 10,")
[void]$sb.AppendLine('        itemSort: function(a, b) { return (b.raw === null ? -Infinity : b.raw) - (a.raw === null ? -Infinity : a.raw); },')
[void]$sb.AppendLine('        callbacks: { label: function(ctx) { if (ctx.raw === null) return null; return " " + ctx.dataset.label + ": " + ctx.raw + " ms"; } }')
[void]$sb.AppendLine('      }')
[void]$sb.AppendLine('    },')
[void]$sb.AppendLine('    scales: {')
[void]$sb.AppendLine("      x: { ticks: { color: '#718096' }, grid: { color: '#2d3748' } },")
[void]$sb.AppendLine("      y: { ticks: { color: '#718096' }, grid: { color: '#2d3748' }, title: { display: true, text: 'Round-trip time (ms)', color: '#718096' } }")
[void]$sb.AppendLine('    }')
[void]$sb.AppendLine('  }')
[void]$sb.AppendLine('});')
[void]$sb.AppendLine("const speedCtx = document.getElementById('speedChart').getContext('2d');")
[void]$sb.AppendLine('new Chart(speedCtx, {')
[void]$sb.AppendLine("  type: 'line',")
[void]$sb.AppendLine('  data: {')
[void]$sb.AppendLine("    labels: [$speedLabels],")
[void]$sb.AppendLine('    datasets: [')
[void]$sb.AppendLine('    {')
[void]$sb.AppendLine("      label: 'Download Mbps',")
[void]$sb.AppendLine("      data: [$speedDlVals],")
[void]$sb.AppendLine("      borderColor: 'rgba(104,211,145,1)',")
[void]$sb.AppendLine("      backgroundColor: 'rgba(104,211,145,0.1)',")
[void]$sb.AppendLine('      tension: 0.3, fill: true')
[void]$sb.AppendLine('    },')
[void]$sb.AppendLine('    {')
[void]$sb.AppendLine("      label: 'Upload Mbps',")
[void]$sb.AppendLine("      data: [$speedUlVals],")
[void]$sb.AppendLine("      borderColor: 'rgba(99,179,237,1)',")
[void]$sb.AppendLine("      backgroundColor: 'rgba(99,179,237,0.1)',")
[void]$sb.AppendLine('      tension: 0.3, fill: true')
[void]$sb.AppendLine('    }]')
[void]$sb.AppendLine('  },')
[void]$sb.AppendLine('  options: {')
[void]$sb.AppendLine('    responsive: true, maintainAspectRatio: false,')
[void]$sb.AppendLine('    interaction: { mode: "index", intersect: false },')
[void]$sb.AppendLine('    plugins: {')
[void]$sb.AppendLine("      legend: { labels: { color: '#a0aec0', usePointStyle: true }, onClick: function(e, legendItem, legend) { const index = legendItem.datasetIndex; const ci = legend.chart; if (ci.isDatasetVisible(index)) { ci.hide(index); legendItem.hidden = true; } else { ci.show(index); legendItem.hidden = false; } } },")
[void]$sb.AppendLine('      tooltip: {')
[void]$sb.AppendLine('        mode: "index", intersect: false,')
[void]$sb.AppendLine("        backgroundColor: '#1a1f2e', borderColor: '#2d3748', borderWidth: 1,")
[void]$sb.AppendLine("        titleColor: '#e2e8f0', bodyColor: '#a0aec0', padding: 10,")
[void]$sb.AppendLine('        callbacks: { label: function(ctx) { if (ctx.raw === null) return null; return " " + ctx.dataset.label + ": " + ctx.raw + " Mbps"; } }')
[void]$sb.AppendLine('      }')
[void]$sb.AppendLine('    },')
[void]$sb.AppendLine('    scales: {')
[void]$sb.AppendLine("      x: { ticks: { color: '#718096' }, grid: { color: '#2d3748' } },")
[void]$sb.AppendLine("      y: { ticks: { color: '#718096' }, grid: { color: '#2d3748' }, title: { display: true, text: 'Mbps', color: '#718096' } }")
[void]$sb.AppendLine('    }')
[void]$sb.AppendLine('  }')
[void]$sb.AppendLine('});')
[void]$sb.AppendLine('</script>')
[void]$sb.AppendLine('</body>')
[void]$sb.AppendLine('</html>')

[System.IO.File]::WriteAllText($ReportPath, $sb.ToString(), [System.Text.Encoding]::UTF8)

Write-Host ""
Write-Host "  ----------------------------------------------------------------" -ForegroundColor DarkGray
Write-Host "  Report saved to:" -ForegroundColor Cyan
Write-Host "     $ReportPath" -ForegroundColor White
Write-Host ""
Write-Host "  Quick Summary:" -ForegroundColor Cyan
Write-Host "     Overall Avg Ping : $overallAvgPing ms" -ForegroundColor White
Write-Host "     Avg Packet Loss  : $totalPacketLoss%" -ForegroundColor White
Write-Host "     Avg Download     : $avgDownload Mbps
     Avg Upload       : $avgUpload Mbps" -ForegroundColor White
Write-Host "  ----------------------------------------------------------------" -ForegroundColor DarkGray
Write-Host ""

try { Start-Process $ReportPath } catch {}
