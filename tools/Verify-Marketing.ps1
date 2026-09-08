#requires -Version 7
[CmdletBinding()]
param(
    [string]$RepoRoot = (Split-Path -Parent $PSScriptRoot),
    [Parameter(Mandatory)][string]$Version,
    [string]$Archive
)
$ErrorActionPreference = 'Stop'
$RepoRoot = [IO.Path]::GetFullPath($RepoRoot)
function Assert-Valid([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Get-Digest([string]$Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
$originals = @{
    'direction-01-dimensional-telemetry-shield.png' = '1220c61ea34ed39b2d59b6ef6dda25f13a5f3ef6ad2974c6feb8d04bd9050dc4'
    'direction-02-selected-telemetry-shield.png' = '5bf54f701d1eee0e87def781124b70d27cdbfb0a5667fc2dc37c47e5247a126b'
    'direction-03-telemetry-shield-light.png' = '7b14354379d61adab2aa511fae5a5c842772a82dfeae64dc3b2e51561fb96296'
}
foreach ($name in $originals.Keys) {
    Assert-Valid ((Get-Digest (Join-Path $RepoRoot "assets/brand/concepts/$name")) -eq $originals[$name]) "Original concept changed: $name"
}
Assert-Valid ((Get-Digest (Join-Path $RepoRoot 'assets/brand/disable-adobe-telemetry-selected-master.png')) -eq $originals['direction-02-selected-telemetry-shield.png']) 'Selected master changed'
$links = 0
foreach ($document in 'README.md', 'assets/brand/concepts/README.md') {
    $path = Join-Path $RepoRoot $document
    foreach ($match in [regex]::Matches([IO.File]::ReadAllText($path), '(?:src|href)="([^"]+)"|\]\(([^)]+)\)')) {
        $link = if ($match.Groups[1].Success) { $match.Groups[1].Value } else { $match.Groups[2].Value }
        $link = $link.Split('#')[0]
        if (-not $link -or $link -match '^[a-zA-Z][a-zA-Z0-9+.-]*:') { continue }
        $target = [IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $path) $link))
        Assert-Valid ($target.StartsWith($RepoRoot + '\', [StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $target)) "Missing local document asset: $link"
        $links++
    }
}
$readme = [IO.File]::ReadAllText((Join-Path $RepoRoot 'README.md'))
Assert-Valid ($readme.Contains("version-$Version-") -and $readme.Contains("Disable-AdobeTelemetry-v$Version.zip")) 'README version is stale'
$report = Get-Content -LiteralPath (Join-Path $RepoRoot 'assets/screenshots/capture-report.json') -Raw | ConvertFrom-Json
Assert-Valid ($report.schemaVersion -eq 2 -and $report.version -eq $Version) 'Capture version is stale'
Assert-Valid ($report.offscreen -and $report.representativeData -and $report.protectionCommands -eq $false) 'Capture isolation evidence is incomplete'
$sources = @('Disable-AdobeTelemetry.GUI.ps1', 'Disable-AdobeTelemetry.ps1', 'branding/logo.png', 'branding/logo-small.png', 'branding/logo.ico')
Assert-Valid ($report.sourceFiles.Count -eq 5 -and -not (Compare-Object $sources @($report.sourceFiles.path))) 'Capture source list is incomplete'
foreach ($source in $report.sourceFiles) {
    $path = Join-Path $RepoRoot $source.path
    Assert-Valid ($source.sha256 -eq (Get-Digest $path) -and $source.bytes -eq (Get-Item -LiteralPath $path).Length) "Captured source changed: $($source.path)"
}
$names = @('01-control-center.png', '02-status-check.png', '03-dry-run-preview.png')
Assert-Valid ($report.captures.Count -eq 3 -and -not (Compare-Object $names @($report.captures.file))) 'Expected three unique captures'
Add-Type -AssemblyName System.Drawing
foreach ($capture in $report.captures) {
    $path = Join-Path $RepoRoot "assets/screenshots/$($capture.file)"
    Assert-Valid ($capture.sha256 -eq (Get-Digest $path) -and $capture.bytes -eq (Get-Item -LiteralPath $path).Length) "Capture changed: $($capture.file)"
    $bitmap = [Drawing.Image]::FromFile($path)
    try { Assert-Valid ($bitmap.Width -eq 1600 -and $bitmap.Height -eq 1000 -and $capture.width -eq 1600 -and $capture.height -eq 1000) "Capture dimensions changed: $($capture.file)" }
    finally { $bitmap.Dispose() }
}
if ($Archive) {
    $expected = @{}
    foreach ($name in 'Disable-AdobeTelemetry.ps1', 'Disable-AdobeTelemetry.GUI.ps1', 'README.md', 'LICENSE') { $expected[$name] = Join-Path $RepoRoot $name }
    foreach ($folder in 'Data', 'fleet', 'branding', 'assets') {
        foreach ($file in Get-ChildItem -LiteralPath (Join-Path $RepoRoot $folder) -File -Recurse) { $expected[[IO.Path]::GetRelativePath($RepoRoot, $file.FullName).Replace('\', '/')] = $file.FullName }
    }
    $prefix = "Disable-AdobeTelemetry-v$Version/"
    $zip = [IO.Compression.ZipFile]::OpenRead([IO.Path]::GetFullPath($Archive))
    try {
        $entries = @($zip.Entries | Where-Object { $_.Name })
        $names = @($expected.Keys | ForEach-Object { $prefix + $_ }) + ($prefix + 'release-manifest.json')
        Assert-Valid ($entries.Count -eq $names.Count -and -not (Compare-Object $names @($entries.FullName))) 'ZIP has missing or unexpected files'
        $reader = [IO.StreamReader]::new($zip.GetEntry($prefix + 'release-manifest.json').Open())
        try { $manifest = $reader.ReadToEnd() | ConvertFrom-Json } finally { $reader.Dispose() }
        Assert-Valid ($manifest.version -eq $Version -and $manifest.files.Count -eq $expected.Count -and -not (Compare-Object @($expected.Keys) @($manifest.files.path))) 'Package manifest is incomplete'
        foreach ($file in $manifest.files) {
            $path = $expected[$file.path]
            $hash = Get-Digest $path
            Assert-Valid ($file.sha256 -eq $hash -and $file.bytes -eq (Get-Item -LiteralPath $path).Length) "Manifest differs from source: $($file.path)"
            $stream = $zip.GetEntry($prefix + $file.path).Open()
            try { $actual = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($stream)).ToLowerInvariant() } finally { $stream.Dispose() }
            Assert-Valid ($actual -eq $hash) "ZIP differs from source: $($file.path)"
        }
    } finally { $zip.Dispose() }
}
Write-Output "Verified v$Version, three original studies, three captures, $links local document links$(if ($Archive) { ', and exact ZIP contents' })."
