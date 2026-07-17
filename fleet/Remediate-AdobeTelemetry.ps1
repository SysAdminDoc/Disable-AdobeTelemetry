<#
.SYNOPSIS
    Intune Proactive Remediation - remediation script for Disable-AdobeTelemetry.

.DESCRIPTION
    Runs the main Disable-AdobeTelemetry.ps1 to apply Adobe telemetry protections,
    then normalizes the script's exit code (0 / 3010 = success) to the convention
    Intune expects:
      exit 0 = remediation succeeded
      exit 1 = remediation failed

    Intune runs remediation as SYSTEM (already elevated), so the main script does not
    attempt a UAC relaunch. Adjust -Profile / -Skip below for your fleet policy.

.PARAMETER ScriptPath
    Full path to Disable-AdobeTelemetry.ps1. If omitted, a default search is used.

.PARAMETER Profile
    Blocking intensity passed to the main script (Minimal, Standard, Aggressive).

.NOTES
    Author : SysAdminDoc
    Part of Disable-AdobeTelemetry. Pair with Detect-AdobeTelemetry.ps1.
#>

[CmdletBinding()]
param(
    [string]$ScriptPath,
    [ValidateSet('Minimal','Standard','Aggressive')]
    [string]$Profile = 'Standard'
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
    Write-Output 'Disable-AdobeTelemetry.ps1 not found; cannot remediate.'
    exit 1
}

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $main -Profile $Profile
$code = $LASTEXITCODE

# Main script exit codes: 0 = success, 3010 = success + reboot recommended,
# 3 = partial success, 1/2 = failure/invalid.
if ($code -eq 0 -or $code -eq 3010) {
    Write-Output "Remediation succeeded (exit $code)."
    exit 0
} else {
    Write-Output "Remediation reported issues (exit $code)."
    exit 1
}
