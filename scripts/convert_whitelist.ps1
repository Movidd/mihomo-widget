# convert_whitelist.ps1
# Convert scripts/whitelist (a hand-maintained direct-connection list: mixed formats - bare domain,
# .suffix, localhost, wildcard, IPv4, IPv6) into .tools/mihomo/direct.yaml, the classical rule
# provider consumed by mihomo via RULE-SET,direct,DIRECT.
#
# IPv6 literals/CIDRs become IP-CIDR6 (a bare address gets /128). Note the policy as of 2026-09-14:
# the whitelist no longer carries a `::/0` catch-all, so IPv6 destinations follow the normal rule
# chain (MATCH,Proxy) unless you list a specific prefix here. Do NOT put private IPv6 addresses in
# the whitelist: it ships with the repo and the release bundle.
# Lines starting with # are comments and are skipped.
#
# Called by build_release.bat at packaging time; safe to re-run by hand.
# ASCII only on purpose (PowerShell 5.1 reads .ps1 as ANSI unless a BOM is present, and a BOM in a
# script whose content is plain ASCII is just another thing to get wrong).
$ErrorActionPreference = "Stop"
# This script sits next to the whitelist in scripts/; direct.yaml goes to <repo>\.tools\mihomo\
$scriptsDir = $PSScriptRoot
if ([string]::IsNullOrEmpty($scriptsDir)) { $scriptsDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
$proj = Split-Path -Parent $scriptsDir
$src = Join-Path $scriptsDir "whitelist"
$dst = Join-Path $proj ".tools\mihomo\direct.yaml"

if (-not (Test-Path $src)) { Write-Host "[convert] whitelist not found: $src"; exit 1 }

$out = New-Object System.Collections.Generic.List[string]
$out.Add("payload:")

# Read/write explicitly as UTF-8: PowerShell 5.1's Get-Content uses the system ANSI codepage by
# default, which mangles non-ASCII comments in the whitelist (and mismatched bytes can even swallow
# a newline and glue a comment onto the next entry).
$utf8 = New-Object System.Text.UTF8Encoding($false)   # UTF-8 without BOM
foreach ($raw in [System.IO.File]::ReadAllLines($src, $utf8)) {
  $s = $raw.Trim()
  if ($s -eq "") { continue }
  if ($s.StartsWith("#")) { continue }
  if ($s -eq "localhost") { $out.Add("  - DOMAIN,localhost") }
  elseif ($s -eq "0.0.0.0") { $out.Add("  - IP-CIDR,0.0.0.0/8,no-resolve") }
  elseif ($s -eq "127.0.0.1") { $out.Add("  - IP-CIDR,127.0.0.0/8,no-resolve") }
  elseif ($s -match "^192\.168\.\*$") { $out.Add("  - IP-CIDR,192.168.0.0/16,no-resolve") }
  elseif ($s -match "^\.[A-Za-z0-9\.\-]+$") { $out.Add("  - DOMAIN-SUFFIX," + $s.Substring(1)) }
  elseif ($s -match "^[0-9]+(\.[0-9]+)+$") { $out.Add("  - IP-CIDR,$s,no-resolve") }
  elseif ($s -match "^[0-9A-Fa-f]*:[0-9A-Fa-f:]*(/\d{1,3})?$") {
    if ($s -match "/") { $out.Add("  - IP-CIDR6,$s,no-resolve") }
    else { $out.Add("  - IP-CIDR6,$s/128,no-resolve") }
  }
  else { $out.Add("  - DOMAIN-SUFFIX,$s") }
}

[System.IO.File]::WriteAllText($dst, ([string]::Join("`n", $out) + "`n"), $utf8)   # LF line endings
Write-Host "[convert] wrote $dst ($($out.Count - 1) rules)"
