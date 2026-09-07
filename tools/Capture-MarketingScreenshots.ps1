[CmdletBinding()]
param(
    [string]$OutputDirectory = (Join-Path (Split-Path -Parent $PSScriptRoot) 'assets\screenshots'),
    [string]$GuiScript = (Join-Path (Split-Path -Parent $PSScriptRoot) 'Disable-AdobeTelemetry.GUI.ps1')
)

$ErrorActionPreference = 'Stop'
$guiScript = [System.IO.Path]::GetFullPath($GuiScript)
if (-not (Test-Path -LiteralPath $guiScript)) {
    throw "GUI script not found: $guiScript"
}
$windowsPowerShell = Join-Path $PSHOME 'powershell.exe'
if (-not (Test-Path -LiteralPath $windowsPowerShell)) {
    $windowsPowerShell = (Get-Command powershell.exe -ErrorAction Stop).Source
}

$views = @(
    [pscustomobject]@{ Name = 'overview'; File = '01-control-center.png' }
    [pscustomobject]@{ Name = 'status'; File = '02-status-check.png' }
    [pscustomobject]@{ Name = 'dry-run'; File = '03-dry-run-preview.png' }
)

New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$previousCapture = $env:DISABLE_ADOBE_MARKETING_CAPTURE
$previousView = $env:DISABLE_ADOBE_MARKETING_VIEW
$previousOutput = $env:DISABLE_ADOBE_MARKETING_OUTPUT
$report = @()

try {
    $env:DISABLE_ADOBE_MARKETING_CAPTURE = '1'
    foreach ($view in $views) {
        $outputPath = Join-Path $OutputDirectory $view.File
        if (Test-Path -LiteralPath $outputPath) {
            Remove-Item -LiteralPath $outputPath -Force
        }

        $env:DISABLE_ADOBE_MARKETING_VIEW = $view.Name
        $env:DISABLE_ADOBE_MARKETING_OUTPUT = $outputPath
        & $windowsPowerShell -NoLogo -NoProfile -Sta -ExecutionPolicy Bypass -File $guiScript
        if ($LASTEXITCODE -ne 0) {
            throw "Capture failed for $($view.Name) with exit code $LASTEXITCODE."
        }
        if (-not (Test-Path -LiteralPath $outputPath)) {
            throw "Capture did not produce $outputPath."
        }

        Add-Type -AssemblyName System.Drawing
        $image = [System.Drawing.Image]::FromFile($outputPath)
        try {
            if ($image.Width -ne 1600 -or $image.Height -ne 1000) {
                throw "Unexpected capture size for $($view.Name): $($image.Width)x$($image.Height)."
            }
            $width = $image.Width
            $height = $image.Height
        } finally {
            $image.Dispose()
        }

        $file = Get-Item -LiteralPath $outputPath
        $report += [ordered]@{
            view = $view.Name
            file = $view.File
            width = $width
            height = $height
            bytes = $file.Length
            sha256 = (Get-FileHash -LiteralPath $outputPath -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    }
} finally {
    $env:DISABLE_ADOBE_MARKETING_CAPTURE = $previousCapture
    $env:DISABLE_ADOBE_MARKETING_VIEW = $previousView
    $env:DISABLE_ADOBE_MARKETING_OUTPUT = $previousOutput
}

$reportPath = Join-Path $OutputDirectory 'capture-report.json'
$reportJson = [ordered]@{
    product = 'Disable Adobe Telemetry'
    version = '2.5.2'
    renderer = 'WPF RenderTargetBitmap at 125 percent DPI'
    captures = $report
} | ConvertTo-Json -Depth 4
$reportJson = ($reportJson -replace "`r`n", "`n") + "`n"
[System.IO.File]::WriteAllText($reportPath, $reportJson, [System.Text.UTF8Encoding]::new($false))

Write-Host "Captured $($views.Count) marketing screenshots to $OutputDirectory"
