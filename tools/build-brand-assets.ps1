[CmdletBinding()]
param(
    [switch]$MarketingOnly,
    [string]$OutputDirectory
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$brandDirectory = Join-Path $repoRoot 'assets\brand'
$iconDirectory = Join-Path $brandDirectory 'icons'
$fullMaster = Join-Path $brandDirectory 'telemetry-shield-master.png'
$smallMaster = Join-Path $brandDirectory 'telemetry-shield-small-master.png'
$magick = (Get-Command magick -ErrorAction Stop).Source

foreach ($required in $fullMaster, $smallMaster) {
    if (-not (Test-Path -LiteralPath $required)) {
        throw "Brand master not found: $required"
    }
}

New-Item -ItemType Directory -Force -Path $iconDirectory, (Join-Path $repoRoot 'branding') | Out-Null

$logo = Join-Path $repoRoot 'branding\logo.png'
$smallLogo = Join-Path $repoRoot 'branding\logo-small.png'

if (-not $MarketingOnly) {
& $magick $fullMaster `
    -trim +repage `
    -resize '900x900' `
    -gravity center `
    -background none `
    -extent '1024x1024' `
    -strip `
    -define 'png:color-type=6' `
    $logo
if ($LASTEXITCODE -ne 0) { throw 'Failed to build the primary logo.' }

& $magick $smallMaster `
    -trim +repage `
    -resize '900x900' `
    -gravity center `
    -background none `
    -extent '1024x1024' `
    -strip `
    -define 'png:color-type=6' `
    $smallLogo
if ($LASTEXITCODE -ne 0) { throw 'Failed to build the optical-size logo.' }

$sizes = 16, 24, 32, 48, 64, 96, 128, 256, 512, 1024
foreach ($size in $sizes) {
    $source = if ($size -le 64) { $smallLogo } else { $logo }
    $filter = if ($size -le 24) { 'box' } else { 'Lanczos' }
    $output = Join-Path $iconDirectory "telemetry-shield-$size.png"
    & $magick $source -filter $filter -resize "${size}x${size}" -strip -define 'png:color-type=6' $output
    if ($LASTEXITCODE -ne 0) { throw "Failed to build the $size pixel icon." }
}

$icoInputs = 16, 24, 32, 48, 64, 96, 128, 256 | ForEach-Object {
    Join-Path $iconDirectory "telemetry-shield-$_.png"
}
& $magick @icoInputs (Join-Path $repoRoot 'branding\logo.ico')
if ($LASTEXITCODE -ne 0) { throw 'Failed to build branding\logo.ico.' }
}

if ($OutputDirectory) { $brandDirectory = [System.IO.Path]::GetFullPath($OutputDirectory) }
New-Item -ItemType Directory -Force -Path $brandDirectory | Out-Null
$bannerMark = Join-Path $brandDirectory '.banner-mark.png'
$socialMark = Join-Path $brandDirectory '.social-mark.png'
& $magick $logo -resize '355x355' -strip $bannerMark
& $magick $logo -resize '430x430' -strip $socialMark

$banner = Join-Path $brandDirectory 'disable-adobe-telemetry-readme-banner.png'
& $magick `
    -size '1600x500' 'gradient:#11182d-#080d1b' `
    -fill '#172447' -draw 'circle 1470,30 1110,30' `
    $bannerMark -gravity northwest -geometry '+58+70' -composite `
    -font 'Inter-SemiBold' -fill '#F3F7FF' -pointsize 74 `
    -annotate '+445+125' 'Disable Adobe Telemetry' `
    -font 'Inter-Regular' -fill '#AEBBD2' -pointsize 36 `
    -annotate '+452+248' 'Keep the tools. Cut the tracking.' `
    -fill '#20D7F2' -draw 'roundrectangle 452,323 930,330 3,3' `
    -font 'Inter-Medium' -fill '#7E91B3' -pointsize 20 `
    -annotate '+452+370' '60 DOMAINS   11 PHASES   MANIFEST UNDO   LOCAL CONTROL' `
    -strip `
    $banner
if ($LASTEXITCODE -ne 0) { throw 'Failed to build the README banner.' }

$social = Join-Path $brandDirectory 'disable-adobe-telemetry-social-preview.png'
& $magick `
    -size '1280x640' 'gradient:#11182d-#080d1b' `
    -fill '#172447' -draw 'circle 1160,65 820,65' `
    $socialMark -gravity northwest -geometry '+24+110' -composite `
    -font 'Inter-SemiBold' -fill '#F3F7FF' -pointsize 57 `
    -annotate '+455+205' 'Disable Adobe Telemetry' `
    -font 'Inter-Regular' -fill '#AEBBD2' -pointsize 29 `
    -annotate '+462+325' 'Keep the tools. Cut the tracking.' `
    -fill '#20D7F2' -draw 'roundrectangle 462,385 900,392 3,3' `
    -font 'Inter-Medium' -fill '#7E91B3' -pointsize 18 `
    -annotate '+462+432' 'WINDOWS   MANIFEST UNDO   LOCAL CONTROL   OPEN SOURCE' `
    -strip `
    $social
if ($LASTEXITCODE -ne 0) { throw 'Failed to build the social preview.' }

Remove-Item -LiteralPath $bannerMark, $socialMark -Force
Write-Host 'Disable Adobe Telemetry brand assets built.'
