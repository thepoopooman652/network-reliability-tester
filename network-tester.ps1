#Requires -Version 5.1
<#
.CLAUDE_NOTCIE
    THIS PROJECT WAS VIBE CODED BY CLAUDE SONNET 4.6 FOR VERSION 1.0
    USE AT YOUR OWN RISK
.VERSION
    Version 1.0.0
.COPYRIGHT
    Copyright 2026 ProishTheIdiot
    GNU General Public License v3 - See LICENSE file
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
