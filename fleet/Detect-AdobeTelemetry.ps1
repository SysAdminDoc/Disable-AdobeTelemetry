<#
.SYNOPSIS
    Intune Proactive Remediation - detection script for Disable-AdobeTelemetry.

.DESCRIPTION
    Runs the main Disable-AdobeTelemetry.ps1 in -StatusOnly -OutputFormat JSON mode,
    evaluates whether Adobe telemetry protections are in place, and exits with the
    convention Intune expects:
      exit 0 = compliant   (no remediation needed)
      exit 1 = non-compliant (trigger Remediate-AdobeTelemetry.ps1)

    Deploy Disable-AdobeTelemetry.ps1 to a known location on the endpoint (default
    search order below) or pass -ScriptPath. Intune runs detection as SYSTEM, which is
    already elevated, so the main script does not attempt a UAC relaunch.

.PARAMETER ScriptPath
    Full path to Disable-AdobeTelemetry.ps1. If omitted, a default search is used.

.NOTES
    Author : Matt (Maven Imaging)
    Part of Disable-AdobeTelemetry. Pair with Remediate-AdobeTelemetry.ps1.
#>

[CmdletBinding()]
param(
    [string]$ScriptPath
)

$ErrorActionPreference = 'Stop'

function Resolve-MainScript {
    param([string]$Explicit)
    $candidates = @()
    if ($Explicit) { $candidates += $Explicit }
    $candidates += Join-Path $PSScriptRoot 'Disable-AdobeTelemetry.ps1'
    $candidates += Join-Path (Split-Path $PSScriptRoot -Parent) 'Disable-AdobeTelemetry.ps1'
    $candidates += Join-Path $env:ProgramData 'Disable-AdobeTelemetry\Disable-AdobeTelemetry.ps1'
    $candidates += Join-Path $env:ProgramFiles 'Disable-AdobeTelemetry\Disable-AdobeTelemetry.ps1'
    foreach ($c in $candidates) {
        if ($c -and (Test-Path -LiteralPath $c)) { return $c }
    }
    return $null
}

$main = Resolve-MainScript -Explicit $ScriptPath
if (-not $main) {
    Write-Output 'Disable-AdobeTelemetry.ps1 not found; cannot evaluate compliance.'
    exit 1
}

try {
    $raw = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $main -StatusOnly -OutputFormat JSON 2>$null
    $json = ($raw -join "`n").Trim()
    # Be resilient to any leading noise: take from the first '{' onward
    $braceIdx = $json.IndexOf('{')
    if ($braceIdx -gt 0) { $json = $json.Substring($braceIdx) }
    $status = $json | ConvertFrom-Json
} catch {
    Write-Output "Could not read status JSON: $($_.Exception.Message)"
    exit 1
}

# Compliance uses stable signals only (hosts block, firewall rules, service state).
# Live outbound connections are deliberately excluded - they are transient (an Adobe
# app may be open) and would cause remediation churn.
$reasons = @()
if (-not $status.HostsFile.BlockPresent) { $reasons += 'hosts block missing' }
if (-not ($status.Firewall.RuleCount -gt 0)) { $reasons += 'no firewall block rules' }
$unblockedSvc = @($status.Services | Where-Object { -not $_.Blocked })
if ($unblockedSvc.Count -gt 0) { $reasons += "services active: $((($unblockedSvc).Name) -join ',')" }

if ($reasons.Count -eq 0) {
    Write-Output 'Compliant: Adobe telemetry protections are in place.'
    exit 0
} else {
    Write-Output "Non-compliant: $($reasons -join '; ')."
    exit 1
}
