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
$sourceRoot = Split-Path -Parent $guiScript
$version = ([regex]::Match([System.IO.File]::ReadAllText($guiScript), 'Version\s*:\s*(\d+\.\d+\.\d+)')).Groups[1].Value
if (-not $version) { throw 'The GUI version is missing.' }
$sourceFiles = foreach ($relative in 'Disable-AdobeTelemetry.GUI.ps1', 'Disable-AdobeTelemetry.ps1', 'branding/logo.png', 'branding/logo-small.png', 'branding/logo.ico') {
    $path = Join-Path $sourceRoot $relative
    [ordered]@{ path = $relative; bytes = (Get-Item -LiteralPath $path).Length; sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() }
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
        $startInfo = New-Object System.Diagnostics.ProcessStartInfo
        $startInfo.FileName = $windowsPowerShell
        $startInfo.Arguments = "-NoLogo -NoProfile -Sta -ExecutionPolicy Bypass -File `"$guiScript`""
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $startInfo.EnvironmentVariables['PSModulePath'] = Join-Path (Split-Path -Parent $windowsPowerShell) 'Modules'
        $process = [System.Diagnostics.Process]::Start($startInfo)
        try {
            $stdout = $process.StandardOutput.ReadToEndAsync()
            $stderr = $process.StandardError.ReadToEndAsync()
            if (-not $process.WaitForExit(45000)) { $process.Kill(); $process.WaitForExit(); throw "Capture timed out: $($view.Name)" }
            $output = $stdout.GetAwaiter().GetResult()
            $errorOutput = $stderr.GetAwaiter().GetResult()
            if ($process.ExitCode -ne 0 -or $errorOutput) { throw "Capture failed for $($view.Name): $output $errorOutput" }
        } finally {
            $process.Dispose()
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
foreach ($source in $sourceFiles) {
    if ((Get-FileHash -LiteralPath (Join-Path $sourceRoot $source.path) -Algorithm SHA256).Hash.ToLowerInvariant() -ne $source.sha256) { throw "Source changed during capture: $($source.path)" }
}
$reportJson = [ordered]@{
    schemaVersion = 2
    product = 'Disable Adobe Telemetry'
    version = $version
    renderer = 'WPF RenderTargetBitmap at 125 percent DPI'
    offscreen = $true
    representativeData = $true
    protectionCommands = $false
    sourceFiles = @($sourceFiles)
    captures = $report
} | ConvertTo-Json -Depth 4
$reportJson = ($reportJson -replace "`r`n", "`n") + "`n"
[System.IO.File]::WriteAllText($reportPath, $reportJson, [System.Text.UTF8Encoding]::new($false))

Write-Host "Captured $($views.Count) marketing screenshots to $OutputDirectory"
