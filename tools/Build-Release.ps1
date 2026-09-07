[CmdletBinding()]
param(
    [string]$Version = '2.5.2'
)

$ErrorActionPreference = 'Stop'
$repoRoot = [System.IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$distRoot = [System.IO.Path]::GetFullPath((Join-Path $repoRoot 'dist'))
if (-not $distRoot.StartsWith($repoRoot + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to clean a release directory outside the repository: $distRoot"
}

$mainScript = Join-Path $repoRoot 'Disable-AdobeTelemetry.ps1'
$guiScript = Join-Path $repoRoot 'Disable-AdobeTelemetry.GUI.ps1'
$readme = Join-Path $repoRoot 'README.md'
$mainContent = Get-Content -LiteralPath $mainScript -Raw
$guiContent = Get-Content -LiteralPath $guiScript -Raw
$readmeContent = Get-Content -LiteralPath $readme -Raw
if ($mainContent -notmatch [regex]::Escape("`$script:DisplayVersion = 'v$Version'")) {
    throw "Main script version does not match $Version."
}
if ($guiContent -notmatch [regex]::Escape(('Title="Disable Adobe Telemetry v{0}"' -f $Version))) {
    throw "GUI title version does not match $Version."
}
if ($readmeContent -notmatch [regex]::Escape("version-$Version-")) {
    throw "README version badge does not match $Version."
}

& pwsh -NoLogo -NoProfile -File (Join-Path $repoRoot 'Build.ps1') -Verify
if ($LASTEXITCODE -ne 0) { throw 'Inventory verification failed.' }

Import-Module Pester -MinimumVersion 5.0 -ErrorAction Stop
$pester = Invoke-Pester -Path (Join-Path $repoRoot 'Tests') -Output Normal -PassThru
if ($pester.FailedCount -gt 0) {
    throw "$($pester.FailedCount) Pester test(s) failed."
}

Import-Module PSScriptAnalyzer -ErrorAction Stop
$analysisPaths = @(
    $mainScript,
    $guiScript,
    (Join-Path $repoRoot 'Build.ps1'),
    (Join-Path $repoRoot 'tools\build-brand-assets.ps1'),
    (Join-Path $repoRoot 'tools\Capture-MarketingScreenshots.ps1'),
    $PSCommandPath
)
$analysis = foreach ($analysisPath in $analysisPaths) {
    Invoke-ScriptAnalyzer -Path $analysisPath `
        -Settings (Join-Path $repoRoot 'PSScriptAnalyzerSettings.psd1') -Severity Warning, Error
}
if ($analysis.Count -gt 0) {
    $analysis | Format-Table RuleName, Severity, ScriptName, Line, Message -AutoSize | Out-String | Write-Host
    throw "PSScriptAnalyzer reported $($analysis.Count) warning or error finding(s)."
}

$windowsPowerShell = (Get-Command powershell.exe -ErrorAction Stop).Source
foreach ($parsePath in $analysisPaths) {
    $quotedPath = $parsePath.Replace("'", "''")
    $parserCommand = "`$errors = `$null; [System.Management.Automation.Language.Parser]::ParseFile('$quotedPath', [ref]`$null, [ref]`$errors) | Out-Null; if (`$errors.Count) { `$errors | Format-List | Out-String | Write-Error; exit 1 }"
    & $windowsPowerShell -NoLogo -NoProfile -Command $parserCommand
    if ($LASTEXITCODE -ne 0) {
        throw "Windows PowerShell 5.1 syntax validation failed for $parsePath."
    }
}

if (Test-Path -LiteralPath $distRoot) {
    Remove-Item -LiteralPath $distRoot -Recurse -Force
}
$stageRoot = Join-Path $distRoot "Disable-AdobeTelemetry-v$Version"
New-Item -ItemType Directory -Path $stageRoot -Force | Out-Null

$rootFiles = @(
    'Disable-AdobeTelemetry.ps1',
    'Disable-AdobeTelemetry.GUI.ps1',
    'README.md',
    'LICENSE'
)
foreach ($file in $rootFiles) {
    Copy-Item -LiteralPath (Join-Path $repoRoot $file) -Destination (Join-Path $stageRoot $file)
}
foreach ($directory in 'Data', 'fleet', 'branding', 'assets') {
    Copy-Item -LiteralPath (Join-Path $repoRoot $directory) -Destination (Join-Path $stageRoot $directory) -Recurse
}

$signingCertificate = Get-ChildItem Cert:\CurrentUser\My -CodeSigningCert -ErrorAction SilentlyContinue |
    Where-Object { $_.NotAfter -gt (Get-Date) } |
    Sort-Object NotAfter -Descending |
    Select-Object -First 1
$signed = $false
if ($signingCertificate) {
    foreach ($scriptFile in 'Disable-AdobeTelemetry.ps1', 'Disable-AdobeTelemetry.GUI.ps1') {
        $signature = Set-AuthenticodeSignature -FilePath (Join-Path $stageRoot $scriptFile) `
            -Certificate $signingCertificate -TimestampServer 'http://timestamp.digicert.com'
        if ($signature.Status -ne 'Valid') {
            throw "Authenticode signing failed for ${scriptFile}: $($signature.StatusMessage)"
        }
    }
    $signed = $true
}

$includedFiles = Get-ChildItem -LiteralPath $stageRoot -File -Recurse | Sort-Object FullName | ForEach-Object {
    [ordered]@{
        path = [System.IO.Path]::GetRelativePath($stageRoot, $_.FullName).Replace('\', '/')
        bytes = $_.Length
        sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}
$packageManifest = [ordered]@{
    product = 'Disable Adobe Telemetry'
    version = $Version
    authenticodeSigned = $signed
    files = $includedFiles
}
$packageManifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $stageRoot 'release-manifest.json') -Encoding UTF8

$zipName = "Disable-AdobeTelemetry-v$Version.zip"
$zipPath = Join-Path $distRoot $zipName
Compress-Archive -LiteralPath $stageRoot -DestinationPath $zipPath -CompressionLevel Optimal
$zip = Get-Item -LiteralPath $zipPath
$zipHash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
"$zipHash  $zipName" | Set-Content -LiteralPath (Join-Path $distRoot 'SHA256SUMS.txt') -Encoding ascii

[ordered]@{
    product = 'Disable Adobe Telemetry'
    version = $Version
    artifact = $zipName
    bytes = $zip.Length
    sha256 = $zipHash
    authenticodeSigned = $signed
    signingNote = if ($signed) { 'Packaged PowerShell entry points are Authenticode-signed.' } else { 'No usable local code-signing certificate was available.' }
    includedFileCount = @($includedFiles).Count + 1
} | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath (Join-Path $distRoot 'release-manifest.json') -Encoding UTF8

Write-Host "Built $zipPath"
Write-Host "SHA256 $zipHash"
