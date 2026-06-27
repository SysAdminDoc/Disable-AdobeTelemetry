<#
.SYNOPSIS
    Disable-AdobeTelemetry.ps1 - Comprehensive Adobe telemetry and GrowthSDK removal tool.

.DESCRIPTION
    Kills Adobe GrowthSDK, background telemetry services, scheduled tasks, and
    in-app marketing/analytics frameworks across all user profiles.

    Actions performed:
      1. Terminates Adobe background processes
      2. Removes GrowthSDK directories and plants blocker files
      3. Disables Adobe telemetry scheduled tasks
      4. Disables Adobe telemetry/updater services
      5. Sets registry policies to disable usage data collection
      6. Blocks Adobe telemetry domains via Windows Firewall
      7. Blocks domains via hosts file
      8. Disables Adobe Acrobat telemetry via registry
      9. Permanently neutralizes CCXProcess.exe
     10. Firewalls AdobeIPCBroker.exe (outbound only)
     11. Disables Adobe startup/run entries

.PARAMETER Undo
    Reverses ALL changes made by this script.

.PARAMETER StatusOnly
    Shows current state of all telemetry components without making changes.

.PARAMETER DryRun
    Reports all planned actions without writing any changes.

.PARAMETER Only
    Comma-separated list of phases to run. Valid phases:
    Kill, GrowthSDK, CCXProcess, IPCBroker, Tasks, Services, Registry, Firewall, Hosts, Acrobat, Startup

.PARAMETER Skip
    Comma-separated list of phases to skip. Same valid phase names as -Only.

.PARAMETER Profile
    Blocking intensity: Minimal (telemetry domains + process kill only),
    Standard (default - full protection), Aggressive (adds font/library domains).
    User -Only/-Skip flags override profile defaults.

.PARAMETER Launcher
    Non-destructive mode: kills telemetry processes, launches the specified Adobe
    app, waits for it to exit, then re-kills telemetry. No permanent system changes.
    Accepts app names: Photoshop, Illustrator, Premiere, AfterEffects, InDesign, etc.

.PARAMETER OutputFormat
    Output format for -StatusOnly: Text (default, colored console output) or JSON
    (machine-readable structured output for fleet management tools).

.NOTES
    Author  : Matt (Maven Imaging)
    Version : 2.3.0
    Date    : 2026-06-27

    Exit codes:
      0    = Success (no reboot needed) or dry run completed
      1    = Fatal error (invalid arguments, missing executable)
      2    = Invalid arguments
      3    = Partial success (some phases encountered errors)
      3010 = Success, reboot recommended (SCCM/Intune convention)
#>

param(
    [switch]$Undo,
    [switch]$StatusOnly,
    [switch]$DryRun,
    [string[]]$Only,
    [string[]]$Skip,
    [ValidateSet('Minimal','Standard','Aggressive')]
    [string]$Profile = 'Standard',
    [string]$Launcher,
    [string]$ExportProfile,
    [string]$ImportProfile,
    [switch]$InstallWatchdog,
    [switch]$RemoveWatchdog,
    [switch]$ConnectionReport,
    [switch]$WfpTrace,
    [ValidateRange(1,1440)]
    [int]$TraceMinutes = 10,
    [string]$TraceOutput,
    [switch]$PlumbingTest,
    [string]$PlumbingApp = 'Premiere',
    [ValidateRange(1,1440)]
    [int]$PlumbingMinutes = 10,
    [switch]$Verbose,
    [ValidateSet('Text','JSON')]
    [string]$OutputFormat = 'Text'
)

# ── Auto-Elevate ─────────────────────────────────────────────────────────────
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)
if (-not $isAdmin) {
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    if ($Undo)       { $argList += '-Undo' }
    if ($StatusOnly) { $argList += '-StatusOnly' }
    if ($DryRun)     { $argList += '-DryRun' }
    if ($Only)       { $argList += '-Only'; $argList += ($Only -join ',') }
    if ($Skip)       { $argList += '-Skip'; $argList += ($Skip -join ',') }
    if ($Profile -ne 'Standard') { $argList += '-Profile'; $argList += $Profile }
    if ($Launcher) { $argList += '-Launcher'; $argList += "`"$Launcher`"" }
    if ($ExportProfile) { $argList += '-ExportProfile'; $argList += "`"$ExportProfile`"" }
    if ($ImportProfile) { $argList += '-ImportProfile'; $argList += "`"$ImportProfile`"" }
    if ($InstallWatchdog) { $argList += '-InstallWatchdog' }
    if ($RemoveWatchdog)  { $argList += '-RemoveWatchdog' }
    if ($ConnectionReport) { $argList += '-ConnectionReport' }
    if ($WfpTrace) { $argList += '-WfpTrace'; $argList += '-TraceMinutes'; $argList += $TraceMinutes }
    if ($TraceOutput) { $argList += '-TraceOutput'; $argList += "`"$TraceOutput`"" }
    if ($PlumbingTest) { $argList += '-PlumbingTest'; $argList += '-PlumbingApp'; $argList += "`"$PlumbingApp`""; $argList += '-PlumbingMinutes'; $argList += $PlumbingMinutes }
    if ($Verbose) { $argList += '-Verbose' }
    if ($OutputFormat -ne 'Text') { $argList += '-OutputFormat'; $argList += $OutputFormat }
    Start-Process powershell.exe -Verb RunAs -ArgumentList $argList
    exit 0
}

# ── Config ──────────────────────────────────────────────────────────────────────

$ErrorActionPreference = 'Continue'

$script:DisplayVersion = 'v2.3.0'
$script:Version = $script:DisplayVersion.TrimStart('v')
$script:LogFile = Join-Path $env:TEMP 'Disable-AdobeTelemetry.log'
$script:LogDir = Join-Path $env:APPDATA 'Disable-AdobeTelemetry\logs'
$script:JsonLogFile = Join-Path $script:LogDir ("Disable-AdobeTelemetry-{0}.jsonl" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))

# ── Undo Manifest ────────────────────────────────────────────────────────────
# JSON manifest recording every action so -Undo can be fully deterministic
$script:ManifestDir = Join-Path $env:APPDATA 'Disable-AdobeTelemetry'
$script:ManifestPath = Join-Path $script:ManifestDir 'undo-manifest.json'
$script:ManifestActions = @()

function Initialize-AppDataDirectory {
    if (-not (Test-Path $script:ManifestDir)) {
        New-Item -Path $script:ManifestDir -ItemType Directory -Force | Out-Null
    }
    if (-not (Test-Path $script:LogDir)) {
        New-Item -Path $script:LogDir -ItemType Directory -Force | Out-Null
    }
}

function Add-ManifestAction {
    param(
        [string]$Phase,
        [string]$Action,       # e.g. 'RenameFile', 'SetRegistry', 'AddFirewallRule', etc.
        [hashtable]$Details    # action-specific details for undo
    )
    if ($DryRun) { return }
    $script:ManifestActions += @{
        Phase     = $Phase
        Action    = $Action
        Timestamp = (Get-Date -Format 'o')
        Details   = $Details
    }
}

function Save-Manifest {
    if ($DryRun) { return }
    if ($script:ManifestActions.Count -eq 0) { return }
    Initialize-AppDataDirectory
    $manifest = @{
        Version       = $script:Version
        SchemaVersion = 2
        CreatedAt     = (Get-Date -Format 'o')
        Profile       = $Profile
        Only          = $Only
        Skip          = $Skip
        Actions       = $script:ManifestActions
    }
    $manifest | ConvertTo-Json -Depth 5 | Set-Content -Path $script:ManifestPath -Force -Encoding UTF8
    Write-Status "Undo manifest saved to $($script:ManifestPath)" -Type Info
}

function Get-ManifestDetail {
    param(
        [Parameter(Mandatory=$true)]$Details,
        [Parameter(Mandatory=$true)][string]$Name
    )
    if ($Details -is [hashtable]) {
        return $Details[$Name]
    }
    $property = $Details.PSObject.Properties[$Name]
    if ($property) {
        return $property.Value
    }
    return $null
}

# ── Phase Resolution ──────────────────────────────────────────────────────────
# Valid phase names for -Only / -Skip filtering
$script:ValidPhases = @(
    'Kill', 'GrowthSDK', 'CCXProcess', 'IPCBroker',
    'Tasks', 'Services', 'Registry', 'Firewall',
    'Hosts', 'Acrobat', 'Startup'
)

# Validate -Only / -Skip values
foreach ($p in ($Only + $Skip)) {
    if ($p -and $script:ValidPhases -notcontains $p) {
        Write-Host "  [!!] Invalid phase name: '$p'" -ForegroundColor Red
        Write-Host "       Valid phases: $($script:ValidPhases -join ', ')" -ForegroundColor Yellow
        exit 2
    }
}

# Apply profile-based phase defaults (user -Only/-Skip overrides take precedence)
if (-not $Only -and -not $Skip -and $Profile -eq 'Minimal') {
    $Skip = @('GrowthSDK', 'CCXProcess', 'Services', 'Tasks', 'Registry', 'Acrobat', 'Startup')
}

function Test-PhaseEnabled {
    param([string]$Phase)
    if ($Only -and $Only.Count -gt 0) {
        return ($Only -contains $Phase)
    }
    if ($Skip -and $Skip.Count -gt 0) {
        return ($Skip -notcontains $Phase)
    }
    return $true
}

# ── Summary Counters ──────────────────────────────────────────────────────────
$script:Counters = @{
    ProcessesKilled   = 0
    GrowthSDKBlocked  = 0
    TasksDisabled     = 0
    ServicesDisabled  = 0
    RegistryKeysSet   = 0
    FirewallRulesAdded = 0
    FirewallIPsBlocked = 0
    DomainsBlocked    = 0
    StartupDisabled   = 0
    ExesNeutralized   = 0
    ConnectionsBefore = -1
    ConnectionsAfter  = -1
    Errors            = 0
}

# Adobe background processes to kill
$AdobeProcesses = @(
    'CCXProcess'
    'CCLibrary'
    'AdobeIPCBroker'
    'Adobe Desktop Service'
    'AdobeNotificationClient'
    'AdobeUpdateService'
    'armsvc'
    'AGSService'
    'AGMService'
    'CoreSync'
    'LogTransport2'
    'AdobeCollabSync'
    'CRWindowsClientService'
    'CRLogTransport'
    'acrotray'
    'AcroTray'
    'Adobe Acrobat'
    'Acrobat'
    'AcroCEF'
    'RdrCEF'
    'AdobeARM'
    'AdobeGCClient'
    'Adobe Genuine Service'
    'Adobe Genuine Helper'
    'Adobe Crash Processor'
    'AdobeCRDaemon'
    'Adobe CEF Helper'
    'Creative Cloud'
    'Creative Cloud Helper'
    'Adobe Creative Cloud'
    'AAM Updates Notifier'
    'Adobe Substance 3D Painter'
    'Adobe Substance 3D Designer'
    'Adobe Substance 3D Sampler'
    'Adobe Substance 3D Stager'
    'Adobe Substance 3D Modeler'
    'Adobe Dimension'
    'node'  # Adobe CEF/Node helpers - filtered by path below
)

# GrowthSDK relative path under each user's LocalLow
$GrowthSDKRelPath = 'Adobe\GrowthSDK'

# Additional Adobe telemetry/cache directories to neutralize
$AdditionalPaths = @(
    'Adobe\OOBE\opm.db'
    'Adobe\OOBE\PDApp\CCM\Telemetry'
)

$AdobeAppExecutables = @{
    'Photoshop'        = 'Photoshop.exe'
    'Illustrator'      = 'Illustrator.exe'
    'Premiere'         = 'Adobe Premiere Pro.exe'
    'PremierePro'      = 'Adobe Premiere Pro.exe'
    'AfterEffects'     = 'AfterFX.exe'
    'InDesign'         = 'InDesign.exe'
    'Lightroom'        = 'Lightroom.exe'
    'LightroomClassic' = 'Lightroom.exe'
    'Audition'         = 'Adobe Audition.exe'
    'Animate'          = 'Animate.exe'
    'MediaEncoder'     = 'Adobe Media Encoder.exe'
    'SubstancePainter' = 'Adobe Substance 3D Painter.exe'
    'SubstanceDesigner'= 'Adobe Substance 3D Designer.exe'
    'SubstanceSampler' = 'Adobe Substance 3D Sampler.exe'
    'SubstanceStager'  = 'Adobe Substance 3D Stager.exe'
    'Dimension'        = 'Adobe Dimension.exe'
    'Acrobat'          = 'Acrobat.exe'
    'Reader'           = 'AcroRd32.exe'
}

# Services to disable
$Services = @(
    'AGSService'           # Adobe Genuine Software Integrity
    'AGMService'           # Adobe Genuine Monitor
    'AdobeARMservice'      # Adobe Acrobat Update Service
    'AdobeUpdateService'   # Adobe Update Service
    'AdobeFlashPlayerUpdateSvc'
    'CCXProcess'
)

# Adobe telemetry / analytics domains
# Telemetry domains - tiered by profile
$TelemetryDomainsMinimal = @(
    'cc-api-data.adobe.io'
    'ada.adobe.io'
    'assets.adobedtm.com'
    'sstats.adobe.com'
    'stats.adobe.com'
    'ic.adobe.io'
    'p13n.adobe.io'
    'fp.adobestats.io'
    'r.openx.net'
    'dpm.demdex.net'
    'adobe.demdex.net'
    'adobedc.demdex.net'
    'bam.nr-data.net'
    'fls.doubleclick.net'
    'hbrcv.adobe.com'
    'crs.cr.adobe.com'
    'crlog-crcn.adobe.com'
    'aepxlg.adobe.com'
    'utut-service.adobe.com'
    'senseimds.adobe.io'
    'cai-splunk-proxy.adobe.io'
    'detect-ccd.creativecloud.adobe.com'
)
$TelemetryDomainsStandard = $TelemetryDomainsMinimal + @(
    'notify.adobe.io'
    'prod.adobegc.com'
    'geo2.adobe.com'
    'pv2.adobe.com'
    'lcs-cops.adobe.io'
    'lcs-robs.adobe.io'
    'lcs-ulecs.adobe.io'
    'cc-cdn.adobe.com'
    'platform.adobe.io'
    'adobeid-na1.services.adobe.com'
    'na1r.services.adobe.com'
    'hlrc.adobegenuine.com'
    'genuine.adobe.com'
    'prod.adobegenuine.com'
    'prod-rel-ffc-ccm.oobesaas.adobe.com'
    'odin.adobe.com'
    'armmf.adobe.com'
    'client.messaging.adobe.com'
    'server.messaging.adobe.com'
    'ui.messaging.adobe.com'
)
$TelemetryDomainsAggressive = $TelemetryDomainsStandard + @(
    'use.typekit.net'
    'p.typekit.net'
    'data.typekit.net'
    'cctypekit.adobe.io'
    'cclibraries-defaults-cdn.adobe.com'
    'services.adobe.com'
)

# Select domain list based on profile
$TelemetryDomains = switch ($Profile) {
    'Minimal'    { $TelemetryDomainsMinimal }
    'Aggressive' { $TelemetryDomainsAggressive }
    default      { $TelemetryDomainsStandard }
}

# Domains that must never be blocked — required for authentication and downloads
$script:DomainSafelist = @(
    'ims-na1.adobelogin.com'
    'auth.services.adobe.com'
    'na1e-acc.services.adobe.com'
    'ccmdls.adobe.com'
    'ardownload2.adobe.com'
    'cdn-ffc.oobesaas.adobe.com'
    'cc-api-data-us.adobe.io'
    'fonts.adobe.com'
    'stock.adobe.com'
    'www.adobe.com'
)

# Optionally merge upstream domains from a-dove-is-dumb community list
$script:UpstreamUrl = 'https://a.dove.isdumb.one/list.txt'
function Merge-UpstreamDomains {
    try {
        $raw = (Invoke-WebRequest -Uri $script:UpstreamUrl -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop).Content
        $upstream = $raw -split "`n" |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ -and $_ -notmatch '^\s*#' -and $_ -match '\.' }
        $filtered = $upstream | Where-Object { $script:DomainSafelist -notcontains $_ }
        $removed = $upstream.Count - $filtered.Count
        if ($filtered.Count -gt 0) {
            $before = $script:TelemetryDomains.Count
            $script:TelemetryDomains = ($script:TelemetryDomains + $filtered) | Sort-Object -Unique
            $added = $script:TelemetryDomains.Count - $before
            $msg = "Merged $added upstream domains ($($script:TelemetryDomains.Count) total)"
            if ($removed -gt 0) { $msg += " ($removed safelisted domains filtered)" }
            Write-Status $msg -Type Success
        }
    } catch {
        Write-Status "Could not fetch upstream domain list (using built-in list)" -Type Warning
    }
}

# ── Dynamic Path Detection ────────────────────────────────────────────────────
# Detect Adobe install paths from registry instead of hard-coding Program Files

function Find-AdobeInstallPaths {
    <#
    .SYNOPSIS
        Discovers Adobe application install paths from registry and filesystem.
    #>
    $paths = @()

    # Check registry for installed Adobe products
    $regRoots = @(
        'HKLM:\SOFTWARE\Adobe'
        'HKLM:\SOFTWARE\WOW6432Node\Adobe'
    )
    foreach ($root in $regRoots) {
        if (-not (Test-Path $root)) { continue }
        $products = Get-ChildItem $root -Recurse -ErrorAction SilentlyContinue |
            Get-ItemProperty -ErrorAction SilentlyContinue |
            Where-Object { $_.InstallPath -or $_.Path } |
            ForEach-Object { if ($_.InstallPath) { $_.InstallPath } else { $_.Path } }
        if ($products) { $paths += $products }
    }

    # Also check standard locations as fallback
    $standardPaths = @(
        "$env:ProgramFiles\Adobe"
        "${env:ProgramFiles(x86)}\Adobe"
        "$env:ProgramFiles\Common Files\Adobe"
        "${env:ProgramFiles(x86)}\Common Files\Adobe"
    )
    foreach ($sp in $standardPaths) {
        if (Test-Path $sp) { $paths += $sp }
    }

    return ($paths | Sort-Object -Unique)
}

$script:AdobeInstallPaths = Find-AdobeInstallPaths

# ── Functions ───────────────────────────────────────────────────────────────────

function Write-Status {
    param(
        [string]$Message,
        [ValidateSet('Info','Success','Warning','Error','Header','DryRun')]
        [string]$Type = 'Info'
    )
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $logLine = "[$timestamp] [$Type] $Message"
    Initialize-AppDataDirectory
    Add-Content -Path $script:LogFile -Value $logLine -ErrorAction SilentlyContinue
    $jsonEntry = [ordered]@{
        timestamp = (Get-Date -Format 'o')
        level     = $Type
        message   = $Message
        profile   = $Profile
        dryRun    = [bool]$DryRun
        undo      = [bool]$Undo
        status    = [bool]$StatusOnly
    }
    ($jsonEntry | ConvertTo-Json -Compress) | Add-Content -Path $script:JsonLogFile -Encoding UTF8 -ErrorAction SilentlyContinue

    if ($Type -eq 'Error') { $script:Counters.Errors++ }

    switch ($Type) {
        'Header'  { Write-Host "`n=== $Message ===`n" -ForegroundColor Cyan }
        'Success' { Write-Host "  [OK] $Message" -ForegroundColor Green }
        'Warning' { Write-Host "  [--] $Message" -ForegroundColor Yellow }
        'Error'   { Write-Host "  [!!] $Message" -ForegroundColor Red }
        'Info'    { Write-Host "  [..] $Message" -ForegroundColor Gray }
        'DryRun'  { Write-Host "  [>>] $Message" -ForegroundColor Magenta }
    }
}

function Write-Rationale {
    param([string]$Message)
    if ($Verbose) {
        Write-Status "Why: $Message" -Type Info
    }
}

function Get-RegistryValueKind {
    param(
        [string]$Path,
        [string]$Name
    )
    $key = $null
    try {
        $keyPath = $Path -replace '^HKLM:\\', 'HKEY_LOCAL_MACHINE\' -replace '^HKCU:\\', 'HKEY_CURRENT_USER\'
        $baseName = if ($keyPath -like 'HKEY_LOCAL_MACHINE\*') { 'LocalMachine' } else { 'CurrentUser' }
        $subKey = $keyPath -replace '^HKEY_LOCAL_MACHINE\\', '' -replace '^HKEY_CURRENT_USER\\', ''
        $baseKey = [Microsoft.Win32.Registry]::$baseName
        $key = $baseKey.OpenSubKey($subKey)
        if ($key) {
            return $key.GetValueKind($Name).ToString()
        }
    } catch {
    } finally {
        if ($key) { $key.Close() }
    }
    return $null
}

function Set-RegistryValueTracked {
    param(
        [string]$Phase,
        [string]$Path,
        [string]$Name,
        $Value,
        [string]$Type = 'DWord'
    )
    $previousExists = $false
    $previousValue = $null
    $previousType = $null
    if (Test-Path $Path) {
        $property = Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue
        if ($null -ne $property -and $property.PSObject.Properties[$Name]) {
            $previousExists = $true
            $previousValue = $property.$Name
            $previousType = Get-RegistryValueKind -Path $Path -Name $Name
        }
    }
    if (-not (Test-Path $Path)) {
        New-Item -Path $Path -Force | Out-Null
    }
    Set-ItemProperty -Path $Path -Name $Name -Value $Value -Type $Type -Force
    Add-ManifestAction -Phase $Phase -Action 'SetRegistryValue' -Details @{
        Path = $Path; Name = $Name; Value = $Value; Type = $Type
        PreviousExists = $previousExists; PreviousValue = $previousValue; PreviousType = $previousType
    }
}

function Restore-RegistryValue {
    param(
        [string]$Path,
        [string]$Name,
        $PreviousValue,
        [bool]$PreviousExists,
        [string]$PreviousType
    )
    if ($PreviousExists) {
        if (-not (Test-Path $Path)) {
            New-Item -Path $Path -Force | Out-Null
        }
        $type = if ($PreviousType) { $PreviousType } else { 'String' }
        Set-ItemProperty -Path $Path -Name $Name -Value $PreviousValue -Type $type -Force
        Write-Status "Restored $Path\$Name" -Type Success
    } elseif (Test-Path $Path) {
        Remove-ItemProperty -Path $Path -Name $Name -Force -ErrorAction SilentlyContinue
        Write-Status "Removed $Path\$Name" -Type Success
    }
}

function Convert-ServiceStartModeForSc {
    param([string]$StartMode)
    switch ($StartMode) {
        'Auto'     { 'auto' }
        'Automatic' { 'auto' }
        'Manual'   { 'demand' }
        'Disabled' { 'disabled' }
        default    { 'demand' }
    }
}

function Set-ServiceStartMode {
    param(
        [string]$Name,
        [string]$StartMode
    )
    $scMode = Convert-ServiceStartModeForSc -StartMode $StartMode
    & sc.exe config $Name start= $scMode 2>&1 | Out-Null
}

function Stop-ServiceSilent {
    param([string]$Name)
    & sc.exe stop $Name 2>&1 | Out-Null
}

function Start-ServiceSilent {
    param([string]$Name)
    & sc.exe start $Name 2>&1 | Out-Null
}

function Remove-DenyAclForEveryone {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return }
    try {
        $acl = Get-Acl $Path
        $changed = $false
        foreach ($rule in @($acl.Access)) {
            if ($rule.AccessControlType -eq 'Deny' -and $rule.IdentityReference.Value -eq 'Everyone') {
                $acl.RemoveAccessRule($rule) | Out-Null
                $changed = $true
            }
        }
        if ($changed) {
            Set-Acl -Path $Path -AclObject $acl
            Write-Status "Removed deny ACL from $Path" -Type Success
        }
    } catch {
        Write-Status "Failed to remove deny ACL from $Path" -Type Warning
    }
}

function Stop-AdobeProcesses {
    Write-Status 'Terminating Adobe background processes' -Type Header
    Write-Rationale 'Adobe CC spawns persistent background processes for telemetry, marketing, and software verification that continue running even after all Adobe apps are closed.'

    foreach ($procName in $AdobeProcesses) {
        $procs = Get-Process -Name $procName -ErrorAction SilentlyContinue |
                 Where-Object {
                     # Only kill node.exe if it lives under an Adobe path
                     if ($procName -eq 'node') {
                         $_.Path -like '*Adobe*'
                     } else { $true }
                 }

        if ($procs) {
            if ($DryRun) {
                Write-Status "Would kill $($procs.Count) instance(s) of $procName" -Type DryRun
            } else {
                $procs | Stop-Process -Force -ErrorAction SilentlyContinue
                Write-Status "Killed $($procs.Count) instance(s) of $procName" -Type Success
            }
            $script:Counters.ProcessesKilled += $procs.Count
        } else {
            Write-Status "$procName not running" -Type Warning
        }
    }
}

function Remove-GrowthSDK {
    Write-Status 'Neutralizing GrowthSDK across all profiles' -Type Header
    Write-Rationale 'GrowthSDK is Adobe''s in-app marketing framework that serves upsell prompts and phones home with usage data. Deleting the directory is insufficient; Adobe recreates it on every launch. A read-only ACL-denied blocker file prevents regeneration.'

    # Get all user profile directories
    $profileRoot = Split-Path $env:USERPROFILE
    $userProfiles = Get-ChildItem $profileRoot -Directory -ErrorAction SilentlyContinue

    foreach ($userProf in $userProfiles) {
        $localLow = Join-Path $userProf.FullName 'AppData\LocalLow'
        if (-not (Test-Path $localLow)) { continue }

        $growthDir = Join-Path $localLow $GrowthSDKRelPath

        if (Test-Path $growthDir -PathType Container) {
            if ($DryRun) {
                Write-Status "Would remove and block GrowthSDK for $($userProf.Name)" -Type DryRun
                $script:Counters.GrowthSDKBlocked++
                continue
            }
            # Nuke the directory
            Remove-Item $growthDir -Recurse -Force -ErrorAction SilentlyContinue
            Start-Sleep -Milliseconds 200

            if (-not (Test-Path $growthDir)) {
                # Plant a read-only blocker file where the directory was
                New-Item -Path $growthDir -ItemType File -Force | Out-Null
                Set-ItemProperty -Path $growthDir -Name IsReadOnly -Value $true
                Set-ItemProperty -Path $growthDir -Name Attributes -Value ([System.IO.FileAttributes]::ReadOnly -bor [System.IO.FileAttributes]::System -bor [System.IO.FileAttributes]::Hidden)
                # Deny write via ACL to prevent Adobe from removing the blocker
                $acl = Get-Acl $growthDir
                $denyRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
                    'Everyone', 'Delete,Write', 'Deny'
                )
                $acl.AddAccessRule($denyRule)
                Set-Acl -Path $growthDir -AclObject $acl
                Write-Status "Removed and blocked GrowthSDK for $($userProf.Name)" -Type Success
                Add-ManifestAction -Phase 'GrowthSDK' -Action 'BlockDirectory' -Details @{
                    Path = $growthDir; Profile = $userProf.Name
                }
                $script:Counters.GrowthSDKBlocked++
            } else {
                Write-Status "Could not remove GrowthSDK for $($userProf.Name) (files locked?)" -Type Error
            }
        } else {
            if (Test-Path $growthDir -PathType Leaf) {
                Write-Status "GrowthSDK already blocked for $($userProf.Name)" -Type Warning
            } else {
                if ($DryRun) {
                    Write-Status "Would pre-block GrowthSDK for $($userProf.Name)" -Type DryRun
                    $script:Counters.GrowthSDKBlocked++
                    continue
                }
                # Preemptively plant blocker even if directory didn't exist yet
                $parentDir = Split-Path $growthDir
                if (-not (Test-Path $parentDir)) {
                    New-Item -Path $parentDir -ItemType Directory -Force | Out-Null
                }
                New-Item -Path $growthDir -ItemType File -Force | Out-Null
                Set-ItemProperty -Path $growthDir -Name IsReadOnly -Value $true
                Set-ItemProperty -Path $growthDir -Name Attributes -Value ([System.IO.FileAttributes]::ReadOnly -bor [System.IO.FileAttributes]::System -bor [System.IO.FileAttributes]::Hidden)
                $acl = Get-Acl $growthDir
                $denyRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
                    'Everyone', 'Delete,Write', 'Deny'
                )
                $acl.AddAccessRule($denyRule)
                Set-Acl -Path $growthDir -AclObject $acl
                Write-Status "Pre-blocked GrowthSDK for $($userProf.Name)" -Type Success
                Add-ManifestAction -Phase 'GrowthSDK' -Action 'BlockDirectory' -Details @{
                    Path = $growthDir; Profile = $userProf.Name
                }
                $script:Counters.GrowthSDKBlocked++
            }
        }

        # Handle additional telemetry paths
        foreach ($relPath in $AdditionalPaths) {
            $targetPath = Join-Path $localLow $relPath
            if (Test-Path $targetPath -PathType Container) {
                if ($DryRun) {
                    Write-Status "Would remove $relPath for $($userProf.Name)" -Type DryRun
                } else {
                    Remove-Item $targetPath -Recurse -Force -ErrorAction SilentlyContinue
                    Write-Status "Removed $relPath for $($userProf.Name)" -Type Success
                }
            }
        }
    }
}

function Disable-AdobeScheduledTasks {
    Write-Status 'Disabling Adobe scheduled tasks' -Type Header
    Write-Rationale 'Adobe installs scheduled tasks (GCInvoker, Genuine Monitor, updaters) that re-enable telemetry services and background processes on a schedule, even after manual disabling.'

    # Dynamic discovery: find all Adobe-related tasks by name or path
    $allTasks = Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object {
        $_.TaskName -like '*Adobe*' -or $_.TaskPath -like '*Adobe*' -or
        $_.TaskName -like '*AdobeGC*' -or $_.TaskName -like '*AdobeAAM*'
    }

    if (-not $allTasks) {
        Write-Status 'No Adobe scheduled tasks found' -Type Warning
        return
    }

    foreach ($task in $allTasks) {
        if ($task.State -eq 'Disabled') {
            Write-Status "Already disabled: $($task.TaskName)" -Type Warning
            continue
        }
        if ($DryRun) {
            Write-Status "Would disable task: $($task.TaskName)" -Type DryRun
            $script:Counters.TasksDisabled++
            continue
        }
        try {
            $task | Disable-ScheduledTask -ErrorAction Stop | Out-Null
            Write-Status "Disabled task: $($task.TaskName)" -Type Success
            Add-ManifestAction -Phase 'Tasks' -Action 'DisableScheduledTask' -Details @{
                TaskName = $task.TaskName; TaskPath = $task.TaskPath; PreviousState = $task.State
            }
            $script:Counters.TasksDisabled++
        } catch {
            Write-Status "Failed to disable task: $($task.TaskName) - $($_.Exception.Message)" -Type Error
        }
    }
}

function Disable-AdobeServices {
    Write-Status 'Disabling Adobe telemetry services' -Type Header
    Write-Rationale 'Adobe background services (AGSService, AGMService, AdobeARMservice, AdobeUpdateService) maintain telemetry pipelines and genuine-software checks. Disabling prevents automatic restart after process termination.'

    foreach ($svcName in $Services) {
        $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
        if ($svc) {
            $startType = (Get-CimInstance Win32_Service -Filter "Name='$svcName'" -ErrorAction SilentlyContinue).StartMode
            if ($startType -eq 'Disabled') {
                Write-Status "Already disabled: $svcName ($($svc.DisplayName))" -Type Warning
                continue
            }
            if ($DryRun) {
                Write-Status "Would disable service: $svcName ($($svc.DisplayName))" -Type DryRun
                $script:Counters.ServicesDisabled++
                continue
            }
            if ($svc.Status -eq 'Running') {
                Stop-ServiceSilent -Name $svcName
            }
            Set-ServiceStartMode -Name $svcName -StartMode 'Disabled'
            Write-Status "Disabled service: $svcName ($($svc.DisplayName))" -Type Success
            Add-ManifestAction -Phase 'Services' -Action 'DisableService' -Details @{
                Name = $svcName; PreviousStartMode = $startType; PreviousStatus = $svc.Status
            }
            $script:Counters.ServicesDisabled++
        } else {
            Write-Status "Service not found: $svcName" -Type Warning
        }
    }
}

function Set-AdobeRegistryPolicies {
    Write-Status 'Setting registry policies to disable telemetry' -Type Header
    Write-Rationale 'Enterprise registry policies under HKLM:\SOFTWARE\Policies\Adobe are the official mechanism for fleet-wide Adobe telemetry suppression. Adobe applications read these keys at startup and respect them.'

    $regPaths = @(
        @{
            Path  = 'HKLM:\SOFTWARE\Policies\Adobe\Common\Enterprise'
            Values = @{
                'DisableUsageData'      = 1
                'DisableFileSync'       = 1
                'DisableAutoupdates'    = 1
                'DisableCCDesktop'      = 0  # Keep CC app functional, just kill telemetry
            }
        },
        @{
            Path  = 'HKLM:\SOFTWARE\Policies\Adobe\CCXNew'
            Values = @{
                'DisableGrowth'         = 1
            }
        },
        @{
            Path  = 'HKLM:\SOFTWARE\Policies\Adobe\CreativeCloud'
            Values = @{
                'DisableLaunchOnLogin'  = 1
                'DisableNotifications'  = 1
                'DisableAutoUpdates'    = 1
            }
        },
        @{
            Path  = 'HKLM:\SOFTWARE\Adobe\Adobe Genuine Service'
            Values = @{
                'AgsDisabled'           = 1
            }
        },
        @{
            Path  = 'HKCU:\SOFTWARE\Adobe\CommonFiles\UsageCC'
            Values = @{
                'AUSUF'                 = 0
            }
        },
        @{
            Path  = 'HKLM:\SOFTWARE\Policies\Adobe\Substance 3D'
            Values = @{
                'DisableAnalytics'      = 1
                'DisableTelemetry'      = 1
                'DisableAutoUpdate'     = 1
            }
        },
        @{
            Path  = 'HKCU:\SOFTWARE\Adobe\Substance 3D Painter\Settings'
            Values = @{
                'enable_analytics'      = 0
            }
        },
        @{
            Path  = 'HKCU:\SOFTWARE\Adobe\Substance 3D Designer\Settings'
            Values = @{
                'enable_analytics'      = 0
            }
        },
        @{
            Path  = 'HKCU:\SOFTWARE\Adobe\Substance 3D Sampler\Settings'
            Values = @{
                'enable_analytics'      = 0
            }
        }
    )

    foreach ($entry in $regPaths) {
        foreach ($name in $entry.Values.Keys) {
            $val = $entry.Values[$name]
            # Idempotent: check if already set to desired value
            if (Test-Path $entry.Path) {
                $current = (Get-ItemProperty -Path $entry.Path -Name $name -ErrorAction SilentlyContinue).$name
                if ($null -ne $current -and $current -eq $val) {
                    Write-Status "Already set: $($entry.Path)\$name = $val" -Type Warning
                    continue
                }
            }
            if ($DryRun) {
                Write-Status "Would set $($entry.Path)\$name = $val" -Type DryRun
                $script:Counters.RegistryKeysSet++
                continue
            }
            Set-RegistryValueTracked -Phase 'Registry' -Path $entry.Path -Name $name -Value $val -Type 'DWord'
            Write-Status "Set $($entry.Path)\$name = $val" -Type Success
            $script:Counters.RegistryKeysSet++
        }
    }
}

function Block-AdobeFirewall {
    Write-Status 'Creating firewall rules to block Adobe telemetry' -Type Header
    Write-Rationale 'DNS-level blocking (hosts file) can be bypassed by hardcoded IPs or DNS-over-HTTPS. Firewall rules block by resolved IP (TCP+UDP) and by program path as a defense-in-depth layer. Persistent null routes add a third layer that survives firewall resets.'

    # Idempotent: remove existing rules from a previous run to avoid duplicates
    $existing = Get-NetFirewallRule -DisplayName 'Block Adobe Telemetry*' -ErrorAction SilentlyContinue
    if ($existing) {
        if ($DryRun) {
            Write-Status "Would remove $(@($existing).Count) previous firewall rules before recreating" -Type DryRun
        } else {
            $existing | Remove-NetFirewallRule -ErrorAction SilentlyContinue
            Write-Status 'Removed previous firewall rules (will recreate)' -Type Info
        }
    }

    # Block outbound to telemetry domains by resolving IPs (both IPv4 and IPv6)
    $resolvedIPv4 = @()
    $resolvedIPv6 = @()
    $domainIPMap = @{}
    foreach ($domain in $TelemetryDomains) {
        try {
            $allAddrs = [System.Net.Dns]::GetHostAddresses($domain)
            $v4 = $allAddrs | Where-Object { $_.AddressFamily -eq 'InterNetwork' } | Select-Object -ExpandProperty IPAddressToString
            $v6 = $allAddrs | Where-Object { $_.AddressFamily -eq 'InterNetworkV6' } | Select-Object -ExpandProperty IPAddressToString
            $combined = @()
            if ($v4) { $resolvedIPv4 += $v4; $combined += $v4 }
            if ($v6) { $resolvedIPv6 += $v6; $combined += $v6 }
            if ($combined) {
                $domainIPMap[$domain] = $combined
                Write-Status "$domain -> $($combined -join ', ')" -Type Info
            } else {
                Write-Status "$domain -> no records" -Type Warning
            }
        } catch {
            Write-Status "$domain -> resolution failed" -Type Warning
        }
    }

    # Log the full domain-to-IP mapping
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Add-Content -Path $script:LogFile -Value "[$timestamp] [Firewall] Domain-to-IP resolution:" -ErrorAction SilentlyContinue
    foreach ($domain in $domainIPMap.Keys) {
        Add-Content -Path $script:LogFile -Value "  $domain -> $($domainIPMap[$domain] -join ', ')" -ErrorAction SilentlyContinue
    }

    $resolvedIPv4 = $resolvedIPv4 | Sort-Object -Unique
    $resolvedIPv6 = $resolvedIPv6 | Sort-Object -Unique
    $allResolvedIPs = @($resolvedIPv4) + @($resolvedIPv6) | Sort-Object -Unique

    if ($allResolvedIPs.Count -gt 0) {
        if ($DryRun) {
            Write-Status "Would block $($resolvedIPv4.Count) IPv4 + $($resolvedIPv6.Count) IPv6 telemetry IPs via firewall" -Type DryRun
        } else {
            New-NetFirewallRule -DisplayName 'Block Adobe Telemetry - Outbound IPs (TCP)' `
                -Direction Outbound `
                -Action Block `
                -RemoteAddress $allResolvedIPs `
                -Protocol TCP `
                -Profile Any `
                -Enabled True `
                -Description 'Blocks outbound TCP to Adobe telemetry/analytics servers (IPv4+IPv6).' |
                Out-Null
            New-NetFirewallRule -DisplayName 'Block Adobe Telemetry - Outbound IPs (UDP)' `
                -Direction Outbound `
                -Action Block `
                -RemoteAddress $allResolvedIPs `
                -Protocol UDP `
                -Profile Any `
                -Enabled True `
                -Description 'Blocks outbound UDP/QUIC to Adobe telemetry/analytics servers (IPv4+IPv6).' |
                Out-Null
            Add-ManifestAction -Phase 'Firewall' -Action 'AddFirewallRule' -Details @{
                DisplayName = 'Block Adobe Telemetry - Outbound IPs (TCP)'
            }
            Add-ManifestAction -Phase 'Firewall' -Action 'AddFirewallRule' -Details @{
                DisplayName = 'Block Adobe Telemetry - Outbound IPs (UDP)'
            }
            Write-Status "Blocked $($resolvedIPv4.Count) IPv4 + $($resolvedIPv6.Count) IPv6 telemetry IPs via firewall (TCP+UDP)" -Type Success
        }
        $script:Counters.FirewallIPsBlocked = $allResolvedIPs.Count
        $script:Counters.FirewallRulesAdded += 2
    } else {
        Write-Status 'Could not resolve any telemetry domains (offline?)' -Type Warning
    }

    # Also block known Adobe telemetry executables by program path
    $adobeExePaths = @(
        "$env:ProgramFiles\Common Files\Adobe\OOBE\PDApp\core\PDApp.exe"
        "$env:ProgramFiles\Common Files\Adobe\AdobeGCClient\AdobeGCClient.exe"
        "$env:ProgramFiles\Common Files\Adobe\OOBE\PDApp\UWA\UpdaterStartupUtility.exe"
        "${env:ProgramFiles(x86)}\Common Files\Adobe\OOBE\PDApp\core\PDApp.exe"
        "${env:ProgramFiles(x86)}\Common Files\Adobe\AdobeGCClient\AdobeGCClient.exe"
        "$env:ProgramFiles\Common Files\Adobe\CoreSyncExtension\CoreSync.exe"
        "${env:ProgramFiles(x86)}\Common Files\Adobe\CoreSyncExtension\CoreSync.exe"
    )
    # Dynamically discover additional telemetry executables under Adobe install paths
    $telemetryExeNames = @(
        'LogTransport2.exe', 'CRWindowsClientService.exe', 'CRLogTransport.exe', 'AdobeCollabSync.exe',
        'AdobeGCClient.exe', 'Adobe Crash Processor.exe', 'AcroCEF.exe', 'RdrCEF.exe', 'Acrobat.exe',
        'AcroRd32.exe', 'Adobe Dimension.exe', 'Adobe Substance 3D Painter.exe',
        'Adobe Substance 3D Designer.exe', 'Adobe Substance 3D Sampler.exe', 'Adobe Substance 3D Stager.exe',
        'Creative Cloud.exe', 'Adobe CEF Helper.exe', 'AdobeNotificationClient.exe'
    )
    foreach ($installPath in $script:AdobeInstallPaths) {
        if (-not (Test-Path $installPath)) { continue }
        foreach ($exeName in $telemetryExeNames) {
            $found = Get-ChildItem -Path $installPath -Filter $exeName -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($found) { $adobeExePaths += $found.FullName }
        }
    }

    foreach ($exePath in $adobeExePaths) {
        if (Test-Path $exePath) {
            $exeName = Split-Path $exePath -Leaf
            if ($DryRun) {
                Write-Status "Would block $exeName via firewall" -Type DryRun
            } else {
                New-NetFirewallRule -DisplayName "Block Adobe Telemetry - $exeName" `
                    -Direction Outbound `
                    -Action Block `
                    -Program $exePath `
                    -Profile Any `
                    -Enabled True `
                    -Description "Blocks $exeName from reaching Adobe analytics servers." |
                    Out-Null
                Add-ManifestAction -Phase 'Firewall' -Action 'AddFirewallRule' -Details @{
                    DisplayName = "Block Adobe Telemetry - $exeName"
                }
            }
            $script:Counters.FirewallRulesAdded++
        }
    }

    if ($script:Counters.FirewallRulesAdded -gt 1) {
        Write-Status "Blocked $($script:Counters.FirewallRulesAdded - 1) Adobe executables via firewall" -Type Success
    } else {
        Write-Status 'No known Adobe telemetry executables found on disk' -Type Warning
    }

    # Add persistent null routes for resolved telemetry IPs (IPv4 only — route.exe does not support IPv6 persistent routes)
    if ($resolvedIPv4.Count -gt 0) {
        $routesAdded = 0
        foreach ($ip in $resolvedIPv4) {
            $existing = route print $ip 2>&1 | Select-String $ip -ErrorAction SilentlyContinue
            if ($existing) { continue }
            if ($DryRun) {
                $routesAdded++
            } else {
                & route -p add $ip mask 255.255.255.255 0.0.0.0 2>&1 | Out-Null
                Add-ManifestAction -Phase 'Firewall' -Action 'AddRoute' -Details @{
                    IPAddress = $ip
                }
                $routesAdded++
            }
        }
        if ($routesAdded -gt 0) {
            if ($DryRun) {
                Write-Status "Would add $routesAdded persistent null routes" -Type DryRun
            } else {
                Write-Status "Added $routesAdded persistent null routes for telemetry IPs" -Type Success
            }
        }
    }

    # FQDN wildcard firewall rules via Dynamic Keywords (Windows 10 20H2+, requires Defender + Network Protection)
    $dynamicKeywordsAvailable = $false
    try {
        $mpStatus = Get-MpComputerStatus -ErrorAction Stop
        $mpPrefs = Get-MpPreference -ErrorAction Stop
        if ($mpStatus.AMRunningMode -eq 'Normal' -and $mpPrefs.EnableNetworkProtection -ge 1) {
            $dynamicKeywordsAvailable = $null -ne (Get-Command New-NetFirewallDynamicKeywordAddress -ErrorAction SilentlyContinue)
        }
    } catch { }

    if ($dynamicKeywordsAvailable) {
        $fqdnPatterns = @(
            '*.adobe.io'
            '*.adobestats.io'
            '*.demdex.net'
            '*.adobedtm.com'
            '*.adobegenuine.com'
        )

        # Remove existing Dynamic Keyword rules from previous runs
        $existingDk = Get-NetFirewallDynamicKeywordAddress -ErrorAction SilentlyContinue |
            Where-Object { $_.Keyword -like '*adobe*' -or $_.Keyword -like '*demdex*' -or $_.Keyword -like '*adobedtm*' }
        if ($existingDk) {
            foreach ($dk in $existingDk) {
                Remove-NetFirewallDynamicKeywordAddress -Id $dk.Id -ErrorAction SilentlyContinue
            }
        }

        if ($DryRun) {
            Write-Status "Would create $($fqdnPatterns.Count) FQDN wildcard firewall rules via Dynamic Keywords" -Type DryRun
        } else {
            $dkCreated = 0
            foreach ($pattern in $fqdnPatterns) {
                try {
                    $dkId = '{' + (New-Guid).ToString() + '}'
                    New-NetFirewallDynamicKeywordAddress -Id $dkId -Keyword $pattern -AutoResolve $true -ErrorAction Stop
                    New-NetFirewallRule -DisplayName "Block Adobe Telemetry - FQDN $pattern" `
                        -Direction Outbound `
                        -Action Block `
                        -RemoteDynamicKeywordAddresses $dkId `
                        -Profile Any `
                        -Enabled True `
                        -Description "Blocks outbound to $pattern via FQDN Dynamic Keyword." |
                        Out-Null
                    Add-ManifestAction -Phase 'Firewall' -Action 'AddFirewallRule' -Details @{
                        DisplayName = "Block Adobe Telemetry - FQDN $pattern"
                    }
                    Add-ManifestAction -Phase 'Firewall' -Action 'AddDynamicKeyword' -Details @{
                        Id = $dkId; Keyword = $pattern
                    }
                    $dkCreated++
                } catch {
                    Write-Status "Dynamic Keyword failed for $pattern : $($_.Exception.Message)" -Type Warning
                }
            }
            if ($dkCreated -gt 0) {
                Write-Status "Created $dkCreated FQDN wildcard firewall rules (handles subdomain rotation automatically)" -Type Success
                $script:Counters.FirewallRulesAdded += $dkCreated
            }
        }
    } else {
        Write-Status 'Dynamic Keywords not available (requires Defender + Network Protection) — using IP-based rules only' -Type Info
    }
}

function Block-AdobeHostsFile {
    Write-Status 'Blocking Adobe telemetry via hosts file' -Type Header
    Write-Rationale 'Hosts file sinkholing (0.0.0.0) is the simplest blocking layer. It works at the OS resolver level before any network stack is involved, but can be overridden by Adobe WAM (Web Account Manager) which injects its own hosts entries. WAM entries are detected and removed first.'

    $hostsPath = "$env:SystemRoot\System32\drivers\etc\hosts"
    $marker    = '# --- Adobe Telemetry Block (Disable-AdobeTelemetry.ps1) ---'
    $endMarker = '# --- End Adobe Telemetry Block ---'

    $hostsContent = Get-Content $hostsPath -Raw -ErrorAction SilentlyContinue

    # Pre-flight backup of the hosts file
    $backupDir = Join-Path $env:APPDATA 'Disable-AdobeTelemetry'
    if (-not (Test-Path $backupDir)) {
        New-Item -Path $backupDir -ItemType Directory -Force | Out-Null
    }
    $backupTs = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backupPath = Join-Path $backupDir "hosts.bak.$backupTs"

    if ($DryRun) {
        Write-Status "Would backup hosts file to $backupPath" -Type DryRun
        Write-Status "Would add $($TelemetryDomains.Count) domains to hosts file" -Type DryRun
        $script:Counters.DomainsBlocked = $TelemetryDomains.Count
        return
    }

    Copy-Item -Path $hostsPath -Destination $backupPath -Force -ErrorAction SilentlyContinue
    Write-Status "Hosts file backed up to $backupPath" -Type Info
    Add-ManifestAction -Phase 'Hosts' -Action 'HostsBackup' -Details @{
        Path = $hostsPath; BackupPath = $backupPath
    }

    # Remove Adobe WAM injected entries if present
    $wamMarker = '# Adobe Creative Cloud WAM - Start'
    $wamEndMarker = '# Adobe Creative Cloud WAM - End'
    if ($hostsContent -match [regex]::Escape($wamMarker)) {
        $wamPattern = "(?s)\r?\n?$([regex]::Escape($wamMarker)).*?$([regex]::Escape($wamEndMarker))\r?\n?"
        $hostsContent = $hostsContent -replace $wamPattern, ''
        Set-Content -Path $hostsPath -Value $hostsContent.TrimEnd() -Force -Encoding ASCII
        Write-Status 'Removed Adobe WAM hosts injection' -Type Success
        Add-ManifestAction -Phase 'Hosts' -Action 'RemoveHostsBlock' -Details @{
            Path = $hostsPath; Marker = $wamMarker; EndMarker = $wamEndMarker
        }
    }

    # Remove previous block if it exists (idempotent refresh)
    if ($hostsContent -match [regex]::Escape($marker)) {
        $pattern = "(?s)$([regex]::Escape($marker)).*?$([regex]::Escape($endMarker))\r?\n?"
        $hostsContent = $hostsContent -replace $pattern, ''
        Set-Content -Path $hostsPath -Value $hostsContent.TrimEnd() -Force -Encoding ASCII
    }

    # Append new block (IPv4 + IPv6 sinkhole for each domain)
    $blockEntries = @($marker)
    foreach ($domain in $TelemetryDomains) {
        $blockEntries += "0.0.0.0    $domain"
        $blockEntries += "::         $domain"
    }
    $blockEntries += $endMarker

    $newBlock = "`r`n" + ($blockEntries -join "`r`n") + "`r`n"
    Add-Content -Path $hostsPath -Value $newBlock -Encoding ASCII
    Write-Status "Added $($TelemetryDomains.Count) domains to hosts file" -Type Success
    Add-ManifestAction -Phase 'Hosts' -Action 'HostsBlock' -Details @{
        Path = $hostsPath; Marker = $marker; EndMarker = $endMarker; BackupPath = $backupPath
    }
    $script:Counters.DomainsBlocked = $TelemetryDomains.Count

    # Flush DNS cache so changes take effect immediately
    & ipconfig /flushdns 2>&1 | Out-Null
    Write-Status 'DNS cache flushed' -Type Info
}

function Disable-CCXProcess {
    Write-Status 'Permanently neutralizing CCXProcess' -Type Header
    Write-Rationale 'CCXProcess.exe is the Creative Cloud Experience host that serves in-app marketing and notifications. It persists after closing all Adobe apps and relaunches via scheduled tasks. The triple-layer approach (rename + IFEO + ACL) ensures it cannot be restored silently by Adobe updaters.'

    $ccxPaths = @(
        "$env:ProgramFiles\Adobe\Adobe Creative Cloud Experience"
        "${env:ProgramFiles(x86)}\Adobe\Adobe Creative Cloud Experience"
    )

    foreach ($ccxDir in $ccxPaths) {
        if (-not (Test-Path $ccxDir)) { continue }

        $ccxExe = Join-Path $ccxDir 'CCXProcess.exe'
        $ccxDisabled = Join-Path $ccxDir 'CCXProcess.exe.disabled'

        # Already neutralized?
        if (-not (Test-Path $ccxExe) -and (Test-Path $ccxDisabled)) {
            Write-Status "CCXProcess.exe already renamed in $ccxDir" -Type Warning
        } elseif (Test-Path $ccxExe) {
            if ($DryRun) {
                Write-Status "Would rename CCXProcess.exe -> CCXProcess.exe.disabled in $ccxDir" -Type DryRun
                $script:Counters.ExesNeutralized++
            } else {
                # Kill it first
                Get-Process -Name 'CCXProcess' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
                Start-Sleep -Milliseconds 500

                try {
                    Rename-Item -Path $ccxExe -NewName 'CCXProcess.exe.disabled' -Force -ErrorAction Stop
                    Write-Status "Renamed CCXProcess.exe -> CCXProcess.exe.disabled in $ccxDir" -Type Success
                    Add-ManifestAction -Phase 'CCXProcess' -Action 'RenameFile' -Details @{
                        OriginalPath = $ccxExe; RenamedPath = $ccxDisabled
                    }
                    $script:Counters.ExesNeutralized++
                } catch {
                    Write-Status "Rename failed (file locked?) - applying ACL deny instead" -Type Warning
                    # If rename fails (file locked), strip execute permissions instead
                    try {
                        $acl = Get-Acl $ccxExe
                        $denyRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
                            'Everyone', 'ReadAndExecute,ExecuteFile', 'Deny'
                        )
                        $acl.AddAccessRule($denyRule)
                        Set-Acl -Path $ccxExe -AclObject $acl
                        Write-Status "Denied execute permissions on CCXProcess.exe in $ccxDir" -Type Success
                        Add-ManifestAction -Phase 'CCXProcess' -Action 'SetAclDeny' -Details @{
                            Path = $ccxExe
                        }
                        $script:Counters.ExesNeutralized++
                    } catch {
                        Write-Status "Could not modify CCXProcess.exe - try after closing all Adobe apps" -Type Error
                    }
                }
            }
        }

        # Also handle the Node.js helper that CCXProcess spawns
        $nodeExe = Join-Path $ccxDir 'libs\node.exe'
        if (Test-Path $nodeExe) {
            if ($DryRun) {
                Write-Status "Would rename CCX node.exe -> node.exe.disabled" -Type DryRun
                $script:Counters.ExesNeutralized++
            } else {
                try {
                    Rename-Item -Path $nodeExe -NewName 'node.exe.disabled' -Force -ErrorAction Stop
                    Write-Status "Renamed CCX node.exe -> node.exe.disabled" -Type Success
                    Add-ManifestAction -Phase 'CCXProcess' -Action 'RenameFile' -Details @{
                        OriginalPath = $nodeExe; RenamedPath = (Join-Path (Split-Path $nodeExe) 'node.exe.disabled')
                    }
                    $script:Counters.ExesNeutralized++
                } catch {
                    Write-Status "CCX node.exe rename failed (may be locked)" -Type Warning
                }
            }
        }
    }

    # IFEO debugger redirect as a fallback - if anything tries to launch
    # CCXProcess.exe, Windows redirects it to a nonexistent debugger and it dies
    $ifeoPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\CCXProcess.exe'
    if ($DryRun) {
        Write-Status 'Would set IFEO debugger redirect for CCXProcess.exe' -Type DryRun
    } else {
        # Save original IFEO value before overwriting so restore can be exact
        if (Test-Path $ifeoPath) {
            $originalDebugger = (Get-ItemProperty -Path $ifeoPath -Name 'Debugger' -ErrorAction SilentlyContinue).Debugger
            if ($originalDebugger -and $originalDebugger -notlike '*AdobeTelemetryBlock.invalid') {
                $backupDir = Join-Path $env:APPDATA 'Disable-AdobeTelemetry'
                if (-not (Test-Path $backupDir)) { New-Item -Path $backupDir -ItemType Directory -Force | Out-Null }
                $ifeoBackup = Join-Path $backupDir 'ifeo-original-values.txt'
                $backupLine = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | CCXProcess.exe | Debugger | $originalDebugger"
                Add-Content -Path $ifeoBackup -Value $backupLine -ErrorAction SilentlyContinue
                Write-Status "Saved original IFEO value for CCXProcess.exe: $originalDebugger" -Type Info
            }
        } else {
            New-Item -Path $ifeoPath -Force | Out-Null
        }
        $ifeoTarget = Join-Path $env:SystemRoot 'System32\AdobeTelemetryBlock.invalid'
        Set-RegistryValueTracked -Phase 'CCXProcess' -Path $ifeoPath -Name 'Debugger' -Value $ifeoTarget -Type 'String'
        Write-Status 'Set IFEO debugger redirect for CCXProcess.exe (failsafe)' -Type Success
    }

    # Block it in firewall by program path (in case it ever gets restored)
    foreach ($ccxDir in $ccxPaths) {
        $ccxExe = Join-Path $ccxDir 'CCXProcess.exe'
        $disabledExe = Join-Path $ccxDir 'CCXProcess.exe.disabled'
        $targetExe = if (Test-Path $ccxExe) { $ccxExe } elseif (Test-Path $disabledExe) { $ccxExe } else { $null }
        if ($targetExe) {
            if ($DryRun) {
                Write-Status "Would add firewall rule for CCXProcess in $ccxDir" -Type DryRun
            } else {
                # Create rule against original path in case it gets restored
                New-NetFirewallRule -DisplayName "Block Adobe Telemetry - CCXProcess ($ccxDir)" `
                    -Direction Outbound `
                    -Action Block `
                    -Program $ccxExe `
                    -Profile Any `
                    -Enabled True `
                    -Description 'Prevents CCXProcess from phoning home even if restored.' |
                    Out-Null
                Write-Status "Firewall rule added for CCXProcess in $ccxDir" -Type Success
                Add-ManifestAction -Phase 'CCXProcess' -Action 'AddFirewallRule' -Details @{
                    DisplayName = "Block Adobe Telemetry - CCXProcess ($ccxDir)"
                }
            }
            $script:Counters.FirewallRulesAdded++
        }
    }

    # IFEO redirect for Creative Cloud Helper (triggers CC app auto-popup after updates)
    $ccHelperExes = @('Creative Cloud Helper.exe', 'AdobeNotificationClient.exe')
    foreach ($helperExe in $ccHelperExes) {
        $helperIfeo = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\$helperExe"
        if ($DryRun) {
            Write-Status "Would set IFEO debugger redirect for $helperExe" -Type DryRun
        } else {
            if (-not (Test-Path $helperIfeo)) {
                New-Item -Path $helperIfeo -Force | Out-Null
            }
            $ifeoTarget = Join-Path $env:SystemRoot 'System32\AdobeTelemetryBlock.invalid'
            Set-RegistryValueTracked -Phase 'CCXProcess' -Path $helperIfeo -Name 'Debugger' -Value $ifeoTarget -Type 'String'
            Write-Status "Set IFEO debugger redirect for $helperExe" -Type Success
        }
    }
}

function Disable-AdobeIPCBroker {
    Write-Status 'Restricting AdobeIPCBroker (firewall only - required for app launch)' -Type Header
    Write-Rationale 'AdobeIPCBroker.exe is required for Premiere Pro and Photoshop to launch (local inter-process communication). Renaming or blocking execution breaks Adobe apps. Instead, outbound firewall rules prevent it from phoning home while preserving local IPC functionality.'

    # NOTE: AdobeIPCBroker.exe is required for Premiere/Photoshop to start.
    # Renaming or blocking execution breaks Adobe apps entirely.
    # Instead we firewall it so it handles local IPC but cannot phone home.

    $ipcPaths = @(
        "$env:ProgramFiles\Common Files\Adobe\Adobe Desktop Common\IPCBox"
        "${env:ProgramFiles(x86)}\Common Files\Adobe\Adobe Desktop Common\IPCBox"
    )

    foreach ($ipcDir in $ipcPaths) {
        if (-not (Test-Path $ipcDir)) { continue }

        $ipcExe = Join-Path $ipcDir 'AdobeIPCBroker.exe'
        if (-not (Test-Path $ipcExe)) {
            # Check if a previous run renamed it - restore it
            $disabledExe = Join-Path $ipcDir 'AdobeIPCBroker.exe.disabled'
            if (Test-Path $disabledExe) {
                if ($DryRun) {
                    Write-Status "Would restore previously disabled AdobeIPCBroker.exe in $ipcDir" -Type DryRun
                } else {
                    Rename-Item -Path $disabledExe -NewName 'AdobeIPCBroker.exe' -Force -ErrorAction SilentlyContinue
                    # Re-run guard: verify the restore actually worked
                    $ipcExe = Join-Path $ipcDir 'AdobeIPCBroker.exe'
                    if (Test-Path $ipcExe) {
                        Write-Status "Restored previously disabled AdobeIPCBroker.exe in $ipcDir" -Type Success
                    } else {
                        Write-Status "Failed to restore AdobeIPCBroker.exe in $ipcDir - file may be locked" -Type Error
                        continue
                    }
                }
                $ipcExe = Join-Path $ipcDir 'AdobeIPCBroker.exe'
            } else {
                continue
            }
        }

        # Remove any deny ACLs from a previous run
        if (-not $DryRun) {
            try {
                $acl = Get-Acl $ipcExe
                $removedRule = $false
                foreach ($rule in $acl.Access) {
                    if ($rule.AccessControlType -eq 'Deny' -and
                        $rule.IdentityReference.Value -eq 'Everyone') {
                        $acl.RemoveAccessRule($rule) | Out-Null
                        $removedRule = $true
                    }
                }
                if ($removedRule) {
                    Set-Acl -Path $ipcExe -AclObject $acl
                    Write-Status "Removed previous deny ACL from AdobeIPCBroker.exe" -Type Success
                }
            } catch { }
        }

        # Firewall rule - block outbound only (local IPC still works)
        if ($DryRun) {
            Write-Status "Would add firewall rule for AdobeIPCBroker in $ipcDir" -Type DryRun
        } else {
            New-NetFirewallRule -DisplayName "Block Adobe Telemetry - AdobeIPCBroker ($ipcDir)" `
                -Direction Outbound `
                -Action Block `
                -Program $ipcExe `
                -Profile Any `
                -Enabled True `
                -Description 'Blocks AdobeIPCBroker outbound telemetry while allowing local IPC.' |
                Out-Null
            Write-Status "Firewall rule added for AdobeIPCBroker in $ipcDir" -Type Success
            Add-ManifestAction -Phase 'IPCBroker' -Action 'AddFirewallRule' -Details @{
                DisplayName = "Block Adobe Telemetry - AdobeIPCBroker ($ipcDir)"
            }
        }
        $script:Counters.FirewallRulesAdded++
    }

    # Remove IFEO redirect if set by a previous run
    $ifeoPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\AdobeIPCBroker.exe'
    if (Test-Path $ifeoPath) {
        if ($DryRun) {
            Write-Status 'Would remove previous IFEO redirect for AdobeIPCBroker.exe' -Type DryRun
        } else {
            Remove-Item -Path $ifeoPath -Recurse -Force -ErrorAction SilentlyContinue
            Write-Status 'Removed previous IFEO redirect for AdobeIPCBroker.exe' -Type Success
        }
    }
    Write-Status 'AdobeIPCBroker.exe left functional (firewalled outbound only)' -Type Info
}

function Disable-AdobeStartupEntries {
    Write-Status 'Disabling Adobe startup/run entries' -Type Header
    Write-Rationale 'Adobe registers auto-start entries in HKLM/HKCU Run keys and startup folders. These relaunch CC Desktop, AGS, and update services on login, undoing process kills and service disables. Values are prefixed with REM rather than deleted so -Undo can restore the exact original value.'

    $runPaths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
    )

    foreach ($runPath in $runPaths) {
        if (-not (Test-Path $runPath)) { continue }
        $props = Get-ItemProperty $runPath -ErrorAction SilentlyContinue
        foreach ($name in $props.PSObject.Properties.Name) {
            if ($name -match 'Adobe|CCXProcess|AdobeGC|AdobeAAM') {
                $val = $props.$name
                # Prefix with REM to disable without deleting
                if ($val -notlike 'REM *') {
                    if ($DryRun) {
                        Write-Status "Would disable startup entry: $name" -Type DryRun
                    } else {
                        Set-ItemProperty -Path $runPath -Name $name -Value "REM $val" -Force
                        Write-Status "Disabled startup entry: $name" -Type Success
                        Add-ManifestAction -Phase 'Startup' -Action 'DisableStartupValue' -Details @{
                            Path = $runPath; Name = $name; PreviousValue = $val
                        }
                    }
                    $script:Counters.StartupDisabled++
                } else {
                    Write-Status "Already disabled: $name" -Type Warning
                }
            }
        }
    }

    $startupFolders = @()
    $commonStartup = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\Startup'
    if (Test-Path $commonStartup) { $startupFolders += $commonStartup }
    $profileRoot = Split-Path $env:USERPROFILE
    $userProfiles = Get-ChildItem $profileRoot -Directory -ErrorAction SilentlyContinue
    foreach ($userProf in $userProfiles) {
        $folder = Join-Path $userProf.FullName 'AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup'
        if (Test-Path $folder) { $startupFolders += $folder }
    }

    foreach ($folder in ($startupFolders | Sort-Object -Unique)) {
        $shortcuts = Get-ChildItem -Path $folder -Filter '*.lnk' -ErrorAction SilentlyContinue |
            Where-Object { $_.BaseName -match 'Adobe|Creative Cloud|CCX|CCLibrary|CoreSync' }
        foreach ($shortcut in $shortcuts) {
            $disabledPath = "$($shortcut.FullName).disabled"
            if (Test-Path $disabledPath) {
                Write-Status "Startup shortcut already disabled: $($shortcut.Name)" -Type Warning
                continue
            }
            if ($DryRun) {
                Write-Status "Would disable startup shortcut: $($shortcut.FullName)" -Type DryRun
            } else {
                Rename-Item -Path $shortcut.FullName -NewName "$($shortcut.Name).disabled" -Force
                Write-Status "Disabled startup shortcut: $($shortcut.Name)" -Type Success
                Add-ManifestAction -Phase 'Startup' -Action 'RenameStartupShortcut' -Details @{
                    OriginalPath = $shortcut.FullName; RenamedPath = $disabledPath
                }
            }
            $script:Counters.StartupDisabled++
        }
    }
}

function Disable-AcrobatTelemetry {
    Write-Status 'Disabling Adobe Acrobat/Reader telemetry via registry' -Type Header
    Write-Rationale 'Acrobat and Reader have their own telemetry and in-product messaging system separate from CC. FeatureLockDown registry policies are the documented enterprise mechanism. Both 64-bit and Wow6432Node paths are set to cover Acrobat Pro (64-bit) and Reader (32-bit) installations.'

    # Build policies for both Acrobat Pro and Acrobat Reader
    $productPaths = @(
        'Adobe Acrobat'
        'Acrobat Reader'
    )
    $acrobatPolicies = @(
        @{
            Path   = 'HKCU:\SOFTWARE\Adobe\Adobe Acrobat\DC\AVAlert\cCheckbox'
            Values = @{ 'iAcro498' = 1 }
        },
        @{
            Path   = 'HKCU:\SOFTWARE\Adobe\CommonFiles\CRLog'
            Values = @{ 'Never Ask' = '1' }
            Type   = 'String'
        },
        @{
            Path   = 'HKCU:\SOFTWARE\Adobe\Adobe Acrobat\DC\Workflows'
            Values = @{ 'bNeedSynchronizer' = 0 }
        }
    )

    foreach ($product in $productPaths) {
        $basePaths = @(
            "HKLM:\SOFTWARE\Policies\Adobe\$product\DC\FeatureLockDown"
            "HKLM:\SOFTWARE\Wow6432Node\Policies\Adobe\$product\DC\FeatureLockDown"
        )
        foreach ($basePath in $basePaths) {
            $acrobatPolicies += @{
                Path   = $basePath
                Values = @{
                    'bUsageMeasurement'       = 0
                    'bAcroSuppressUpsell'     = 1
                    'bUpdater'                = 0
                    'bWhatsNewExp'            = 1
                    'bEnableGentech'          = 0
                }
            }
            $acrobatPolicies += @{
                Path   = "$basePath\cServices"
                Values = @{
                    'bToggleAdobeSign'           = 1
                    'bTogglePrefsSync'           = 1
                    'bToggleWebConnectors'       = 1
                    'bAdobeSendPluginToggle'     = 1
                    'bToggleAdobeDocumentServices' = 1
                    'bToggleFillSign'            = 1
                    'bToggleSendAndTrack'        = 1
                }
            }
            $acrobatPolicies += @{
                Path   = "$basePath\cIPM"
                Values = @{
                    'bShowMsgAtLaunch'              = 0
                    'bDontShowMsgWhenViewingDoc'    = 0
                }
            }
            $acrobatPolicies += @{
                Path   = "$basePath\cCloud"
                Values = @{ 'bDisableADCFileStore' = 1 }
            }
            $acrobatPolicies += @{
                Path   = "$basePath\cWelcomeScreen"
                Values = @{ 'bShowWelcomeScreen' = 0 }
            }
            $acrobatPolicies += @{
                Path   = "$basePath\cWebmailProfiles"
                Values = @{ 'bDisableWebmail' = 1 }
            }
            $acrobatPolicies += @{
                Path   = "$basePath\cSharePoint"
                Values = @{ 'bDisableSharePointFeatures' = 1 }
            }

            # DISA STIG v2r1 + NSA CTR hardening keys (Aggressive profile only)
            if ($Profile -eq 'Aggressive') {
                $acrobatPolicies += @{
                    Path   = $basePath
                    Values = @{
                        'bProtectedMode'                   = 1
                        'iProtectedView'                   = 2
                        'bEnhancedSecurityStandalone'       = 1
                        'bEnhancedSecurityInBrowser'        = 1
                        'iFileAttachmentPerms'              = 1
                        'bEnableFlash'                      = 0
                        'bDisableTrustedFolders'            = 1
                        'bDisableTrustedSites'              = 1
                        'bDisableOSTrustedSites'            = 1
                        'bEnableProtectedModeAppContainer'  = 1
                        'bEnableCertificateBasedTrust'      = 0
                    }
                }
                $acrobatPolicies += @{
                    Path   = "$basePath\cDefaultLaunchURLPerms"
                    Values = @{
                        'iURLPerms'        = 1
                        'iUnknownURLPerms' = 3
                    }
                }
            }
        }
    }

    foreach ($entry in $acrobatPolicies) {
        foreach ($name in $entry.Values.Keys) {
            $val = $entry.Values[$name]
            # Idempotent: check if already set
            if (Test-Path $entry.Path) {
                $current = (Get-ItemProperty -Path $entry.Path -Name $name -ErrorAction SilentlyContinue).$name
                if ($null -ne $current -and $current -eq $val) {
                    Write-Status "Already set: $($entry.Path)\$name = $val" -Type Warning
                    continue
                }
            }
            if ($DryRun) {
                Write-Status "Would set $($entry.Path)\$name = $val" -Type DryRun
                $script:Counters.RegistryKeysSet++
                continue
            }
            $regType = if ($entry.Type) { $entry.Type } else { 'DWord' }
            Set-RegistryValueTracked -Phase 'Acrobat' -Path $entry.Path -Name $name -Value $val -Type $regType
            Write-Status "Set $($entry.Path)\$name = $val" -Type Success
            $script:Counters.RegistryKeysSet++
        }
    }
}

# ── Undo Function ────────────────────────────────────────────────────────────

function Remove-HostsBlockByMarker {
    param(
        [string]$Path,
        [string]$Marker,
        [string]$EndMarker
    )
    if (-not (Test-Path $Path)) { return }
    $content = Get-Content $Path -Raw -ErrorAction SilentlyContinue
    if ($content -and $content -match [regex]::Escape($Marker)) {
        $pattern = "(?s)\r?\n?$([regex]::Escape($Marker)).*?$([regex]::Escape($EndMarker))\r?\n?"
        $content = $content -replace $pattern, ''
        Set-Content -Path $Path -Value $content.TrimEnd() -Force -Encoding ASCII
        Write-Status "Removed hosts block: $Marker" -Type Success
    }
}

function Invoke-ManifestUndo {
    if (-not (Test-Path $script:ManifestPath)) {
        Write-Status 'No undo manifest found; using legacy broad cleanup' -Type Warning
        return $false
    }

    try {
        $manifest = Get-Content $script:ManifestPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    } catch {
        Write-Status "Could not read undo manifest: $($_.Exception.Message)" -Type Warning
        return $false
    }

    if (-not $manifest.SchemaVersion -or [int]$manifest.SchemaVersion -lt 2) {
        Write-Status 'Undo manifest is from an older partial schema; using legacy broad cleanup' -Type Warning
        return $false
    }

    $actions = @($manifest.Actions)
    if ($actions.Count -eq 0) {
        Write-Status 'Undo manifest has no actions' -Type Warning
        return $true
    }

    Write-Status "Replaying $($actions.Count) manifest action(s) in reverse" -Type Header
    for ($idx = $actions.Count - 1; $idx -ge 0; $idx--) {
        $entry = $actions[$idx]
        $details = $entry.Details
        try {
            switch ($entry.Action) {
                'SetRegistryValue' {
                    Restore-RegistryValue `
                        -Path (Get-ManifestDetail $details 'Path') `
                        -Name (Get-ManifestDetail $details 'Name') `
                        -PreviousValue (Get-ManifestDetail $details 'PreviousValue') `
                        -PreviousExists ([bool](Get-ManifestDetail $details 'PreviousExists')) `
                        -PreviousType (Get-ManifestDetail $details 'PreviousType')
                }
                'DisableService' {
                    $name = Get-ManifestDetail $details 'Name'
                    $previousStartMode = Get-ManifestDetail $details 'PreviousStartMode'
                    $previousStatus = Get-ManifestDetail $details 'PreviousStatus'
                    if ($name) {
                        Set-ServiceStartMode -Name $name -StartMode $previousStartMode
                        if ($previousStatus -eq 'Running') {
                            Start-ServiceSilent -Name $name
                        }
                        Write-Status "Restored service state: $name ($previousStartMode)" -Type Success
                    }
                }
                'DisableScheduledTask' {
                    $taskName = Get-ManifestDetail $details 'TaskName'
                    $taskPath = Get-ManifestDetail $details 'TaskPath'
                    $previousState = Get-ManifestDetail $details 'PreviousState'
                    if ($taskName -and $previousState -ne 'Disabled') {
                        $task = if ($taskPath) {
                            Get-ScheduledTask -TaskName $taskName -TaskPath $taskPath -ErrorAction SilentlyContinue
                        } else {
                            Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
                        }
                        if ($task) {
                            $task | Enable-ScheduledTask -ErrorAction SilentlyContinue | Out-Null
                            Write-Status "Restored scheduled task: $taskName" -Type Success
                        }
                    }
                }
                'AddFirewallRule' {
                    $displayName = Get-ManifestDetail $details 'DisplayName'
                    if ($displayName) {
                        Get-NetFirewallRule -DisplayName $displayName -ErrorAction SilentlyContinue |
                            Remove-NetFirewallRule -ErrorAction SilentlyContinue
                        Write-Status "Removed firewall rule: $displayName" -Type Success
                    }
                }
                'AddRoute' {
                    $ip = Get-ManifestDetail $details 'IPAddress'
                    if ($ip) {
                        & route delete $ip 2>&1 | Out-Null
                        Write-Status "Removed persistent route: $ip" -Type Success
                    }
                }
                'HostsBlock' {
                    Remove-HostsBlockByMarker `
                        -Path (Get-ManifestDetail $details 'Path') `
                        -Marker (Get-ManifestDetail $details 'Marker') `
                        -EndMarker (Get-ManifestDetail $details 'EndMarker')
                    & ipconfig /flushdns 2>&1 | Out-Null
                }
                'RenameFile' {
                    $originalPath = Get-ManifestDetail $details 'OriginalPath'
                    $renamedPath = Get-ManifestDetail $details 'RenamedPath'
                    if ($renamedPath -and (Test-Path $renamedPath) -and $originalPath -and -not (Test-Path $originalPath)) {
                        Rename-Item -Path $renamedPath -NewName (Split-Path $originalPath -Leaf) -Force
                        Write-Status "Restored file: $originalPath" -Type Success
                    }
                }
                'RenameStartupShortcut' {
                    $originalPath = Get-ManifestDetail $details 'OriginalPath'
                    $renamedPath = Get-ManifestDetail $details 'RenamedPath'
                    if ($renamedPath -and (Test-Path $renamedPath) -and $originalPath -and -not (Test-Path $originalPath)) {
                        Rename-Item -Path $renamedPath -NewName (Split-Path $originalPath -Leaf) -Force
                        Write-Status "Restored startup shortcut: $originalPath" -Type Success
                    }
                }
                'SetAclDeny' {
                    Remove-DenyAclForEveryone -Path (Get-ManifestDetail $details 'Path')
                }
                'BlockDirectory' {
                    $path = Get-ManifestDetail $details 'Path'
                    if ($path -and (Test-Path $path -PathType Leaf)) {
                        Remove-DenyAclForEveryone -Path $path
                        Set-ItemProperty -Path $path -Name Attributes -Value 'Normal' -ErrorAction SilentlyContinue
                        Remove-Item -Path $path -Force -ErrorAction SilentlyContinue
                        Write-Status "Removed blocker file: $path" -Type Success
                    }
                }
                'DisableStartupValue' {
                    $path = Get-ManifestDetail $details 'Path'
                    $name = Get-ManifestDetail $details 'Name'
                    $previousValue = Get-ManifestDetail $details 'PreviousValue'
                    if ($path -and $name -and (Test-Path $path)) {
                        Set-ItemProperty -Path $path -Name $name -Value $previousValue -Force
                        Write-Status "Restored startup value: $path\$name" -Type Success
                    }
                }
                'AddDynamicKeyword' {
                    $dkId = Get-ManifestDetail $details 'Id'
                    $keyword = Get-ManifestDetail $details 'Keyword'
                    if ($dkId) {
                        Remove-NetFirewallDynamicKeywordAddress -Id $dkId -ErrorAction SilentlyContinue
                        Write-Status "Removed Dynamic Keyword: $keyword ($dkId)" -Type Success
                    }
                }
                'HostsBackup' {
                    $backupPath = Get-ManifestDetail $details 'BackupPath'
                    Write-Status "Hosts backup was saved at: $backupPath" -Type Info
                }
                'RemoveHostsBlock' {
                    Write-Status "WAM hosts injection was removed during apply" -Type Info
                }
                default {
                    Write-Status "Skipped manifest action type: $($entry.Action)" -Type Warning
                }
            }
        } catch {
            Write-Status "Manifest undo failed for $($entry.Action): $($_.Exception.Message)" -Type Error
        }
    }

    return $true
}

function Invoke-Undo {
    Write-Status 'UNDO - Reversing all telemetry blocks' -Type Header

    # 1. Re-enable disabled services
    Write-Status 'Re-enabling Adobe services' -Type Header
    foreach ($svcName in $Services) {
        $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
        if ($svc) {
            Set-Service -Name $svcName -StartupType Manual -ErrorAction SilentlyContinue
            Write-Status "Re-enabled service: $svcName (set to Manual)" -Type Success
        } else {
            Write-Status "Service not found: $svcName" -Type Warning
        }
    }

    # 2. Re-enable disabled scheduled tasks
    Write-Status 'Re-enabling Adobe scheduled tasks' -Type Header
    $allTasks = Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object {
        ($_.TaskName -like '*Adobe*' -or $_.TaskPath -like '*Adobe*') -and
        $_.State -eq 'Disabled'
    }
    if ($allTasks) {
        foreach ($task in $allTasks) {
            try {
                $task | Enable-ScheduledTask -ErrorAction Stop | Out-Null
                Write-Status "Re-enabled task: $($task.TaskName)" -Type Success
            } catch {
                Write-Status "Failed to re-enable task: $($task.TaskName)" -Type Error
            }
        }
    } else {
        Write-Status 'No disabled Adobe tasks found' -Type Warning
    }

    # 3. Remove firewall rules with "Block Adobe Telemetry" in display name
    Write-Status 'Removing Adobe telemetry firewall rules' -Type Header
    $fwRules = Get-NetFirewallRule -DisplayName 'Block Adobe Telemetry*' -ErrorAction SilentlyContinue
    if ($fwRules) {
        $fwRules | Remove-NetFirewallRule -ErrorAction SilentlyContinue
        Write-Status "Removed $(@($fwRules).Count) firewall rule(s)" -Type Success
    } else {
        Write-Status 'No Adobe telemetry firewall rules found' -Type Warning
    }

    # 3b. Remove Dynamic Keyword FQDN rules
    $existingDk = Get-NetFirewallDynamicKeywordAddress -ErrorAction SilentlyContinue |
        Where-Object { $_.Keyword -like '*adobe*' -or $_.Keyword -like '*demdex*' -or $_.Keyword -like '*adobedtm*' }
    if ($existingDk) {
        foreach ($dk in $existingDk) {
            Remove-NetFirewallDynamicKeywordAddress -Id $dk.Id -ErrorAction SilentlyContinue
        }
        Write-Status "Removed $(@($existingDk).Count) Dynamic Keyword address(es)" -Type Success
    }

    # 3c. Remove persistent null routes for telemetry IPs
    Write-Status 'Removing persistent null routes' -Type Header
    $routeOutput = route print 2>&1
    $routesRemoved = 0
    foreach ($domain in $TelemetryDomains) {
        try {
            $ips = [System.Net.Dns]::GetHostAddresses($domain) |
                   Where-Object { $_.AddressFamily -eq 'InterNetwork' } |
                   Select-Object -ExpandProperty IPAddressToString
            foreach ($ip in $ips) {
                if ($routeOutput -match [regex]::Escape($ip)) {
                    & route delete $ip 2>&1 | Out-Null
                    $routesRemoved++
                }
            }
        } catch { }
    }
    if ($routesRemoved -gt 0) {
        Write-Status "Removed $routesRemoved persistent null route(s)" -Type Success
    } else {
        Write-Status 'No persistent null routes found' -Type Warning
    }

    # 4. Remove hosts file block (between markers)
    Write-Status 'Removing hosts file telemetry block' -Type Header
    $hostsPath = "$env:SystemRoot\System32\drivers\etc\hosts"
    $marker    = '# --- Adobe Telemetry Block (Disable-AdobeTelemetry.ps1) ---'
    $endMarker = '# --- End Adobe Telemetry Block ---'
    $hostsContent = Get-Content $hostsPath -Raw -ErrorAction SilentlyContinue
    $hostsModified = $false
    # Remove WAM entries if present
    $wamMarker = '# Adobe Creative Cloud WAM - Start'
    $wamEndMarker = '# Adobe Creative Cloud WAM - End'
    if ($hostsContent -and $hostsContent -match [regex]::Escape($wamMarker)) {
        $wamPattern = "(?s)\r?\n?$([regex]::Escape($wamMarker)).*?$([regex]::Escape($wamEndMarker))\r?\n?"
        $hostsContent = $hostsContent -replace $wamPattern, ''
        $hostsModified = $true
        Write-Status 'Removed Adobe WAM hosts injection' -Type Success
    }
    if ($hostsContent -and $hostsContent -match [regex]::Escape($marker)) {
        $pattern = "(?s)\r?\n?$([regex]::Escape($marker)).*?$([regex]::Escape($endMarker))\r?\n?"
        $hostsContent = $hostsContent -replace $pattern, ''
        $hostsModified = $true
        Write-Status 'Removed Adobe telemetry block from hosts file' -Type Success
    } else {
        Write-Status 'No Adobe block found in hosts file' -Type Warning
    }
    if ($hostsModified) {
        Set-Content -Path $hostsPath -Value $hostsContent.TrimEnd() -Force -Encoding ASCII
        & ipconfig /flushdns 2>&1 | Out-Null
        Write-Status 'DNS cache flushed' -Type Info
    }

    # 5. Remove IFEO debugger entries for CCXProcess.exe
    Write-Status 'Removing IFEO debugger redirects' -Type Header
    $ifeoTargets = @('CCXProcess.exe', 'Creative Cloud Helper.exe', 'AdobeNotificationClient.exe')
    foreach ($ifeoExe in $ifeoTargets) {
        $ifeoPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\$ifeoExe"
        if (Test-Path $ifeoPath) {
            Remove-Item -Path $ifeoPath -Recurse -Force -ErrorAction SilentlyContinue
            Write-Status "Removed IFEO redirect for $ifeoExe" -Type Success
        } else {
            Write-Status "No IFEO redirect found for $ifeoExe" -Type Warning
        }
    }

    # 6. Restore CCXProcess.exe.disabled back to CCXProcess.exe
    Write-Status 'Restoring renamed executables' -Type Header
    $ccxPaths = @(
        "$env:ProgramFiles\Adobe\Adobe Creative Cloud Experience"
        "${env:ProgramFiles(x86)}\Adobe\Adobe Creative Cloud Experience"
    )
    foreach ($ccxDir in $ccxPaths) {
        if (-not (Test-Path $ccxDir)) { continue }
        $disabledExe = Join-Path $ccxDir 'CCXProcess.exe.disabled'
        if (Test-Path $disabledExe) {
            try {
                Rename-Item -Path $disabledExe -NewName 'CCXProcess.exe' -Force -ErrorAction Stop
                Write-Status "Restored CCXProcess.exe in $ccxDir" -Type Success
            } catch {
                Write-Status "Failed to restore CCXProcess.exe in $ccxDir" -Type Error
            }
        }
        $disabledNode = Join-Path $ccxDir 'libs\node.exe.disabled'
        if (Test-Path $disabledNode) {
            try {
                Rename-Item -Path $disabledNode -NewName 'node.exe' -Force -ErrorAction Stop
                Write-Status "Restored node.exe in $ccxDir\libs" -Type Success
            } catch {
                Write-Status "Failed to restore node.exe in $ccxDir\libs" -Type Error
            }
        }
        # Remove deny ACLs from CCXProcess.exe if present
        $ccxExe = Join-Path $ccxDir 'CCXProcess.exe'
        if (Test-Path $ccxExe) {
            try {
                $acl = Get-Acl $ccxExe
                $changed = $false
                foreach ($rule in @($acl.Access)) {
                    if ($rule.AccessControlType -eq 'Deny' -and
                        $rule.IdentityReference.Value -eq 'Everyone') {
                        $acl.RemoveAccessRule($rule) | Out-Null
                        $changed = $true
                    }
                }
                if ($changed) {
                    Set-Acl -Path $ccxExe -AclObject $acl
                    Write-Status "Removed deny ACL from CCXProcess.exe in $ccxDir" -Type Success
                }
            } catch { }
        }
    }

    # 7. Remove deny ACLs from GrowthSDK blocker files
    Write-Status 'Removing GrowthSDK blocker files' -Type Header
    $profileRoot = Split-Path $env:USERPROFILE
    $userProfiles = Get-ChildItem $profileRoot -Directory -ErrorAction SilentlyContinue
    foreach ($userProf in $userProfiles) {
        $localLow = Join-Path $userProf.FullName 'AppData\LocalLow'
        if (-not (Test-Path $localLow)) { continue }
        $growthDir = Join-Path $localLow $GrowthSDKRelPath
        if (Test-Path $growthDir -PathType Leaf) {
            try {
                # Remove deny ACL first so we can delete
                $acl = Get-Acl $growthDir
                foreach ($rule in @($acl.Access)) {
                    if ($rule.AccessControlType -eq 'Deny') {
                        $acl.RemoveAccessRule($rule) | Out-Null
                    }
                }
                Set-Acl -Path $growthDir -AclObject $acl
                # Remove readonly/system/hidden attributes
                Set-ItemProperty -Path $growthDir -Name Attributes -Value 'Normal'
                Remove-Item -Path $growthDir -Force -ErrorAction Stop
                Write-Status "Removed GrowthSDK blocker for $($userProf.Name)" -Type Success
            } catch {
                Write-Status "Failed to remove GrowthSDK blocker for $($userProf.Name)" -Type Error
            }
        }
    }

    # 8. Remove registry policy overrides
    Write-Status 'Removing registry policy overrides' -Type Header
    $regPathsToRemove = @(
        'HKLM:\SOFTWARE\Policies\Adobe\Common\Enterprise'
        'HKLM:\SOFTWARE\Policies\Adobe\CCXNew'
        'HKLM:\SOFTWARE\Policies\Adobe\Adobe Acrobat\DC\FeatureLockDown'
        'HKLM:\SOFTWARE\Policies\Adobe\Acrobat Reader\DC\FeatureLockDown'
        'HKLM:\SOFTWARE\Wow6432Node\Policies\Adobe\Adobe Acrobat\DC\FeatureLockDown'
        'HKLM:\SOFTWARE\Wow6432Node\Policies\Adobe\Acrobat Reader\DC\FeatureLockDown'
        'HKLM:\SOFTWARE\Policies\Adobe\Substance 3D'
    )
    foreach ($regPath in $regPathsToRemove) {
        if (Test-Path $regPath) {
            Remove-Item -Path $regPath -Recurse -Force -ErrorAction SilentlyContinue
            Write-Status "Removed $regPath" -Type Success
        }
    }
    # Remove specific values rather than whole keys for non-policy paths
    $specificValues = @(
        @{ Path = 'HKLM:\SOFTWARE\Adobe\Adobe Genuine Service'; Name = 'AgsDisabled' },
        @{ Path = 'HKCU:\SOFTWARE\Adobe\CommonFiles\UsageCC'; Name = 'AUSUF' },
        @{ Path = 'HKCU:\SOFTWARE\Adobe\Adobe Acrobat\DC\AVAlert\cCheckbox'; Name = 'iAcro498' },
        @{ Path = 'HKCU:\SOFTWARE\Adobe\Substance 3D Painter\Settings'; Name = 'enable_analytics' },
        @{ Path = 'HKCU:\SOFTWARE\Adobe\Substance 3D Designer\Settings'; Name = 'enable_analytics' },
        @{ Path = 'HKCU:\SOFTWARE\Adobe\Substance 3D Sampler\Settings'; Name = 'enable_analytics' },
        @{ Path = 'HKCU:\SOFTWARE\Adobe\CommonFiles\CRLog'; Name = 'Never Ask' },
        @{ Path = 'HKCU:\SOFTWARE\Adobe\Adobe Acrobat\DC\Workflows'; Name = 'bNeedSynchronizer' }
    )
    foreach ($sv in $specificValues) {
        if (Test-Path $sv.Path) {
            Remove-ItemProperty -Path $sv.Path -Name $sv.Name -Force -ErrorAction SilentlyContinue
            Write-Status "Removed $($sv.Path)\$($sv.Name)" -Type Success
        }
    }

    # 9. Re-enable startup entries (remove "REM " prefix)
    Write-Status 'Re-enabling Adobe startup entries' -Type Header
    $runPaths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
    )
    foreach ($runPath in $runPaths) {
        if (-not (Test-Path $runPath)) { continue }
        $props = Get-ItemProperty $runPath -ErrorAction SilentlyContinue
        foreach ($name in $props.PSObject.Properties.Name) {
            if ($name -match 'Adobe|CCXProcess|AdobeGC|AdobeAAM') {
                $val = $props.$name
                if ($val -like 'REM *') {
                    $restored = $val -replace '^REM ', ''
                    Set-ItemProperty -Path $runPath -Name $name -Value $restored -Force
                    Write-Status "Re-enabled startup entry: $name" -Type Success
                }
            }
        }
    }

    # 10. Remove watchdog task if installed
    Write-Status 'Removing watchdog task' -Type Header
    Remove-Watchdog

    Write-Status 'Undo Complete' -Type Header
    Write-Host '  All Adobe telemetry blocks have been reversed.' -ForegroundColor Green
    Write-Host '  A reboot is recommended to ensure all changes take effect.' -ForegroundColor Yellow
    Write-Host ''
}

# ── Status Function ──────────────────────────────────────────────────────────

function Get-StatusData {
    $statusData = [ordered]@{
        Version    = $script:Version
        Timestamp  = (Get-Date -Format 'o')
        Computer   = $env:COMPUTERNAME
        Services   = @()
        Tasks      = @()
        GrowthSDK  = @()
        Firewall   = @{ RuleCount = 0 }
        Connections = @{ Count = 0 }
        HostsFile  = @{ BlockPresent = $false }
        IFEO       = @()
        Registry   = @()
        Startup    = @()
        Watchdog   = @{ Installed = $false; State = 'NotInstalled' }
    }

    foreach ($svcName in $Services) {
        $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
        if ($svc) {
            $startType = (Get-CimInstance Win32_Service -Filter "Name='$svcName'" -ErrorAction SilentlyContinue).StartMode
            $statusData.Services += @{ Name = $svcName; Status = "$($svc.Status)"; StartMode = "$startType"; Blocked = ($svc.Status -eq 'Stopped' -or $startType -eq 'Disabled') }
        } else {
            $statusData.Services += @{ Name = $svcName; Status = 'NotFound'; StartMode = 'N/A'; Blocked = $true }
        }
    }

    $allTasks = Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object {
        $_.TaskName -like '*Adobe*' -or $_.TaskPath -like '*Adobe*'
    }
    if ($allTasks) {
        foreach ($task in $allTasks) {
            $statusData.Tasks += @{ Name = $task.TaskName; State = "$($task.State)"; Blocked = ($task.State -eq 'Disabled') }
        }
    }

    $profileRoot = Split-Path $env:USERPROFILE
    $userProfiles = Get-ChildItem $profileRoot -Directory -ErrorAction SilentlyContinue
    foreach ($userProf in $userProfiles) {
        $localLow = Join-Path $userProf.FullName 'AppData\LocalLow'
        if (-not (Test-Path $localLow)) { continue }
        $growthDir = Join-Path $localLow $GrowthSDKRelPath
        $state = if (Test-Path $growthDir -PathType Leaf) { 'Blocked' } elseif (Test-Path $growthDir -PathType Container) { 'Active' } else { 'NotFound' }
        $statusData.GrowthSDK += @{ User = $userProf.Name; State = $state }
    }

    $fwRules = Get-NetFirewallRule -DisplayName 'Block Adobe Telemetry*' -ErrorAction SilentlyContinue
    $statusData.Firewall.RuleCount = if ($fwRules) { @($fwRules).Count } else { 0 }

    $connections = @(Get-AdobeTelemetryConnections)
    $statusData.Connections.Count = $connections.Count

    $hostsPath = "$env:SystemRoot\System32\drivers\etc\hosts"
    $marker = '# --- Adobe Telemetry Block (Disable-AdobeTelemetry.ps1) ---'
    $hostsContent = Get-Content $hostsPath -Raw -ErrorAction SilentlyContinue
    $statusData.HostsFile.BlockPresent = ($hostsContent -and $hostsContent -match [regex]::Escape($marker))

    $ifeoCheckExes = @('CCXProcess.exe', 'Creative Cloud Helper.exe', 'AdobeNotificationClient.exe')
    foreach ($ifeoExe in $ifeoCheckExes) {
        $ifeoPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\$ifeoExe"
        $active = $false
        $debugger = $null
        if (Test-Path $ifeoPath) {
            $debugger = (Get-ItemProperty -Path $ifeoPath -Name 'Debugger' -ErrorAction SilentlyContinue).Debugger
            $active = [bool]$debugger
        }
        $statusData.IFEO += @{ Executable = $ifeoExe; Active = $active; Debugger = $debugger }
    }

    $regChecks = @(
        @{ Path = 'HKLM:\SOFTWARE\Policies\Adobe\Common\Enterprise'; Name = 'DisableUsageData'; Expected = 1 },
        @{ Path = 'HKLM:\SOFTWARE\Policies\Adobe\Common\Enterprise'; Name = 'DisableFileSync'; Expected = 1 },
        @{ Path = 'HKLM:\SOFTWARE\Policies\Adobe\Common\Enterprise'; Name = 'DisableAutoupdates'; Expected = 1 },
        @{ Path = 'HKLM:\SOFTWARE\Policies\Adobe\CCXNew'; Name = 'DisableGrowth'; Expected = 1 },
        @{ Path = 'HKLM:\SOFTWARE\Adobe\Adobe Genuine Service'; Name = 'AgsDisabled'; Expected = 1 },
        @{ Path = 'HKCU:\SOFTWARE\Adobe\CommonFiles\UsageCC'; Name = 'AUSUF'; Expected = 0 },
        @{ Path = 'HKLM:\SOFTWARE\Policies\Adobe\Adobe Acrobat\DC\FeatureLockDown'; Name = 'bUsageMeasurement'; Expected = 0 },
        @{ Path = 'HKLM:\SOFTWARE\Policies\Adobe\Adobe Acrobat\DC\FeatureLockDown'; Name = 'bAcroSuppressUpsell'; Expected = 1 },
        @{ Path = 'HKLM:\SOFTWARE\Policies\Adobe\Adobe Acrobat\DC\FeatureLockDown\cServices'; Name = 'bToggleAdobeSign'; Expected = 1 },
        @{ Path = 'HKLM:\SOFTWARE\Policies\Adobe\Adobe Acrobat\DC\FeatureLockDown\cIPM'; Name = 'bShowMsgAtLaunch'; Expected = 0 },
        @{ Path = 'HKLM:\SOFTWARE\Policies\Adobe\Acrobat Reader\DC\FeatureLockDown'; Name = 'bUsageMeasurement'; Expected = 0 },
        @{ Path = 'HKCU:\SOFTWARE\Adobe\CommonFiles\CRLog'; Name = 'Never Ask'; Expected = '1' },
        @{ Path = 'HKLM:\SOFTWARE\Policies\Adobe\Substance 3D'; Name = 'DisableAnalytics'; Expected = 1 },
        @{ Path = 'HKLM:\SOFTWARE\Policies\Adobe\Substance 3D'; Name = 'DisableTelemetry'; Expected = 1 },
        @{ Path = 'HKCU:\SOFTWARE\Adobe\Substance 3D Painter\Settings'; Name = 'enable_analytics'; Expected = 0 }
    )
    foreach ($check in $regChecks) {
        $val = $null
        $state = 'NotSet'
        if (Test-Path $check.Path) {
            $val = (Get-ItemProperty -Path $check.Path -Name $check.Name -ErrorAction SilentlyContinue).($check.Name)
            if ($null -ne $val) { $state = if ($val -eq $check.Expected) { 'Correct' } else { 'Incorrect' } }
        } else { $state = 'PathNotFound' }
        $statusData.Registry += @{ Name = $check.Name; State = $state; Value = $val; Expected = $check.Expected }
    }

    $runPaths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
    )
    foreach ($runPath in $runPaths) {
        if (-not (Test-Path $runPath)) { continue }
        $props = Get-ItemProperty $runPath -ErrorAction SilentlyContinue
        foreach ($name in $props.PSObject.Properties.Name) {
            if ($name -match 'Adobe|CCXProcess|AdobeGC|AdobeAAM') {
                $val = $props.$name
                $statusData.Startup += @{ Name = $name; Disabled = ($val -like 'REM *') }
            }
        }
    }

    $wdTask = Get-ScheduledTask -TaskName $script:WatchdogTaskName -ErrorAction SilentlyContinue
    if ($wdTask) {
        $statusData.Watchdog = @{ Installed = $true; State = "$($wdTask.State)" }
    }

    return $statusData
}

function Show-Status {
    $data = Get-StatusData

    if ($OutputFormat -eq 'JSON') {
        $data | ConvertTo-Json -Depth 5
        return
    }

    Write-Status 'Adobe Telemetry Status Report' -Type Header
    Write-Host ''

    Write-Host '  --- Services ---' -ForegroundColor Cyan
    foreach ($svc in $data.Services) {
        $color = if ($svc.Blocked) { 'Green' } elseif ($svc.Status -eq 'NotFound') { 'DarkGray' } else { 'Red' }
        Write-Host "    $($svc.Name) : $($svc.Status) ($($svc.StartMode))" -ForegroundColor $color
    }

    Write-Host ''
    Write-Host '  --- Scheduled Tasks ---' -ForegroundColor Cyan
    if ($data.Tasks.Count -gt 0) {
        foreach ($task in $data.Tasks) {
            $color = if ($task.Blocked) { 'Green' } else { 'Red' }
            Write-Host "    $($task.Name) : $($task.State)" -ForegroundColor $color
        }
    } else {
        Write-Host '    No Adobe scheduled tasks found' -ForegroundColor DarkGray
    }

    Write-Host ''
    Write-Host '  --- GrowthSDK ---' -ForegroundColor Cyan
    foreach ($gs in $data.GrowthSDK) {
        $color = switch ($gs.State) { 'Blocked' { 'Green' } 'Active' { 'Red' } default { 'DarkGray' } }
        Write-Host "    $($gs.User) : $($gs.State)" -ForegroundColor $color
    }

    Write-Host ''
    Write-Host '  --- Firewall Rules ---' -ForegroundColor Cyan
    $fwColor = if ($data.Firewall.RuleCount -gt 0) { 'Green' } else { 'Yellow' }
    Write-Host "    Adobe telemetry block rules: $($data.Firewall.RuleCount)" -ForegroundColor $fwColor

    Write-Host ''
    Write-Host '  --- Live Connections ---' -ForegroundColor Cyan
    $connColor = if ($data.Connections.Count -eq 0) { 'Green' } else { 'Yellow' }
    Write-Host "    Adobe-owned outbound TCP connections: $($data.Connections.Count)" -ForegroundColor $connColor

    Write-Host ''
    Write-Host '  --- Hosts File ---' -ForegroundColor Cyan
    if ($data.HostsFile.BlockPresent) {
        Write-Host '    Adobe telemetry block: Present' -ForegroundColor Green
    } else {
        Write-Host '    Adobe telemetry block: Not present' -ForegroundColor Yellow
    }

    Write-Host ''
    Write-Host '  --- IFEO Redirects ---' -ForegroundColor Cyan
    foreach ($ifeo in $data.IFEO) {
        if ($ifeo.Active) {
            Write-Host "    $($ifeo.Executable) IFEO: Active (Debugger=$($ifeo.Debugger))" -ForegroundColor Green
        } elseif ($null -eq $ifeo.Debugger -and (Test-Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\$($ifeo.Executable)")) {
            Write-Host "    $($ifeo.Executable) IFEO: Key exists but no Debugger value" -ForegroundColor Yellow
        } else {
            Write-Host "    $($ifeo.Executable) IFEO: Not set" -ForegroundColor Yellow
        }
    }

    Write-Host ''
    Write-Host '  --- Registry Policies ---' -ForegroundColor Cyan
    foreach ($reg in $data.Registry) {
        switch ($reg.State) {
            'Correct'      { Write-Host "    $($reg.Name) = $($reg.Value) (expected $($reg.Expected))" -ForegroundColor Green }
            'Incorrect'    { Write-Host "    $($reg.Name) = $($reg.Value) (expected $($reg.Expected))" -ForegroundColor Red }
            'NotSet'       { Write-Host "    $($reg.Name) : Not set" -ForegroundColor Yellow }
            'PathNotFound' { Write-Host "    $($reg.Name) : Path not found" -ForegroundColor Yellow }
        }
    }

    Write-Host ''
    Write-Host '  --- Startup Entries ---' -ForegroundColor Cyan
    if ($data.Startup.Count -gt 0) {
        foreach ($entry in $data.Startup) {
            $color = if ($entry.Disabled) { 'Green' } else { 'Red' }
            $state = if ($entry.Disabled) { 'Disabled' } else { 'Enabled (ACTIVE)' }
            Write-Host "    $($entry.Name) : $state" -ForegroundColor $color
        }
    } else {
        Write-Host '    No Adobe startup entries found' -ForegroundColor DarkGray
    }

    Write-Host ''
    Write-Host '  --- Watchdog ---' -ForegroundColor Cyan
    if ($data.Watchdog.Installed) {
        Write-Host "    $($script:WatchdogTaskName) : $($data.Watchdog.State)" -ForegroundColor Green
    } else {
        Write-Host "    $($script:WatchdogTaskName) : Not installed" -ForegroundColor DarkGray
    }

    Write-Host ''
}

# ── Summary Function ──────────────────────────────────────────────────────────

function Show-Summary {
    $c = $script:Counters
    $mode = if ($DryRun) { 'DRY RUN' } else { 'APPLIED' }

    Write-Host ''
    Write-Host '  =============================================' -ForegroundColor Cyan
    Write-Host "   Summary ($mode)" -ForegroundColor White
    Write-Host '  =============================================' -ForegroundColor Cyan

    $items = @(
        @{ Label = 'Processes killed';     Count = $c.ProcessesKilled;   Color = 'Yellow' }
        @{ Label = 'GrowthSDK blocked';    Count = $c.GrowthSDKBlocked;  Color = 'Green' }
        @{ Label = 'Executables neutralized'; Count = $c.ExesNeutralized; Color = 'Green' }
        @{ Label = 'Tasks disabled';       Count = $c.TasksDisabled;     Color = 'Green' }
        @{ Label = 'Services disabled';    Count = $c.ServicesDisabled;   Color = 'Green' }
        @{ Label = 'Registry keys set';    Count = $c.RegistryKeysSet;   Color = 'Green' }
        @{ Label = 'Firewall rules added'; Count = $c.FirewallRulesAdded; Color = 'Green' }
        @{ Label = 'Telemetry IPs blocked'; Count = $c.FirewallIPsBlocked; Color = 'Green' }
        @{ Label = 'Domains sinkholed';    Count = $c.DomainsBlocked;    Color = 'Green' }
        @{ Label = 'Startup entries disabled'; Count = $c.StartupDisabled; Color = 'Green' }
    )

    foreach ($item in $items) {
        $color = if ($item.Count -gt 0) { $item.Color } else { 'DarkGray' }
        Write-Host "    $($item.Label): $($item.Count)" -ForegroundColor $color
    }

    if ($c.ConnectionsBefore -ge 0 -and $c.ConnectionsAfter -ge 0) {
        $connectionColor = if ($c.ConnectionsAfter -lt $c.ConnectionsBefore) { 'Green' } elseif ($c.ConnectionsAfter -eq 0) { 'Green' } else { 'Yellow' }
        Write-Host "    Live Adobe outbound connections: $($c.ConnectionsBefore) -> $($c.ConnectionsAfter)" -ForegroundColor $connectionColor
    }

    Write-Host ''
}

# ── Launcher Mode ──────────────────────────────────────────────────────────────

function Get-AdobeTelemetryConnections {
    $adobeProcessIds = @{}
    Get-Process -ErrorAction SilentlyContinue | ForEach-Object {
        $path = $null
        try { $path = $_.Path } catch { }
        if ($_.ProcessName -match 'Adobe|CCX|Creative Cloud|CoreSync|Acro|RdrCEF|Substance|Dimension|LogTransport|CRLog' -or
            ($path -and $path -match '\\Adobe\\')) {
            $adobeProcessIds[$_.Id] = @{
                Name = $_.ProcessName
                Path = $path
            }
        }
    }

    if ($adobeProcessIds.Count -eq 0) {
        return @()
    }

    $connections = Get-NetTCPConnection -ErrorAction SilentlyContinue | Where-Object {
        $adobeProcessIds.ContainsKey($_.OwningProcess) -and
        $_.RemoteAddress -and
        $_.RemoteAddress -notin @('0.0.0.0', '::', '127.0.0.1', '::1')
    }

    foreach ($connection in $connections) {
        $proc = $adobeProcessIds[$connection.OwningProcess]
        [pscustomobject]@{
            ProcessName   = $proc.Name
            ProcessId     = $connection.OwningProcess
            LocalAddress  = $connection.LocalAddress
            LocalPort     = $connection.LocalPort
            RemoteAddress = $connection.RemoteAddress
            RemotePort    = $connection.RemotePort
            State         = $connection.State
            Path          = $proc.Path
        }
    }
}

function Show-ConnectionReport {
    Write-Status 'Adobe outbound connection report' -Type Header
    $connections = @(Get-AdobeTelemetryConnections)
    if ($connections.Count -eq 0) {
        Write-Host '    No live Adobe-owned outbound TCP connections found' -ForegroundColor Green
        Write-Status 'No live Adobe-owned outbound TCP connections found' -Type Success
        return
    }

    Write-Host "    Live Adobe-owned outbound TCP connections: $($connections.Count)" -ForegroundColor Yellow
    foreach ($connection in $connections) {
        $line = "{0}({1}) -> {2}:{3} [{4}]" -f $connection.ProcessName, $connection.ProcessId, $connection.RemoteAddress, $connection.RemotePort, $connection.State
        Write-Host "    $line" -ForegroundColor Yellow
        Write-Status $line -Type Info
    }
}

function Find-AdobeAppExecutable {
    param([string]$AppName)
    $exeName = $AdobeAppExecutables[$AppName]
    if (-not $exeName) {
        $exeName = "$AppName.exe"
    }

    foreach ($installPath in $script:AdobeInstallPaths) {
        if (-not (Test-Path $installPath)) { continue }
        $found = Get-ChildItem -Path $installPath -Filter $exeName -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($found) { return $found.FullName }
    }
    return $null
}

function Invoke-WfpTrace {
    Write-Status 'Windows Filtering Platform trace capture' -Type Header
    Initialize-AppDataDirectory
    $outputPath = $TraceOutput
    if (-not $outputPath) {
        $outputPath = Join-Path $script:LogDir ("adobe-wfp-{0}.cab" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    }

    if ($DryRun) {
        Write-Status "Would capture WFP trace for $TraceMinutes minute(s) to $outputPath" -Type DryRun
        return
    }

    Write-Status "Starting WFP capture to $outputPath" -Type Info
    & netsh wfp capture start file="$outputPath" 2>&1 | Add-Content -Path $script:LogFile -ErrorAction SilentlyContinue
    try {
        Start-Sleep -Seconds ($TraceMinutes * 60)
    } finally {
        & netsh wfp capture stop 2>&1 | Add-Content -Path $script:LogFile -ErrorAction SilentlyContinue
    }
    Write-Status "WFP capture saved to $outputPath" -Type Success
}

function Invoke-PlumbingTest {
    param(
        [string]$AppName,
        [int]$Minutes
    )
    Write-Status "Plumbing test: $AppName for $Minutes minute(s)" -Type Header
    $appExe = Find-AdobeAppExecutable -AppName $AppName
    if (-not $appExe) {
        Write-Status "Could not find Adobe app executable for $AppName" -Type Error
        exit 1
    }

    Initialize-AppDataDirectory
    $captureRoot = Join-Path $script:LogDir ("plumbing-{0}-{1}" -f $AppName, (Get-Date -Format 'yyyyMMdd-HHmmss'))
    New-Item -Path $captureRoot -ItemType Directory -Force | Out-Null
    $connectionLog = Join-Path $captureRoot 'connections.jsonl'
    $netstatLog = Join-Path $captureRoot 'netstat.txt'
    $processLog = Join-Path $captureRoot 'processes.jsonl'

    Stop-AdobeProcesses
    Write-Status "Launching $AppName from $appExe" -Type Info
    $proc = Start-Process -FilePath $appExe -PassThru
    $deadline = (Get-Date).AddMinutes($Minutes)
    while ((Get-Date) -lt $deadline) {
        $connections = @(Get-AdobeTelemetryConnections)
        $sample = [ordered]@{
            timestamp   = (Get-Date -Format 'o')
            app         = $AppName
            appPid      = $proc.Id
            connections = $connections
        }
        ($sample | ConvertTo-Json -Depth 5 -Compress) | Add-Content -Path $connectionLog -Encoding UTF8
        & netstat.exe -ano 2>&1 | Add-Content -Path $netstatLog
        $adobeProcesses = Get-Process -ErrorAction SilentlyContinue | Where-Object {
            $_.ProcessName -match 'Adobe|CCX|Creative Cloud|CoreSync|Acro|RdrCEF|Substance|Dimension|LogTransport|CRLog'
        } | Select-Object Id, ProcessName, StartTime, Path
        [ordered]@{
            timestamp = (Get-Date -Format 'o')
            processes = $adobeProcesses
        } | ConvertTo-Json -Depth 4 -Compress | Add-Content -Path $processLog -Encoding UTF8
        Start-Sleep -Seconds 10
    }

    Stop-AdobeProcesses
    Write-Status "Plumbing test artifacts saved to $captureRoot" -Type Success
}

function Invoke-CleanLauncher {
    param([string]$AppName)

    $appExe = Find-AdobeAppExecutable -AppName $AppName
    if (-not $appExe) {
        Write-Status "Could not find Adobe app executable for $AppName" -Type Error
        exit 1
    }

    Write-Status "Clean Launcher: $AppName" -Type Header
    Write-Status "Executable: $appExe" -Type Info

    # Kill telemetry processes before launch
    Stop-AdobeProcesses

    # Launch the app
    Write-Status "Launching $AppName..." -Type Info
    $proc = Start-Process -FilePath $appExe -PassThru

    try {
        Write-Status "Waiting for $AppName to exit (PID $($proc.Id))..." -Type Info
        $proc.WaitForExit()
        Write-Status "$AppName exited" -Type Info
    } finally {
        Start-Sleep -Seconds 2
        Stop-AdobeProcesses
        Write-Status 'Telemetry processes cleaned up' -Type Success
    }
}

# ── Watchdog Scheduled Task ───────────────────────────────────────────────────

$script:WatchdogTaskName = 'Disable-AdobeTelemetry Watchdog'

function Install-Watchdog {
    $scriptFullPath = $PSCommandPath
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$scriptFullPath`" -Skip Kill"
    $trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Monday -At '09:00'
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 10)

    $existing = Get-ScheduledTask -TaskName $script:WatchdogTaskName -ErrorAction SilentlyContinue
    if ($existing) {
        Set-ScheduledTask -TaskName $script:WatchdogTaskName -Action $action -Trigger $trigger `
            -Principal $principal -Settings $settings -ErrorAction SilentlyContinue | Out-Null
        Write-Status "Updated watchdog task: $($script:WatchdogTaskName)" -Type Success
    } else {
        Register-ScheduledTask -TaskName $script:WatchdogTaskName -Action $action -Trigger $trigger `
            -Principal $principal -Settings $settings -Description 'Weekly reassertion of Adobe telemetry blocks after updates' `
            -ErrorAction SilentlyContinue | Out-Null
        Write-Status "Installed watchdog task: $($script:WatchdogTaskName) (Mondays 9 AM)" -Type Success
    }
}

function Remove-Watchdog {
    $existing = Get-ScheduledTask -TaskName $script:WatchdogTaskName -ErrorAction SilentlyContinue
    if ($existing) {
        Unregister-ScheduledTask -TaskName $script:WatchdogTaskName -Confirm:$false -ErrorAction SilentlyContinue
        Write-Status "Removed watchdog task: $($script:WatchdogTaskName)" -Type Success
    } else {
        Write-Status 'No watchdog task found' -Type Warning
    }
}

# ── Profile Export/Import ─────────────────────────────────────────────────────

function Export-RunProfile {
    param([string]$Path)
    $profileData = @{
        Version   = $script:Version
        CreatedAt = (Get-Date -Format 'o')
        Profile   = $Profile
        Only      = $Only
        Skip      = $Skip
        Domains   = $TelemetryDomains
    }
    $profileData | ConvertTo-Json -Depth 3 | Set-Content -Path $Path -Force -Encoding UTF8
    Write-Status "Profile exported to $Path" -Type Success
}

function Import-RunProfile {
    param([string]$Path)
    if (-not (Test-Path $Path)) {
        Write-Status "Profile not found: $Path" -Type Error
        exit 1
    }
    $profileData = Get-Content $Path -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json
    if ($profileData.Only) { $script:Only = @($profileData.Only) }
    if ($profileData.Skip) { $script:Skip = @($profileData.Skip) }
    if ($profileData.Domains) { $script:TelemetryDomains = @($profileData.Domains) }
    Write-Status "Profile loaded from $Path (Profile: $($profileData.Profile))" -Type Success
}

# ── Main Execution ──────────────────────────────────────────────────────────────

function Invoke-ProtectionPhases {
    $script:Counters.ConnectionsBefore = @(Get-AdobeTelemetryConnections).Count

    if ((Test-PhaseEnabled 'Firewall') -or (Test-PhaseEnabled 'Hosts')) {
        Merge-UpstreamDomains
    }

    if (Test-PhaseEnabled 'Kill')      { Stop-AdobeProcesses }
    if (Test-PhaseEnabled 'GrowthSDK') { Remove-GrowthSDK }
    if (Test-PhaseEnabled 'CCXProcess') { Disable-CCXProcess }
    if (Test-PhaseEnabled 'IPCBroker') { Disable-AdobeIPCBroker }
    if (Test-PhaseEnabled 'Tasks')     { Disable-AdobeScheduledTasks }
    if (Test-PhaseEnabled 'Services')  { Disable-AdobeServices }
    if (Test-PhaseEnabled 'Registry')  { Set-AdobeRegistryPolicies }
    if (Test-PhaseEnabled 'Firewall')  { Block-AdobeFirewall }
    if (Test-PhaseEnabled 'Hosts')     { Block-AdobeHostsFile }
    if (Test-PhaseEnabled 'Acrobat')   { Disable-AcrobatTelemetry }
    if (Test-PhaseEnabled 'Startup')   { Disable-AdobeStartupEntries }

    Save-Manifest
    $script:Counters.ConnectionsAfter = @(Get-AdobeTelemetryConnections).Count
}

# Handle special modes before the standard flow
if ($InstallWatchdog) {
    Install-Watchdog
    exit 0
}
if ($RemoveWatchdog) {
    Remove-Watchdog
    exit 0
}
if ($ExportProfile) {
    Export-RunProfile -Path $ExportProfile
    exit 0
}
if ($ImportProfile) {
    Import-RunProfile -Path $ImportProfile
}

if ($ConnectionReport) {
    Show-ConnectionReport
    exit 0
}

if ($WfpTrace) {
    Invoke-WfpTrace
    exit 0
}

if ($Launcher) {
    Invoke-CleanLauncher -AppName $Launcher
    exit 0
}

Write-Host ''
Write-Host '  =============================================' -ForegroundColor Cyan
Write-Host "   Disable-AdobeTelemetry $script:DisplayVersion" -ForegroundColor White
Write-Host '   Comprehensive Adobe GrowthSDK + Telemetry' -ForegroundColor White
Write-Host '   Removal and Blocking Utility' -ForegroundColor White
Write-Host '  =============================================' -ForegroundColor Cyan

if ($DryRun) {
    Write-Host ''
    Write-Host '  *** DRY RUN MODE - No changes will be made ***' -ForegroundColor Magenta
}

if ($Verbose) {
    Write-Host '  Verbose rationale: enabled' -ForegroundColor Yellow
}
if ($Profile -ne 'Standard') {
    Write-Host "  Profile: $Profile" -ForegroundColor Yellow
}
if ($Only -and $Only.Count -gt 0) {
    Write-Host "  Phases: $($Only -join ', ')" -ForegroundColor Yellow
}
if ($Skip -and $Skip.Count -gt 0) {
    Write-Host "  Skipping: $($Skip -join ', ')" -ForegroundColor Yellow
}

# Initialize log
$logHeader = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - Disable-AdobeTelemetry $script:DisplayVersion started"
if ($Undo)       { $logHeader += ' (UNDO mode)' }
if ($StatusOnly) { $logHeader += ' (STATUS mode)' }
if ($DryRun)     { $logHeader += ' (DRY RUN mode)' }
if ($Profile -ne 'Standard') { $logHeader += " (Profile: $Profile)" }
if ($Only)       { $logHeader += " (Only: $($Only -join ','))" }
if ($Skip)       { $logHeader += " (Skip: $($Skip -join ','))" }
if ($Verbose)    { $logHeader += ' (Verbose rationale)' }
Add-Content -Path $script:LogFile -Value $logHeader -ErrorAction SilentlyContinue

if ($StatusOnly) {
    Show-Status
    exit 0
}

if ($Undo) {
    $manifestHandled = Invoke-ManifestUndo
    if (-not $manifestHandled) {
        Invoke-Undo
    } else {
        # Remove watchdog regardless of manifest path
        Remove-Watchdog
        Write-Status 'Manifest-driven undo complete' -Type Header
        Write-Host '  All recorded telemetry blocks have been reversed.' -ForegroundColor Green
        Write-Host '  A reboot is recommended to ensure all changes take effect.' -ForegroundColor Yellow
        Write-Host ''
    }
    # Remove the consumed manifest so a fresh run produces a new one
    if (Test-Path $script:ManifestPath) {
        Remove-Item -Path $script:ManifestPath -Force -ErrorAction SilentlyContinue
    }
    exit 0
}

# Pre-run check: warn if Adobe creative apps are open
$adobeApps = Get-Process -ErrorAction SilentlyContinue | Where-Object {
    $_.ProcessName -match '^(Photoshop|Illustrator|AfterFX|Premiere Pro|Adobe Premiere Pro|InDesign|Lightroom|Adobe Substance|Adobe Dimension|Audition|InCopy|Animate|Adobe Media Encoder|AdobeCollabSync)$'
}
if ($adobeApps) {
    $appNames = ($adobeApps | Select-Object -ExpandProperty ProcessName -Unique) -join ', '
    Write-Host ''
    Write-Host '  WARNING: Adobe application(s) currently running: ' -ForegroundColor Yellow -NoNewline
    Write-Host $appNames -ForegroundColor Red
    Write-Host '  For best results, close all Adobe apps before running this script.' -ForegroundColor Yellow
    Write-Host '  Some operations may fail or require a reboot to take full effect.' -ForegroundColor Yellow
    Write-Host ''
}

# Create system restore point before making changes
if (-not $DryRun) {
    try {
        Checkpoint-Computer -Description 'Pre-Disable-AdobeTelemetry' -RestorePointType MODIFY_SETTINGS -ErrorAction Stop
        Write-Status 'System restore point created' -Type Success
    } catch {
        Write-Status "Could not create restore point: $($_.Exception.Message)" -Type Warning
    }
} else {
    Write-Status 'Would create system restore point' -Type DryRun
}

Invoke-ProtectionPhases

if ($PlumbingTest) {
    Invoke-PlumbingTest -AppName $PlumbingApp -Minutes $PlumbingMinutes
}

Show-Summary

if ($DryRun) {
    Write-Host '  No changes were made (dry run).' -ForegroundColor Magenta
} else {
    Write-Host '  All Adobe telemetry and GrowthSDK components have been disabled.' -ForegroundColor Green
    Write-Host '  A reboot is recommended to ensure all changes take effect.' -ForegroundColor Yellow
}
Write-Host '  Note: Premiere/Photoshop will continue to function normally.' -ForegroundColor Gray
Write-Host "  Log saved to: $script:LogFile" -ForegroundColor Gray
Write-Host "  JSONL log saved to: $script:JsonLogFile" -ForegroundColor Gray
Write-Host ''

# Exit codes: 0=success/dry-run, 1=fatal, 3=partial success, 3010=success+reboot recommended
if ($DryRun) {
    exit 0
} elseif ($script:Counters.Errors -gt 0) {
    exit 3
} else {
    exit 3010
}
