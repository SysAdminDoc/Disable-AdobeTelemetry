<#
.SYNOPSIS
    Regenerates Disable-AdobeTelemetry.ps1 inventory sections from Data/Inventories.psd1.
.DESCRIPTION
    Reads the canonical inventory data from Data/Inventories.psd1 and replaces
    the marked sections in Disable-AdobeTelemetry.ps1. This keeps static data
    (domains, processes, services) editable in one place while preserving
    single-file distribution.
.NOTES
    Run after editing Data/Inventories.psd1 to sync the main script.
#>

param(
    [switch]$Verify
)

$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $PSCommandPath
$dataFile = Join-Path $scriptDir 'Data\Inventories.psd1'
$mainScript = Join-Path $scriptDir 'Disable-AdobeTelemetry.ps1'

if (-not (Test-Path $dataFile)) {
    Write-Error "Data file not found: $dataFile"
    exit 1
}
if (-not (Test-Path $mainScript)) {
    Write-Error "Main script not found: $mainScript"
    exit 1
}

$data = Import-PowerShellDataFile $dataFile
$content = Get-Content $mainScript -Raw

function Format-StringArray {
    param([string[]]$Items, [string]$VarName, [string]$Comment)
    $lines = @()
    if ($Comment) { $lines += $Comment }
    $lines += "`$$VarName = @("
    foreach ($item in $Items) {
        $lines += "    '$item'"
    }
    $lines += ')'
    return $lines -join "`n"
}

function Format-HashtableBlock {
    param([hashtable]$Items, [string]$VarName)
    $lines = @()
    $lines += "`$$VarName = @{"
    $maxKeyLen = ($Items.Keys | ForEach-Object { $_.Length } | Measure-Object -Maximum).Maximum
    foreach ($key in ($Items.Keys | Sort-Object)) {
        $pad = ' ' * ($maxKeyLen - $key.Length + 1)
        $lines += "    '$key'$pad= '$($Items[$key])'"
    }
    $lines += '}'
    return $lines -join "`n"
}

# Generate Processes section
$processBlock = @(
    (Format-StringArray -Items $data.Processes -VarName 'AdobeProcesses')
) -join "`n"
$processBlock = $processBlock -replace "'node'", "'node'  # Adobe CEF/Node helpers - filtered by path below"

# Generate Paths section
$pathsBlock = @(
    "`$GrowthSDKRelPath = '$($data.GrowthSDKRelPath)'"
    ''
    (Format-StringArray -Items $data.AdditionalPaths -VarName 'AdditionalPaths')
    ''
    (Format-HashtableBlock -Items $data.AppExecutables -VarName 'AdobeAppExecutables')
) -join "`n"

# Generate Services section
$svcLines = @()
$svcComments = @{
    'AGSService'              = '# Adobe Genuine Software Integrity'
    'AGMService'              = '# Adobe Genuine Monitor'
    'AdobeARMservice'         = '# Adobe Acrobat Update Service'
    'AdobeUpdateService'      = '# Adobe Update Service'
}
$svcLines += '$Services = @('
foreach ($svc in $data.Services) {
    $comment = $svcComments[$svc]
    if ($comment) {
        $pad = ' ' * (30 - $svc.Length)
        $svcLines += "    '$svc'$pad$comment"
    } else {
        $svcLines += "    '$svc'"
    }
}
$svcLines += ')'
$servicesBlock = $svcLines -join "`n"

# Generate Domains section
$domainsBlock = @(
    (Format-StringArray -Items $data.DomainsMinimal -VarName 'TelemetryDomainsMinimal')
    ('$TelemetryDomainsStandard = $TelemetryDomainsMinimal + @(')
    ($data.DomainsStandardAdditions | ForEach-Object { "    '$_'" }) -join "`n"
    ')'
    ('$TelemetryDomainsAggressive = $TelemetryDomainsStandard + @(')
    ($data.DomainsAggressiveAdditions | ForEach-Object { "    '$_'" }) -join "`n"
    ')'
    ''
    '$TelemetryDomains = switch ($Profile) {'
    "    'Minimal'    { `$TelemetryDomainsMinimal }"
    "    'Aggressive' { `$TelemetryDomainsAggressive }"
    "    default      { `$TelemetryDomainsStandard }"
    '}'
    ''
    (Format-StringArray -Items $data.DomainSafelist -VarName 'script:DomainSafelist')
) -join "`n"

# Replace marked sections
$sections = @{
    'Processes' = $processBlock
    'Paths'     = $pathsBlock
    'Services'  = $servicesBlock
    'Domains'   = $domainsBlock
}

$updated = $content
foreach ($section in $sections.Keys) {
    $pattern = "(?s)# BEGIN INVENTORY:$section\r?\n.*?# END INVENTORY:$section"
    $replacement = "# BEGIN INVENTORY:$section`n$($sections[$section])`n# END INVENTORY:$section"
    if ($updated -notmatch "# BEGIN INVENTORY:$section") {
        Write-Error "Marker not found: # BEGIN INVENTORY:$section"
        exit 1
    }
    $updated = [regex]::Replace($updated, $pattern, $replacement)
}

# Normalize to CRLF so generated LF-joined blocks match the repository's
# line-ending convention (prevents a spurious out-of-sync report on CRLF checkouts).
$updated = ($updated -replace "`r`n", "`n") -replace "`n", "`r`n"

if ($Verify) {
    if ($updated -eq $content) {
        Write-Host 'Inventories are in sync.' -ForegroundColor Green
        exit 0
    } else {
        Write-Host 'Inventories are out of sync. Run Build.ps1 to regenerate.' -ForegroundColor Red
        exit 1
    }
}

Set-Content -Path $mainScript -Value $updated -Encoding UTF8 -NoNewline
Write-Host "Regenerated inventory sections in $mainScript" -ForegroundColor Green
