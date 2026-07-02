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

.PARAMETER ShowRationale
    Shows a brief explanation ("Why") for each phase action. Alias: -Verbose (for
    backward compatibility; the parameter was renamed to avoid shadowing PowerShell's
    automatic $VerbosePreference variable).

.PARAMETER OutputFormat
    Output format for -StatusOnly: Text (default, colored console output) or JSON
    (machine-readable structured output for fleet management tools).

.PARAMETER LockHostsFile
    After writing the hosts block, add a Deny-Write ACE for NT AUTHORITY\SYSTEM on the
    hosts file so Adobe WAM (which runs as SYSTEM) cannot re-inject its detection entry.
    Opt-in: the weekly watchdog task runs as SYSTEM, so locking the hosts file prevents
    the watchdog from reasserting hosts entries (firewall/IFEO reassertion is unaffected).
    Fully reversed by -Undo.

.NOTES
    Author  : Matt (Maven Imaging)
    Version : 2.4.1
    Date    : 2026-07-01

    Exit codes:
      0    = Success (no reboot needed) or dry run completed
      1    = Fatal error (invalid arguments, missing executable)
      2    = Invalid arguments
      3    = Partial success (some phases encountered errors)
      3010 = Success, reboot recommended (SCCM/Intune convention)
#>

#Requires -Version 5.1

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
    [Alias('Verbose')]
    [switch]$ShowRationale,
    [switch]$LockHostsFile,
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
    if ($ShowRationale) { $argList += '-ShowRationale' }
    if ($OutputFormat -ne 'Text') { $argList += '-OutputFormat'; $argList += $OutputFormat }
    Start-Process powershell.exe -Verb RunAs -ArgumentList $argList
    exit 0
}

# ── Config ──────────────────────────────────────────────────────────────────────

$ErrorActionPreference = 'Continue'

$script:DisplayVersion = 'v2.4.1'
$script:Version = $script:DisplayVersion.TrimStart('v')
$script:LogFile = Join-Path $env:TEMP 'Disable-AdobeTelemetry.log'
$script:LogDir = Join-Path $env:APPDATA 'Disable-AdobeTelemetry\logs'
$script:JsonLogFile = Join-Path $script:LogDir ("Disable-AdobeTelemetry-{0}.jsonl" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))

# ── Undo Manifest ────────────────────────────────────────────────────────────
# JSON manifest recording every action so -Undo can be fully deterministic
$script:ManifestDir = Join-Path $env:APPDATA 'Disable-AdobeTelemetry'
$script:ManifestPath = Join-Path $script:ManifestDir 'undo-manifest.json'
$script:UpstreamCachePath = Join-Path $script:ManifestDir 'upstream-domains-cache.json'
$script:ManifestActions = @()

$script:AppDataInitialized = $false
function Initialize-AppDataDirectory {
    # Called on every log message; short-circuit after the first successful init so we
    # don't stat the filesystem twice per line for the life of the run.
    if ($script:AppDataInitialized) { return }
    if (-not (Test-Path $script:ManifestDir)) {
        New-Item -Path $script:ManifestDir -ItemType Directory -Force | Out-Null
    }
    if (-not (Test-Path $script:LogDir)) {
        New-Item -Path $script:LogDir -ItemType Directory -Force | Out-Null
    }
    $script:AppDataInitialized = $true
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
    # -Skip always wins, including when combined with -Only, so that
    # `-Only Firewall,Hosts -Skip Hosts` runs only Firewall (not Hosts).
    if ($Skip -and $Skip.Count -gt 0 -and ($Skip -contains $Phase)) {
        return $false
    }
    if ($Only -and $Only.Count -gt 0) {
        return ($Only -contains $Phase)
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
    VerificationFailures = 0
    Errors            = 0
}

# BEGIN INVENTORY:Processes
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
    'AdobeExtensionsService'
    'Adobe Content Synchronizer'
    'node'  # Adobe CEF/Node helpers - filtered by path below
)
# END INVENTORY:Processes

# BEGIN INVENTORY:Paths
$GrowthSDKRelPath = 'Adobe\GrowthSDK'

$AdditionalPaths = @(
    'Adobe\OOBE\opm.db'
    'Adobe\OOBE\PDApp\CCM\Telemetry'
)

$AdobeAppExecutables = @{
    'Acrobat'           = 'Acrobat.exe'
    'AfterEffects'      = 'AfterFX.exe'
    'Animate'           = 'Animate.exe'
    'Audition'          = 'Adobe Audition.exe'
    'Dimension'         = 'Adobe Dimension.exe'
    'Illustrator'       = 'Illustrator.exe'
    'InDesign'          = 'InDesign.exe'
    'Lightroom'         = 'Lightroom.exe'
    'LightroomClassic'  = 'Lightroom.exe'
    'MediaEncoder'      = 'Adobe Media Encoder.exe'
    'Photoshop'         = 'Photoshop.exe'
    'Premiere'          = 'Adobe Premiere Pro.exe'
    'PremierePro'       = 'Adobe Premiere Pro.exe'
    'Reader'            = 'AcroRd32.exe'
    'SubstanceDesigner' = 'Adobe Substance 3D Designer.exe'
    'SubstancePainter'  = 'Adobe Substance 3D Painter.exe'
    'SubstanceSampler'  = 'Adobe Substance 3D Sampler.exe'
    'SubstanceStager'   = 'Adobe Substance 3D Stager.exe'
}
# END INVENTORY:Paths

# BEGIN INVENTORY:Services
$Services = @(
    'AGSService'                    # Adobe Genuine Software Integrity
    'AGMService'                    # Adobe Genuine Monitor
    'AdobeARMservice'               # Adobe Acrobat Update Service
    'AdobeUpdateService'            # Adobe Update Service
    'CCXProcess'
)
# END INVENTORY:Services

# BEGIN INVENTORY:Domains
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
    'lcs-cops.adobe.io'
    'lcs-robs.adobe.io'
    'lcs-ulecs.adobe.io'
    'lcs-entitlement.adobe.io'
    'cc-cdn.adobe.com'
    'platform.adobe.io'
    'adobeid-na1.services.adobe.com'
    'na1r.services.adobe.com'
    'genuine.adobe.com'
    'prod.adobegenuine.com'
    'prod-rel-ffc-ccm.oobesaas.adobe.com'
    'odin.adobe.com'
    'armmf.adobe.com'
    'client.messaging.adobe.com'
    'server.messaging.adobe.com'
    'ui.messaging.adobe.com'
    'firefly-ae.adobe.io'
    'fire-fly.adobe.io'
    'dc-genai-access-provisioning-api.adobe.io'
    'hz-telemetry.adobe.io'
    'hz-telemetry-next.adobe.io'
    'sensei-irl1.adobe.io'
    'senseicore-ew1.adobe.io'
    'o1383653.ingest.sentry.io'
    'o1383653.ingest.us.sentry.io'
    'scss.adobesc.com'
    'scss-prod-ew1.adobesc.com'
    'dcs.adobedc.net'
    'adobe.tt.omtrdc.net'
    'analytics.adobe.com'
    'hbc.adobe.io'
    'js-agent.newrelic.com'
    'acp-ss-ew1.adobe.io'
    'cc-collab.adobe.io'
    'cdn.experience.adobe.net'
)
$TelemetryDomainsAggressive = $TelemetryDomainsStandard + @(
    'use.typekit.net'
    'p.typekit.net'
    'data.typekit.net'
    'polka.typekit.com'
    'cctypekit.adobe.io'
    'cclibraries-defaults-cdn.adobe.com'
    'services.adobe.com'
    'firefly-client-service-prod-va6.adobe.io'
    'firefly-clio-imaging-preview.adobe.io'
    'ccext.adobe.io'
    'ccext-public.adobe.io'
    'cchome.adobe.io'
    'adobesearch.adobe.io'
    'abp-profile-service.adobe.io'
    'rum.hlx.page'
)

$TelemetryDomains = switch ($Profile) {
    'Minimal'    { $TelemetryDomainsMinimal }
    'Aggressive' { $TelemetryDomainsAggressive }
    default      { $TelemetryDomainsStandard }
}

$script:DomainSafelist = @(
    'ims-na1.adobelogin.com'
    'ims-prod06.adobelogin.com'
    'ims-prod07.adobelogin.com'
    'auth-light.identity.adobe.com'
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
# END INVENTORY:Domains

# Optionally merge upstream domains from a-dove-is-dumb community list
$script:UpstreamUrl = 'https://a.dove.isdumb.one/list.txt'
function Get-UpstreamDomainMergeResult {
    param(
        [string]$RawContent,
        [string[]]$ExistingDomains,
        [string]$Source = 'Network',
        [datetime]$FetchedAt = (Get-Date)
    )

    $accepted = @()
    $safelisted = @()
    $rejected = @()
    $existingSet = @{}
    foreach ($domain in @($ExistingDomains)) {
        if ($domain) { $existingSet[[string]$domain.ToLowerInvariant()] = $true }
    }

    foreach ($line in ($RawContent -split "`r?`n")) {
        $trimmed = $line.Trim()
        if (-not $trimmed -or $trimmed -match '^\s*#') { continue }
        $trimmed = ($trimmed -split '\s+#', 2)[0].Trim()
        $parts = $trimmed -split '\s+'
        $candidate = if ($parts.Count -gt 1 -and $parts[0] -match '^(0\.0\.0\.0|127\.0\.0\.1|::)$') { $parts[1] } else { $parts[0] }
        $candidate = $candidate.Trim().Trim('|').Trim('^').ToLowerInvariant()

        if ($candidate -notmatch '^[a-z0-9]([a-z0-9\-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9\-]*[a-z0-9])?)+$') {
            $rejected += $trimmed
            continue
        }

        if ($script:DomainSafelist -contains $candidate) {
            $safelisted += $candidate
            continue
        }

        $accepted += $candidate
    }

    $accepted = @($accepted | Sort-Object -Unique)
    $safelisted = @($safelisted | Sort-Object -Unique)
    $rejected = @($rejected | Sort-Object -Unique)
    $added = @($accepted | Where-Object { -not $existingSet.ContainsKey($_) })
    $finalDomains = @($ExistingDomains + $accepted | Sort-Object -Unique)

    return [ordered]@{
        Url = $script:UpstreamUrl
        Source = $Source
        FetchedAt = $FetchedAt.ToString('o')
        AcceptedDomains = $accepted
        AddedDomains = $added
        SafelistedDomains = $safelisted
        RejectedMalformedEntries = $rejected
        FinalCount = $finalDomains.Count
    }
}

function Save-UpstreamDomainCache {
    param($MergeResult)
    if ($DryRun -or -not $MergeResult -or $MergeResult.Source -ne 'Network') { return }
    Initialize-AppDataDirectory
    [ordered]@{
        Url = $MergeResult.Url
        FetchedAt = $MergeResult.FetchedAt
        Domains = @($MergeResult.AcceptedDomains)
    } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $script:UpstreamCachePath -Encoding UTF8 -Force
}

function Get-UpstreamDomainCacheResult {
    if (-not (Test-Path -LiteralPath $script:UpstreamCachePath)) { return $null }
    try {
        $cache = Get-Content -LiteralPath $script:UpstreamCachePath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        $domains = @($cache.Domains) | Where-Object { $_ }
        if ($domains.Count -eq 0) { return $null }
        $raw = ($domains -join "`n")
        $fetchedAt = if ($cache.FetchedAt) { [datetime]$cache.FetchedAt } else { Get-Date }
        return Get-UpstreamDomainMergeResult -RawContent $raw -ExistingDomains $script:TelemetryDomains -Source 'Cache' -FetchedAt $fetchedAt
    } catch {
        return $null
    }
}

function Write-UpstreamMergeAudit {
    param($MergeResult)
    if (-not $MergeResult) { return }

    Write-JsonLogEvent -Event 'UpstreamDomainMerge' -Data ([ordered]@{
        url = $MergeResult.Url
        source = $MergeResult.Source
        fetchedAt = $MergeResult.FetchedAt
        addedDomains = @($MergeResult.AddedDomains)
        safelistedDomains = @($MergeResult.SafelistedDomains)
        rejectedMalformedEntries = @($MergeResult.RejectedMalformedEntries)
        finalCount = $MergeResult.FinalCount
    })
}

function Merge-UpstreamDomains {
    $mergeResult = $null
    try {
        $raw = (Invoke-WebRequest -Uri $script:UpstreamUrl -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop).Content
        $mergeResult = Get-UpstreamDomainMergeResult -RawContent $raw -ExistingDomains $script:TelemetryDomains -Source 'Network'
        Save-UpstreamDomainCache -MergeResult $mergeResult
    } catch {
        $mergeResult = Get-UpstreamDomainCacheResult
        if ($mergeResult) {
            Write-Status "Could not fetch upstream domain list; using last-good cache from $($mergeResult.FetchedAt)" -Type Warning
        } else {
            Write-Status 'Could not fetch upstream domain list and no last-good cache is available; using built-in list' -Type Warning
            return
        }
    }

    Write-UpstreamMergeAudit -MergeResult $mergeResult
    if ($mergeResult.AcceptedDomains.Count -gt 0) {
        $script:TelemetryDomains = ($script:TelemetryDomains + $mergeResult.AcceptedDomains) | Sort-Object -Unique
    }

    if ($DryRun) {
        Write-Status "Would merge $($mergeResult.AddedDomains.Count) upstream domains from $($mergeResult.Source) ($($script:TelemetryDomains.Count) total, $($mergeResult.SafelistedDomains.Count) safelisted, $($mergeResult.RejectedMalformedEntries.Count) rejected)" -Type DryRun
        return
    }

    if ($mergeResult.AddedDomains.Count -gt 0) {
        Write-Status "Merged $($mergeResult.AddedDomains.Count) upstream domains from $($mergeResult.Source) ($($script:TelemetryDomains.Count) total, $($mergeResult.SafelistedDomains.Count) safelisted, $($mergeResult.RejectedMalformedEntries.Count) rejected)" -Type Success
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

function Write-JsonLogEvent {
    param(
        [Parameter(Mandatory=$true)][string]$Event,
        $Data = @{}
    )
    Initialize-AppDataDirectory
    $jsonEntry = [ordered]@{
        timestamp = (Get-Date -Format 'o')
        level     = 'Info'
        event     = $Event
        profile   = $Profile
        dryRun    = [bool]$DryRun
        undo      = [bool]$Undo
        status    = [bool]$StatusOnly
        data      = $Data
    }
    ($jsonEntry | ConvertTo-Json -Depth 8 -Compress) | Add-Content -Path $script:JsonLogFile -Encoding UTF8 -ErrorAction SilentlyContinue
}

function Write-Rationale {
    param([string]$Message)
    if ($ShowRationale) {
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
            # Nuke the directory with retry for slow/encrypted disks or transient locks
            Remove-Item $growthDir -Recurse -Force -ErrorAction SilentlyContinue
            $retryMs = 200
            for ($attempt = 0; $attempt -lt 5 -and (Test-Path $growthDir); $attempt++) {
                Start-Sleep -Milliseconds $retryMs
                # Re-attempt the delete each iteration - a lock may have cleared
                Remove-Item $growthDir -Recurse -Force -ErrorAction SilentlyContinue
                $retryMs *= 2
            }

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

        # Handle additional telemetry paths (both files, e.g. opm.db, and directories)
        foreach ($relPath in $AdditionalPaths) {
            $targetPath = Join-Path $localLow $relPath
            if (Test-Path $targetPath) {
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

function Resolve-TelemetryDomainAddresses {
    param([string]$Domain)
    return [System.Net.Dns]::GetHostAddresses($Domain)
}

function Get-RoutePrintOutput {
    param([string]$IPAddress)
    if ($IPAddress) {
        return route print $IPAddress 2>&1
    }
    return route print 2>&1
}

function Add-PersistentNullRoute {
    param([string]$IPAddress)
    & route -p add $IPAddress mask 255.255.255.255 0.0.0.0 2>&1 | Out-Null
}

function Remove-PersistentNullRoute {
    param([string]$IPAddress)
    & route delete $IPAddress 2>&1 | Out-Null
}

function Get-AdobeDynamicKeywords {
    Get-NetFirewallDynamicKeywordAddress -ErrorAction SilentlyContinue |
        Where-Object { $_.Keyword -like '*adobe*' -or $_.Keyword -like '*demdex*' -or $_.Keyword -like '*adobedtm*' -or $_.Keyword -like '*hstatic*' }
}

function Test-DynamicKeywordsAvailable {
    try {
        $mpStatus = Get-MpComputerStatus -ErrorAction Stop
        $mpPrefs = Get-MpPreference -ErrorAction Stop
        if ($mpStatus.AMRunningMode -eq 'Normal' -and $mpPrefs.EnableNetworkProtection -ge 1) {
            return ($null -ne (Get-Command New-NetFirewallDynamicKeywordAddress -ErrorAction SilentlyContinue))
        }
    } catch { }
    return $false
}

function Add-DynamicKeywordFirewallRules {
    $fqdnPatterns = @(
        '*.adobe.io'
        '*.adobestats.io'
        '*.demdex.net'
        '*.adobedtm.com'
        '*.adobegenuine.com'
        '*.hstatic.io'
    )

    # Remove existing Dynamic Keyword rules from previous runs
    $existingDk = Get-AdobeDynamicKeywords
    if ($existingDk) {
        foreach ($dk in $existingDk) {
            Remove-NetFirewallDynamicKeywordAddress -Id $dk.Id -ErrorAction SilentlyContinue
        }
    }

    if ($DryRun) {
        Write-Status "Would create $($fqdnPatterns.Count) FQDN wildcard firewall rules via Dynamic Keywords" -Type DryRun
        return 0
    }

    $dkCreated = 0
    foreach ($pattern in $fqdnPatterns) {
        try {
            $dkId = '{' + ([guid]::NewGuid()).ToString() + '}'
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
    return $dkCreated
}

function Block-AdobeFirewall {
    Write-Status 'Creating firewall rules to block Adobe telemetry' -Type Header
    Write-Rationale 'DNS-level blocking (hosts file) can be bypassed by hardcoded IPs or DNS-over-HTTPS. Firewall rules block by resolved IP (TCP+UDP) and by program path as a defense-in-depth layer. Persistent null routes add a third layer that survives firewall resets.'

    # Idempotent: remove existing rules from a previous run to avoid duplicates.
    # Exclude CCXProcess and AdobeIPCBroker rules, which are created by their own
    # earlier phases and manage their own idempotency; the wildcard would otherwise
    # delete rules just created in this same run.
    $existing = Get-NetFirewallRule -DisplayName 'Block Adobe Telemetry*' -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -notlike '*CCXProcess*' -and $_.DisplayName -notlike '*AdobeIPCBroker*' }
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
            $allAddrs = Resolve-TelemetryDomainAddresses -Domain $domain
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
        'AdobeGCClient.exe', 'Adobe Crash Processor.exe', 'AcroCEF.exe', 'RdrCEF.exe',
        'Adobe Dimension.exe', 'Adobe Substance 3D Painter.exe',
        'Adobe Substance 3D Designer.exe', 'Adobe Substance 3D Sampler.exe', 'Adobe Substance 3D Stager.exe',
        'Creative Cloud.exe', 'Adobe CEF Helper.exe', 'AdobeNotificationClient.exe',
        'AdobeExtensionsService.exe', 'Adobe Content Synchronizer.exe'
    )
    # Acrobat.exe / AcroRd32.exe are the primary user-facing apps - blocking all their
    # outbound traffic breaks cloud documents, Sign, and collaboration. Their telemetry
    # helpers (AcroCEF/RdrCEF) are blocked above at all tiers; block the apps themselves
    # only under the Aggressive profile.
    if ($Profile -eq 'Aggressive') {
        $telemetryExeNames += @('Acrobat.exe', 'AcroRd32.exe')
    }
    foreach ($installPath in $script:AdobeInstallPaths) {
        if (-not (Test-Path $installPath)) { continue }
        foreach ($exeName in $telemetryExeNames) {
            $found = Get-ChildItem -Path $installPath -Filter $exeName -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($found) { $adobeExePaths += $found.FullName }
        }
    }

    # Aggressive: block EVERY .exe under the Adobe install paths, not just the curated
    # telemetry list, so newly-added helpers are caught without a code change. This also
    # blocks the primary creative apps' outbound traffic - that is the Aggressive intent.
    if ($Profile -eq 'Aggressive') {
        $walked = 0
        foreach ($installPath in $script:AdobeInstallPaths) {
            if (-not (Test-Path $installPath)) { continue }
            foreach ($exe in (Get-ChildItem -Path $installPath -Filter '*.exe' -Recurse -ErrorAction SilentlyContinue)) {
                $adobeExePaths += $exe.FullName
                $walked++
            }
        }
        Write-Status "Aggressive: discovered $walked executable(s) under Adobe install paths for firewall blocking" -Type Info
    }
    $adobeExePaths = @($adobeExePaths | Sort-Object -Unique)

    $exeRulesCreated = 0
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
            $exeRulesCreated++
        }
    }

    if ($exeRulesCreated -gt 0) {
        Write-Status "Blocked $exeRulesCreated Adobe executable(s) via firewall" -Type Success
    } else {
        Write-Status 'No known Adobe telemetry executables found on disk' -Type Warning
    }

    # Aggressive: block outbound DNS-over-TLS (port 853). DoT bypasses hosts/route
    # sinkholing the same way DoH does; blocking it forces resolution back through the
    # system resolver that our hosts/route layers can sinkhole.
    if ($Profile -eq 'Aggressive') {
        if ($DryRun) {
            Write-Status 'Would block outbound DNS-over-TLS (port 853, TCP+UDP)' -Type DryRun
        } else {
            foreach ($proto in @('TCP', 'UDP')) {
                New-NetFirewallRule -DisplayName "Block Adobe Telemetry - DoT $proto 853" `
                    -Direction Outbound `
                    -Action Block `
                    -Protocol $proto `
                    -RemotePort 853 `
                    -Profile Any `
                    -Enabled True `
                    -Description 'Blocks DNS-over-TLS so it cannot bypass hosts/route sinkholing (Aggressive profile).' |
                    Out-Null
                Add-ManifestAction -Phase 'Firewall' -Action 'AddFirewallRule' -Details @{
                    DisplayName = "Block Adobe Telemetry - DoT $proto 853"
                }
                $script:Counters.FirewallRulesAdded++
            }
            Write-Status 'Blocked outbound DNS-over-TLS (port 853, TCP+UDP)' -Type Success
        }
    }

    # Add persistent null routes for resolved telemetry IPs (IPv4 only — route.exe does not support IPv6 persistent routes)
    if ($resolvedIPv4.Count -gt 0) {
        $routesAdded = 0
        foreach ($ip in $resolvedIPv4) {
            $existing = Get-RoutePrintOutput -IPAddress $ip | Select-String $ip -ErrorAction SilentlyContinue
            if ($existing) { continue }
            if ($DryRun) {
                $routesAdded++
            } else {
                Add-PersistentNullRoute -IPAddress $ip
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
    $dynamicKeywordsAvailable = Test-DynamicKeywordsAvailable
    if ($dynamicKeywordsAvailable) {
        $dkCreated = Add-DynamicKeywordFirewallRules
        if ($dkCreated -gt 0) {
            Write-Status "Created $dkCreated FQDN wildcard firewall rules (handles subdomain rotation automatically)" -Type Success
            $script:Counters.FirewallRulesAdded += $dkCreated
        }
    } else {
        Write-Status 'Dynamic Keywords not available (requires Defender + Network Protection) — using IP-based rules only' -Type Info
    }
}

function Test-DohEnabled {
    # DNS-over-HTTPS bypasses hosts-file sinkholing entirely. Detect system- and
    # browser-level DoH so the user can be warned their hosts layer is ineffective.
    # Detection only - this never modifies DoH configuration.
    $sources = @()

    # Windows system auto-DoH (Windows 11 / Server 2025): 0=off, 1=allow, 2=require.
    # (The DoH-server-address cmdlet is deliberately NOT used - it lists preconfigured
    # DoH server templates that exist even when DoH is off, causing false positives.)
    $dnsParams = 'HKLM:\SYSTEM\CurrentControlSet\Services\Dnscache\Parameters'
    $autoDoh = (Get-ItemProperty -Path $dnsParams -Name 'EnableAutoDoh' -ErrorAction SilentlyContinue).EnableAutoDoh
    if ($autoDoh -ge 1) { $sources += "Windows auto-DoH (EnableAutoDoh=$autoDoh)" }

    # Per-interface enforced DoH lives under DohInterfaceSettings\Doh\<server-ip> with a
    # DohFlags value. (DohProfileSettings\Doh keys are capability templates that exist for
    # any DoH-capable configured DNS server even when DoH is off - they are ignored here.)
    $ifaceDohRoot = 'HKLM:\SYSTEM\CurrentControlSet\Services\Dnscache\InterfaceSpecificParameters'
    if (Test-Path $ifaceDohRoot) {
        $dohIface = Get-ChildItem -Path $ifaceDohRoot -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $_.PSPath -like '*\DohInterfaceSettings\Doh\*' -or $_.PSPath -like '*\DohInterfaceSettings\Doh6\*' } |
            Where-Object { $null -ne (Get-ItemProperty -Path $_.PSPath -Name 'DohFlags' -ErrorAction SilentlyContinue).DohFlags }
        if ($dohIface) { $sources += 'per-interface DoH enforced' }
    }

    # Browser-enforced DoH policies - each bypasses the hosts file for that browser
    $browserDoh = @{
        'Microsoft Edge' = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'
        'Google Chrome'  = 'HKLM:\SOFTWARE\Policies\Google\Chrome'
    }
    foreach ($name in $browserDoh.Keys) {
        $mode = (Get-ItemProperty -Path $browserDoh[$name] -Name 'DnsOverHttpsMode' -ErrorAction SilentlyContinue).DnsOverHttpsMode
        if ($mode -and $mode -ne 'off') { $sources += "$name DoH policy ($mode)" }
    }
    $ffEnabled = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Mozilla\Firefox\DNSOverHTTPS' -Name 'Enabled' -ErrorAction SilentlyContinue).Enabled
    if ($ffEnabled -eq 1) { $sources += 'Mozilla Firefox DoH policy (enabled)' }

    return @{ Enabled = ($sources.Count -gt 0); Sources = @($sources) }
}

function Block-AdobeHostsFile {
    Write-Status 'Blocking Adobe telemetry via hosts file' -Type Header
    Write-Rationale 'Hosts file sinkholing (0.0.0.0) is the simplest blocking layer. It works at the OS resolver level before any network stack is involved, but can be overridden by Adobe WAM (Web Account Manager) which injects its own hosts entries. WAM entries are detected and removed first.'

    $hostsPath = "$env:SystemRoot\System32\drivers\etc\hosts"
    $marker    = '# --- Adobe Telemetry Block (Disable-AdobeTelemetry.ps1) ---'
    $endMarker = '# --- End Adobe Telemetry Block ---'

    # Pre-flight backup path setup
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

    # Open the hosts file with an exclusive lock for the entire read-modify-write so
    # Adobe WAM, a Pi-hole sync agent, corporate MDM, or a second instance cannot race
    # us between read and write and lose the other party's changes.
    $fs = $null
    try {
        $fs = [System.IO.File]::Open($hostsPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
    } catch {
        Write-Status "Could not acquire exclusive lock on hosts file: $($_.Exception.Message)" -Type Error
        return
    }

    $wamRemoved = $false
    try {
        $reader = New-Object System.IO.StreamReader($fs)
        $hostsContent = $reader.ReadToEnd()
        if (-not $hostsContent) { $hostsContent = '' }

        # Backup the current content to a separate file while the source stays locked.
        # Written BOM-free so the backup is a faithful copy of a clean hosts file.
        [System.IO.File]::WriteAllText($backupPath, $hostsContent, (New-Object System.Text.UTF8Encoding($false)))
        Write-Status "Hosts file backed up to $backupPath" -Type Info
        Add-ManifestAction -Phase 'Hosts' -Action 'HostsBackup' -Details @{
            Path = $hostsPath; BackupPath = $backupPath
        }

        # Remove Adobe WAM injected entries if present (old single-# and new CC v26.4+ double-## formats)
        $wamPattern = '(?s)\r?\n?#{1,2}\s*Adobe Creative Cloud WAM\s*-\s*Start\s*#{0,2}.*?#{1,2}\s*Adobe Creative Cloud WAM\s*-\s*End\s*#{0,2}\r?\n?'
        if ($hostsContent -match $wamPattern) {
            $hostsContent = $hostsContent -replace $wamPattern, ''
            $wamRemoved = $true
        }

        # Remove previous block if it exists (idempotent refresh)
        if ($hostsContent -match [regex]::Escape($marker)) {
            $pattern = "(?s)$([regex]::Escape($marker)).*?$([regex]::Escape($endMarker))\r?\n?"
            $hostsContent = $hostsContent -replace $pattern, ''
        }

        # Append new block (IPv4 + IPv6 sinkhole for each domain)
        $blockEntries = @($marker)
        foreach ($domain in $TelemetryDomains) {
            $blockEntries += "0.0.0.0    $domain"
            $blockEntries += "::         $domain"
        }
        $blockEntries += $endMarker

        $finalContent = $hostsContent.TrimEnd() + "`r`n" + ($blockEntries -join "`r`n") + "`r`n"

        # Single BOM-free UTF-8 write while still holding the exclusive lock. PS 5.1's
        # Set-Content -Encoding UTF8 prepends a BOM that some DNS/MDM parsers reject.
        $fs.SetLength(0)
        $fs.Position = 0
        $writer = New-Object System.IO.StreamWriter($fs, (New-Object System.Text.UTF8Encoding($false)))
        $writer.Write($finalContent)
        $writer.Flush()
    } finally {
        if ($fs) { $fs.Close() }
    }

    if ($wamRemoved) {
        Write-Status 'Removed Adobe WAM hosts injection' -Type Success
        Add-ManifestAction -Phase 'Hosts' -Action 'RemoveHostsBlock' -Details @{
            Path = $hostsPath; Marker = 'WAM'; EndMarker = 'WAM'
        }
    }

    Write-Status "Added $($TelemetryDomains.Count) domains to hosts file" -Type Success
    Add-ManifestAction -Phase 'Hosts' -Action 'HostsBlock' -Details @{
        Path = $hostsPath; Marker = $marker; EndMarker = $endMarker; BackupPath = $backupPath
    }
    $script:Counters.DomainsBlocked = $TelemetryDomains.Count

    # Flush DNS cache so changes take effect immediately
    & ipconfig /flushdns 2>&1 | Out-Null
    Write-Status 'DNS cache flushed' -Type Info

    # Warn if DoH is active - it bypasses hosts-file blocking entirely
    $doh = Test-DohEnabled
    if ($doh.Enabled) {
        Write-Status "DNS-over-HTTPS is enabled ($($doh.Sources -join '; ')). Hosts-file blocking is bypassed by DoH - rely on the firewall/route layers or disable DoH for full coverage." -Type Warning
    }

    # Optional: deny SYSTEM write on the hosts file so Adobe WAM (running as SYSTEM)
    # cannot re-inject its detection entry. Opt-in because the SYSTEM watchdog would
    # then be unable to reassert hosts entries.
    if ($LockHostsFile) {
        try {
            $sysSid = New-Object System.Security.Principal.SecurityIdentifier([System.Security.Principal.WellKnownSidType]::LocalSystemSid, $null)
            $acl = Get-Acl $hostsPath
            $denyRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
                $sysSid, 'WriteData,AppendData,Delete', 'Deny'
            )
            $acl.AddAccessRule($denyRule)
            Set-Acl -Path $hostsPath -AclObject $acl
            Write-Status 'Locked hosts file: denied SYSTEM write (blocks WAM re-injection)' -Type Success
            Add-ManifestAction -Phase 'Hosts' -Action 'LockHostsAcl' -Details @{ Path = $hostsPath }
        } catch {
            Write-Status "Could not lock hosts file ACL: $($_.Exception.Message)" -Type Warning
        }
    }
}

function Get-HostsDomainMappings {
    param(
        [string]$HostsContent,
        [string]$Domain = 'detect-ccd.creativecloud.adobe.com'
    )

    $mappings = @()
    if (-not $HostsContent) { return $mappings }

    foreach ($line in ($HostsContent -split "`r?`n")) {
        $trimmed = $line.Trim()
        if (-not $trimmed -or $trimmed.StartsWith('#')) { continue }

        $parts = $trimmed -split '\s+'
        if ($parts.Count -lt 2) { continue }

        foreach ($hostName in $parts[1..($parts.Count - 1)]) {
            if ($hostName -ieq $Domain) {
                $mappings += [pscustomobject]@{
                    Address = $parts[0]
                    Host    = $hostName
                    Line    = $trimmed
                }
            }
        }
    }

    return $mappings
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
    # Idempotent: remove this phase's own rules from a previous run first.
    if (-not $DryRun) {
        Get-NetFirewallRule -DisplayName 'Block Adobe Telemetry - CCXProcess*' -ErrorAction SilentlyContinue |
            Remove-NetFirewallRule -ErrorAction SilentlyContinue
    }
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

    # Idempotent: remove this phase's own rules from a previous run first.
    if (-not $DryRun) {
        Get-NetFirewallRule -DisplayName 'Block Adobe Telemetry - AdobeIPCBroker*' -ErrorAction SilentlyContinue |
            Remove-NetFirewallRule -ErrorAction SilentlyContinue
    }
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
                    'bToggleDocumentCloud'        = 1
                    'bToggleFillSign'            = 1
                    'bToggleSendAndTrack'         = 1
                    'bToggleAcroSendAndTrack'     = 1
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
        # BOM-free UTF-8, consistent with Block-AdobeHostsFile
        [System.IO.File]::WriteAllText($Path, ($content.TrimEnd() + "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
        Write-Status "Removed hosts block: $Marker" -Type Success
    }
}

function Remove-HostsAclLock {
    param([string]$Path)
    try {
        $sysSid = New-Object System.Security.Principal.SecurityIdentifier([System.Security.Principal.WellKnownSidType]::LocalSystemSid, $null)
        $acl = Get-Acl $Path
        $removed = $false
        foreach ($rule in @($acl.Access)) {
            if ($rule.AccessControlType -eq 'Deny') {
                $ruleSid = $rule.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value
                if ($ruleSid -eq $sysSid.Value) {
                    $acl.RemoveAccessRule($rule) | Out-Null
                    $removed = $true
                }
            }
        }
        if ($removed) {
            Set-Acl -Path $Path -AclObject $acl
            Write-Status 'Unlocked hosts file: removed SYSTEM deny ACE' -Type Success
        }
    } catch {
        Write-Status "Could not unlock hosts file ACL: $($_.Exception.Message)" -Type Warning
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
                        Remove-PersistentNullRoute -IPAddress $ip
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
                'LockHostsAcl' {
                    $lockPath = Get-ManifestDetail $details 'Path'
                    if ($lockPath -and (Test-Path $lockPath)) {
                        Remove-HostsAclLock -Path $lockPath
                    }
                }
                'RenameFile' {
                    $originalPath = Get-ManifestDetail $details 'OriginalPath'
                    $renamedPath = Get-ManifestDetail $details 'RenamedPath'
                    if ($renamedPath -and (Test-Path $renamedPath) -and $originalPath -and -not (Test-Path $originalPath)) {
                        Rename-Item -Path $renamedPath -NewName (Split-Path $originalPath -Leaf) -Force
                        Write-Status "Restored file: $originalPath" -Type Success
                    } else {
                        Write-Status "Skipped file restore (renamed file missing or original already exists): $originalPath" -Type Warning
                    }
                }
                'RenameStartupShortcut' {
                    $originalPath = Get-ManifestDetail $details 'OriginalPath'
                    $renamedPath = Get-ManifestDetail $details 'RenamedPath'
                    if ($renamedPath -and (Test-Path $renamedPath) -and $originalPath -and -not (Test-Path $originalPath)) {
                        Rename-Item -Path $renamedPath -NewName (Split-Path $originalPath -Leaf) -Force
                        Write-Status "Restored startup shortcut: $originalPath" -Type Success
                    } else {
                        Write-Status "Skipped shortcut restore (file missing or original exists): $originalPath" -Type Warning
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
    $existingDk = Get-AdobeDynamicKeywords
    if ($existingDk) {
        foreach ($dk in $existingDk) {
            Remove-NetFirewallDynamicKeywordAddress -Id $dk.Id -ErrorAction SilentlyContinue
        }
        Write-Status "Removed $(@($existingDk).Count) Dynamic Keyword address(es)" -Type Success
    }

    # 3c. Remove persistent null routes for telemetry IPs
    Write-Status 'Removing persistent null routes' -Type Header
    $routeOutput = Get-RoutePrintOutput
    $routesRemoved = 0
    foreach ($domain in $TelemetryDomains) {
        try {
            $ips = [System.Net.Dns]::GetHostAddresses($domain) |
                   Where-Object { $_.AddressFamily -eq 'InterNetwork' } |
                Select-Object -ExpandProperty IPAddressToString
            foreach ($ip in $ips) {
                if ($routeOutput -match [regex]::Escape($ip)) {
                    Remove-PersistentNullRoute -IPAddress $ip
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
    # Defensively remove any SYSTEM deny-write lock (from -LockHostsFile) before editing
    if (Test-Path $hostsPath) { Remove-HostsAclLock -Path $hostsPath }
    $hostsContent = Get-Content $hostsPath -Raw -ErrorAction SilentlyContinue
    $hostsModified = $false
    # Remove WAM entries if present (matches both old single-# and new CC v26.4+ double-## formats)
    $wamPattern = '(?s)\r?\n?#{1,2}\s*Adobe Creative Cloud WAM\s*-\s*Start\s*#{0,2}.*?#{1,2}\s*Adobe Creative Cloud WAM\s*-\s*End\s*#{0,2}\r?\n?'
    if ($hostsContent -and $hostsContent -match $wamPattern) {
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
        [System.IO.File]::WriteAllText($hostsPath, ($hostsContent.TrimEnd() + "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
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
        'HKLM:\SOFTWARE\Policies\Adobe\CreativeCloud'
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

    # Restore renamed Adobe startup shortcuts (.lnk.disabled -> .lnk) for the
    # manifest-less legacy path. The manifest undo handles these via RenameStartupShortcut.
    $startupFolders = @()
    $commonStartup = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\Startup'
    if (Test-Path $commonStartup) { $startupFolders += $commonStartup }
    $startupProfileRoot = Split-Path $env:USERPROFILE
    foreach ($userProf in (Get-ChildItem $startupProfileRoot -Directory -ErrorAction SilentlyContinue)) {
        $folder = Join-Path $userProf.FullName 'AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup'
        if (Test-Path $folder) { $startupFolders += $folder }
    }
    foreach ($folder in ($startupFolders | Sort-Object -Unique)) {
        $disabledShortcuts = Get-ChildItem -Path $folder -Filter '*.lnk.disabled' -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match 'Adobe|Creative Cloud|CCX|CCLibrary|CoreSync' }
        foreach ($item in $disabledShortcuts) {
            $restoredName = $item.Name -replace '\.disabled$', ''
            $restoredPath = Join-Path $folder $restoredName
            if (-not (Test-Path $restoredPath)) {
                Rename-Item -Path $item.FullName -NewName $restoredName -Force -ErrorAction SilentlyContinue
                Write-Status "Restored startup shortcut: $restoredName" -Type Success
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

function Add-PolicyStatusCheck {
    param(
        $Checks,
        [string]$Phase,
        [string]$Path,
        [string]$Name,
        $Expected,
        [string]$Type = 'DWord'
    )
    $null = $Checks.Add([ordered]@{
        Phase    = $Phase
        Path     = $Path
        Name     = $Name
        Expected = $Expected
        Type     = $Type
    })
}

function Get-RegistryPolicyStatusChecks {
    $checks = New-Object System.Collections.ArrayList
    $policyGroups = @(
        @{ Phase = 'Registry'; Path = 'HKLM:\SOFTWARE\Policies\Adobe\Common\Enterprise'; Values = @{ DisableUsageData = 1; DisableFileSync = 1; DisableAutoupdates = 1; DisableCCDesktop = 0 } },
        @{ Phase = 'Registry'; Path = 'HKLM:\SOFTWARE\Policies\Adobe\CCXNew'; Values = @{ DisableGrowth = 1 } },
        @{ Phase = 'Registry'; Path = 'HKLM:\SOFTWARE\Policies\Adobe\CreativeCloud'; Values = @{ DisableLaunchOnLogin = 1; DisableNotifications = 1; DisableAutoUpdates = 1 } },
        @{ Phase = 'Registry'; Path = 'HKLM:\SOFTWARE\Adobe\Adobe Genuine Service'; Values = @{ AgsDisabled = 1 } },
        @{ Phase = 'Registry'; Path = 'HKCU:\SOFTWARE\Adobe\CommonFiles\UsageCC'; Values = @{ AUSUF = 0 } },
        @{ Phase = 'Registry'; Path = 'HKLM:\SOFTWARE\Policies\Adobe\Substance 3D'; Values = @{ DisableAnalytics = 1; DisableTelemetry = 1; DisableAutoUpdate = 1 } },
        @{ Phase = 'Registry'; Path = 'HKCU:\SOFTWARE\Adobe\Substance 3D Painter\Settings'; Values = @{ enable_analytics = 0 } },
        @{ Phase = 'Registry'; Path = 'HKCU:\SOFTWARE\Adobe\Substance 3D Designer\Settings'; Values = @{ enable_analytics = 0 } },
        @{ Phase = 'Registry'; Path = 'HKCU:\SOFTWARE\Adobe\Substance 3D Sampler\Settings'; Values = @{ enable_analytics = 0 } },
        @{ Phase = 'Acrobat'; Path = 'HKCU:\SOFTWARE\Adobe\Adobe Acrobat\DC\AVAlert\cCheckbox'; Values = @{ iAcro498 = 1 } },
        @{ Phase = 'Acrobat'; Path = 'HKCU:\SOFTWARE\Adobe\CommonFiles\CRLog'; Type = 'String'; Values = @{ 'Never Ask' = '1' } },
        @{ Phase = 'Acrobat'; Path = 'HKCU:\SOFTWARE\Adobe\Adobe Acrobat\DC\Workflows'; Values = @{ bNeedSynchronizer = 0 } }
    )

    foreach ($group in $policyGroups) {
        foreach ($name in $group.Values.Keys) {
            $type = if ($group.Type) { $group.Type } else { 'DWord' }
            Add-PolicyStatusCheck -Checks $checks -Phase $group.Phase -Path $group.Path -Name $name -Expected $group.Values[$name] -Type $type
        }
    }

    foreach ($product in @('Adobe Acrobat', 'Acrobat Reader')) {
        foreach ($basePath in @("HKLM:\SOFTWARE\Policies\Adobe\$product\DC\FeatureLockDown", "HKLM:\SOFTWARE\Wow6432Node\Policies\Adobe\$product\DC\FeatureLockDown")) {
            foreach ($name in @('bUsageMeasurement', 'bUpdater', 'bEnableGentech')) {
                Add-PolicyStatusCheck -Checks $checks -Phase 'Acrobat' -Path $basePath -Name $name -Expected 0
            }
            foreach ($name in @('bAcroSuppressUpsell', 'bWhatsNewExp')) {
                Add-PolicyStatusCheck -Checks $checks -Phase 'Acrobat' -Path $basePath -Name $name -Expected 1
            }
            foreach ($name in @('bToggleAdobeSign', 'bTogglePrefsSync', 'bToggleWebConnectors', 'bAdobeSendPluginToggle', 'bToggleAdobeDocumentServices', 'bToggleDocumentCloud', 'bToggleFillSign', 'bToggleSendAndTrack', 'bToggleAcroSendAndTrack')) {
                Add-PolicyStatusCheck -Checks $checks -Phase 'Acrobat' -Path "$basePath\cServices" -Name $name -Expected 1
            }
            foreach ($name in @('bShowMsgAtLaunch', 'bDontShowMsgWhenViewingDoc')) {
                Add-PolicyStatusCheck -Checks $checks -Phase 'Acrobat' -Path "$basePath\cIPM" -Name $name -Expected 0
            }
            Add-PolicyStatusCheck -Checks $checks -Phase 'Acrobat' -Path "$basePath\cCloud" -Name 'bDisableADCFileStore' -Expected 1
            Add-PolicyStatusCheck -Checks $checks -Phase 'Acrobat' -Path "$basePath\cWelcomeScreen" -Name 'bShowWelcomeScreen' -Expected 0
            Add-PolicyStatusCheck -Checks $checks -Phase 'Acrobat' -Path "$basePath\cWebmailProfiles" -Name 'bDisableWebmail' -Expected 1
            Add-PolicyStatusCheck -Checks $checks -Phase 'Acrobat' -Path "$basePath\cSharePoint" -Name 'bDisableSharePointFeatures' -Expected 1

            if ($Profile -eq 'Aggressive') {
                foreach ($name in @('bProtectedMode', 'bEnhancedSecurityStandalone', 'bEnhancedSecurityInBrowser', 'iFileAttachmentPerms', 'bDisableTrustedFolders', 'bDisableTrustedSites', 'bDisableOSTrustedSites', 'bEnableProtectedModeAppContainer')) {
                    Add-PolicyStatusCheck -Checks $checks -Phase 'Acrobat' -Path $basePath -Name $name -Expected 1
                }
                foreach ($name in @('bEnableFlash', 'bEnableCertificateBasedTrust')) {
                    Add-PolicyStatusCheck -Checks $checks -Phase 'Acrobat' -Path $basePath -Name $name -Expected 0
                }
                Add-PolicyStatusCheck -Checks $checks -Phase 'Acrobat' -Path $basePath -Name 'iProtectedView' -Expected 2
                Add-PolicyStatusCheck -Checks $checks -Phase 'Acrobat' -Path "$basePath\cDefaultLaunchURLPerms" -Name 'iURLPerms' -Expected 1
                Add-PolicyStatusCheck -Checks $checks -Phase 'Acrobat' -Path "$basePath\cDefaultLaunchURLPerms" -Name 'iUnknownURLPerms' -Expected 3
            }
        }
    }

    return @($checks)
}

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
        Neutralization = @{ CCXProcess = @(); StartupShortcutsDisabled = 0; NullRoutes = 0 }
        Registry   = @()
        Startup    = @()
        Watchdog   = @{ Installed = $false; State = 'NotInstalled' }
        EventLog   = @{ SourceExists = $false; Log = 'Application'; Source = 'Disable-AdobeTelemetry' }
        Verification = $null
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

    $dkAvailable = Test-DynamicKeywordsAvailable
    $existingDk = @()
    $dkPatterns = @()
    if ($dkAvailable) {
        $existingDk = @(Get-AdobeDynamicKeywords)
        $dkPatterns = @($existingDk | ForEach-Object { $_.Keyword })
    }
    $statusData.Firewall.DynamicKeywords = @{
        Available = $dkAvailable
        Count     = $existingDk.Count
        Patterns  = $dkPatterns
    }

    $connections = @(Get-AdobeTelemetryConnections)
    $statusData.Connections.Count = $connections.Count

    $hostsPath = "$env:SystemRoot\System32\drivers\etc\hosts"
    $marker = '# --- Adobe Telemetry Block (Disable-AdobeTelemetry.ps1) ---'
    $endMarker = '# --- End Adobe Telemetry Block ---'
    $hostsContent = Get-Content $hostsPath -Raw -ErrorAction SilentlyContinue
    $statusData.HostsFile.BlockPresent = ($hostsContent -and $hostsContent -match [regex]::Escape($marker))
    $statusData.HostsFile.EndMarkerPresent = ($hostsContent -and $hostsContent -match [regex]::Escape($endMarker))
    $doh = Test-DohEnabled
    $statusData.HostsFile.DohEnabled = $doh.Enabled
    $statusData.HostsFile.DohSources = $doh.Sources

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

    # Neutralization artifacts: CCXProcess rename, startup shortcuts, persistent null routes
    $ccxPaths = @(
        "$env:ProgramFiles\Adobe\Adobe Creative Cloud Experience"
        "${env:ProgramFiles(x86)}\Adobe\Adobe Creative Cloud Experience"
    )
    foreach ($ccxDir in $ccxPaths) {
        if (-not (Test-Path $ccxDir)) { continue }
        $ccxExe = Join-Path $ccxDir 'CCXProcess.exe'
        $ccxDisabled = Join-Path $ccxDir 'CCXProcess.exe.disabled'
        $renamed = ((Test-Path $ccxDisabled) -and -not (Test-Path $ccxExe))
        $statusData.Neutralization.CCXProcess += @{ Path = $ccxDir; Renamed = $renamed; OriginalPresent = (Test-Path $ccxExe) }
    }

    $startupFolders = @()
    $commonStartup = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\Startup'
    if (Test-Path $commonStartup) { $startupFolders += $commonStartup }
    foreach ($userProf in (Get-ChildItem (Split-Path $env:USERPROFILE) -Directory -ErrorAction SilentlyContinue)) {
        $sf = Join-Path $userProf.FullName 'AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup'
        if (Test-Path $sf) { $startupFolders += $sf }
    }
    $disabledShortcutCount = 0
    foreach ($folder in ($startupFolders | Sort-Object -Unique)) {
        $disabledShortcutCount += @(Get-ChildItem -Path $folder -Filter '*.lnk.disabled' -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match 'Adobe|Creative Cloud|CCX|CCLibrary|CoreSync' }).Count
    }
    $statusData.Neutralization.StartupShortcutsDisabled = $disabledShortcutCount

    # Persistent null routes: /32 routes sinkholed to 0.0.0.0 (best-effort count)
    $nullRouteCount = 0
    try {
        $nullRouteCount = @(Get-NetRoute -ErrorAction SilentlyContinue |
            Where-Object { $_.NextHop -eq '0.0.0.0' -and $_.DestinationPrefix -like '*/32' }).Count
    } catch { }
    $statusData.Neutralization.NullRoutes = $nullRouteCount

    foreach ($check in (Get-RegistryPolicyStatusChecks)) {
        $val = $null
        $state = 'NotSet'
        if (Test-Path $check.Path) {
            $val = (Get-ItemProperty -Path $check.Path -Name $check.Name -ErrorAction SilentlyContinue).($check.Name)
            if ($null -ne $val) { $state = if ($val -eq $check.Expected) { 'Correct' } else { 'Incorrect' } }
        } else { $state = 'PathNotFound' }
        $statusData.Registry += @{
            Phase    = $check.Phase
            Path     = $check.Path
            Name     = $check.Name
            Type     = $check.Type
            State    = $state
            Actual   = $val
            Value    = $val
            Expected = $check.Expected
        }
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
        $wdInfo = Get-ScheduledTaskInfo -TaskName $script:WatchdogTaskName -ErrorAction SilentlyContinue
        if ($wdInfo) {
            $statusData.Watchdog.LastRunTime   = if ($wdInfo.LastRunTime)  { $wdInfo.LastRunTime.ToString('o') } else { $null }
            $statusData.Watchdog.NextRunTime   = if ($wdInfo.NextRunTime)  { $wdInfo.NextRunTime.ToString('o') } else { $null }
            $statusData.Watchdog.LastTaskResult = $wdInfo.LastTaskResult
        }
    }

    $eventSourceExists = $false
    try { $eventSourceExists = [System.Diagnostics.EventLog]::SourceExists('Disable-AdobeTelemetry') } catch { }
    $statusData.EventLog = @{ SourceExists = $eventSourceExists; Log = 'Application'; Source = 'Disable-AdobeTelemetry' }

    $statusData.Verification = Get-PostApplyVerificationData -StatusData $statusData

    return $statusData
}

function Get-PostApplyVerificationData {
    param($StatusData)

    $hostsPath = "$env:SystemRoot\System32\drivers\etc\hosts"
    $marker = '# --- Adobe Telemetry Block (Disable-AdobeTelemetry.ps1) ---'
    $endMarker = '# --- End Adobe Telemetry Block ---'
    $wamPattern = '#{1,2}\s*Adobe Creative Cloud WAM\s*-\s*Start\s*#{0,2}'
    $detectDomain = 'detect-ccd.creativecloud.adobe.com'
    $hostsContent = Get-Content $hostsPath -Raw -ErrorAction SilentlyContinue
    $mappings = @(Get-HostsDomainMappings -HostsContent $hostsContent -Domain $detectDomain)
    $effectiveMapping = if ($mappings.Count -gt 0) { $mappings[0].Address } else { $null }
    $sinkholeAddresses = @('0.0.0.0', '::')

    $fwRuleCount = 0
    $dynamicKeywordStatus = @{ Available = $false; Count = 0; Patterns = @() }
    if ($StatusData) {
        $fwRuleCount = [int]$StatusData.Firewall.RuleCount
        if ($StatusData.Firewall.DynamicKeywords) {
            $dynamicKeywordStatus = $StatusData.Firewall.DynamicKeywords
        }
    } else {
        $fwRules = Get-NetFirewallRule -DisplayName 'Block Adobe Telemetry*' -ErrorAction SilentlyContinue
        $fwRuleCount = if ($fwRules) { @($fwRules).Count } else { 0 }
        $dkAvailable = Test-DynamicKeywordsAvailable
        if ($dkAvailable) {
            $existingDk = @(Get-AdobeDynamicKeywords)
            $dynamicKeywordStatus = @{
                Available = $true
                Count     = $existingDk.Count
                Patterns  = @($existingDk | ForEach-Object { $_.Keyword })
            }
        }
    }

    $connections = @(Get-AdobeTelemetryConnections)
    $failures = @()
    $blockPresent = [bool]($hostsContent -and $hostsContent -match [regex]::Escape($marker))
    $endBlockPresent = [bool]($hostsContent -and $hostsContent -match [regex]::Escape($endMarker))
    $wamPresent = [bool]($hostsContent -and $hostsContent -match $wamPattern)
    $detectSinkholed = ($sinkholeAddresses -contains $effectiveMapping)

    if (-not $blockPresent -or -not $endBlockPresent) { $failures += 'Hosts block markers are missing' }
    if ($wamPresent) { $failures += 'Adobe WAM hosts marker is still present' }
    if (-not $detectSinkholed) { $failures += "$detectDomain effective mapping is not sinkholed" }
    if ($fwRuleCount -lt 1) { $failures += 'No Adobe telemetry firewall block rules found' }
    if ($dynamicKeywordStatus.Available -and [int]$dynamicKeywordStatus.Count -lt 1) { $failures += 'Dynamic Keywords are available but no Adobe FQDN keyword rules were found' }
    if ($connections.Count -gt 0) { $failures += "$($connections.Count) Adobe-owned outbound connection(s) remain" }

    return [ordered]@{
        Passed = ($failures.Count -eq 0)
        Failures = $failures
        Hosts = [ordered]@{
            MarkerPresent = $blockPresent
            EndMarkerPresent = $endBlockPresent
            WamMarkerPresent = $wamPresent
            DetectCcdMapping = $effectiveMapping
            DetectCcdSinkholed = $detectSinkholed
            DetectCcdMappings = @($mappings)
        }
        Firewall = [ordered]@{
            RuleCount = $fwRuleCount
            DynamicKeywordsAvailable = [bool]$dynamicKeywordStatus.Available
            DynamicKeywordCount = [int]$dynamicKeywordStatus.Count
            DynamicKeywordPatterns = @($dynamicKeywordStatus.Patterns)
        }
        Connections = [ordered]@{
            RemainingCount = $connections.Count
        }
    }
}

function Invoke-PostApplyVerification {
    Write-Status 'Running post-apply tamper verification' -Type Header
    $verification = Get-PostApplyVerificationData
    if ($verification.Passed) {
        Write-Status 'Post-apply verification passed' -Type Success
        return
    }

    foreach ($failure in $verification.Failures) {
        Write-Status "Post-apply verification failed: $failure" -Type Error
        $script:Counters.VerificationFailures++
    }
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
    if ($data.Firewall.DynamicKeywords.Available) {
        $dkColor = if ($data.Firewall.DynamicKeywords.Count -gt 0) { 'Green' } else { 'Yellow' }
        Write-Host "    FQDN Dynamic Keywords: $($data.Firewall.DynamicKeywords.Count) active ($($data.Firewall.DynamicKeywords.Patterns -join ', '))" -ForegroundColor $dkColor
    } else {
        Write-Host '    FQDN Dynamic Keywords: Not available (requires Defender + Network Protection)' -ForegroundColor DarkGray
    }

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
    if ($data.HostsFile.DohEnabled) {
        Write-Host "    DNS-over-HTTPS: ENABLED - hosts blocking bypassed ($($data.HostsFile.DohSources -join '; '))" -ForegroundColor Yellow
    } else {
        Write-Host '    DNS-over-HTTPS: Not detected (hosts blocking effective)' -ForegroundColor Green
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
    Write-Host '  --- Neutralization ---' -ForegroundColor Cyan
    if (@($data.Neutralization.CCXProcess).Count -gt 0) {
        foreach ($ccx in $data.Neutralization.CCXProcess) {
            if ($ccx.Renamed) {
                Write-Host "    CCXProcess.exe: Renamed/disabled ($($ccx.Path))" -ForegroundColor Green
            } elseif ($ccx.OriginalPresent) {
                Write-Host "    CCXProcess.exe: PRESENT - not neutralized ($($ccx.Path))" -ForegroundColor Yellow
            }
        }
    } else {
        Write-Host '    CCXProcess.exe: install directory not found' -ForegroundColor DarkGray
    }
    $ssColor = if ($data.Neutralization.StartupShortcutsDisabled -gt 0) { 'Green' } else { 'DarkGray' }
    Write-Host "    Startup shortcuts disabled: $($data.Neutralization.StartupShortcutsDisabled)" -ForegroundColor $ssColor
    $nrColor = if ($data.Neutralization.NullRoutes -gt 0) { 'Green' } else { 'DarkGray' }
    Write-Host "    Persistent null routes (/32 -> 0.0.0.0): $($data.Neutralization.NullRoutes)" -ForegroundColor $nrColor

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
        $lastRun = if ($data.Watchdog.LastRunTime) { $data.Watchdog.LastRunTime } else { 'never' }
        $nextRun = if ($data.Watchdog.NextRunTime) { $data.Watchdog.NextRunTime } else { 'n/a' }
        Write-Host "    Last run: $lastRun" -ForegroundColor Gray
        Write-Host "    Next run: $nextRun" -ForegroundColor Gray
        if ($null -ne $data.Watchdog.LastTaskResult) {
            $resColor = if ($data.Watchdog.LastTaskResult -eq 0) { 'Green' } else { 'Yellow' }
            Write-Host "    Last result code: $($data.Watchdog.LastTaskResult)" -ForegroundColor $resColor
        }
    } else {
        Write-Host "    $($script:WatchdogTaskName) : Not installed" -ForegroundColor DarkGray
    }

    Write-Host ''
    Write-Host '  --- Event Log ---' -ForegroundColor Cyan
    if ($data.EventLog.SourceExists) {
        Write-Host "    Application source '$($data.EventLog.Source)': Registered" -ForegroundColor Green
    } else {
        Write-Host "    Application source '$($data.EventLog.Source)': Not registered (created on first apply)" -ForegroundColor DarkGray
    }

    Write-Host ''
}

# ── Summary Function ──────────────────────────────────────────────────────────

function Test-UpdateAvailable {
    # Non-blocking update notification. Reports from a <=24h cache immediately (never
    # waits on the network), then refreshes the cache in a background job for next run.
    $cacheDir = Join-Path $env:APPDATA 'Disable-AdobeTelemetry'
    if (-not (Test-Path $cacheDir)) { New-Item -Path $cacheDir -ItemType Directory -Force | Out-Null }
    $cachePath = Join-Path $cacheDir 'update-check.json'
    $current = $script:Version
    $cacheFresh = $false

    if (Test-Path $cachePath) {
        try {
            $cache = Get-Content $cachePath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            if ($cache.LatestTag) {
                $latest = ($cache.LatestTag -replace '^v', '')
                if ([version]$latest -gt [version]$current) {
                    Write-Status "Update available: $($cache.LatestTag) (current v$current) - https://github.com/SysAdminDoc/Disable-AdobeTelemetry/releases/latest" -Type Warning
                }
            }
            if ($cache.CheckedUtc) {
                $checked = [datetime]::Parse($cache.CheckedUtc, $null, [System.Globalization.DateTimeStyles]::RoundtripKind)
                if (([datetime]::UtcNow - $checked.ToUniversalTime()).TotalHours -lt 24) { $cacheFresh = $true }
            }
        } catch { }
    }

    if (-not $cacheFresh) {
        # Fire-and-forget refresh; result is consumed on a later run so this never blocks.
        Start-Job -ScriptBlock {
            param($cachePath)
            try {
                $resp = Invoke-RestMethod -Uri 'https://api.github.com/repos/SysAdminDoc/Disable-AdobeTelemetry/releases/latest' -Headers @{ 'User-Agent' = 'Disable-AdobeTelemetry' } -UseBasicParsing -TimeoutSec 8 -ErrorAction Stop
                @{ LatestTag = $resp.tag_name; CheckedUtc = [datetime]::UtcNow.ToString('o') } |
                    ConvertTo-Json | Set-Content -LiteralPath $cachePath -Encoding UTF8 -Force
            } catch { }
        } -ArgumentList $cachePath | Out-Null
    }
}

function Write-SummaryEvent {
    # Write a run-summary entry to the Windows Application event log for fleet/SIEM
    # visibility. EventIDs: 1000=success, 2000=partial, 3000=failure, 4000=undo.
    param(
        [ValidateSet('Success','Partial','Failure','Undo')]
        [string]$Result,
        [string]$Message
    )
    if ($DryRun) { return }
    $eventMap = @{
        Success = @{ Id = 1000; Type = 'Information' }
        Partial = @{ Id = 2000; Type = 'Warning' }
        Failure = @{ Id = 3000; Type = 'Error' }
        Undo    = @{ Id = 4000; Type = 'Information' }
    }
    $e = $eventMap[$Result]
    try {
        if (-not [System.Diagnostics.EventLog]::SourceExists('Disable-AdobeTelemetry')) {
            New-EventLog -LogName Application -Source 'Disable-AdobeTelemetry' -ErrorAction Stop
        }
        Write-EventLog -LogName Application -Source 'Disable-AdobeTelemetry' `
            -EventId $e.Id -EntryType $e.Type -Message $Message -ErrorAction Stop
    } catch {
        Write-Status "Could not write Application event log entry: $($_.Exception.Message)" -Type Warning
    }
}

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
        @{ Label = 'Verification failures'; Count = $c.VerificationFailures; Color = 'Red' }
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

    if ($outputPath -match '[";|&<>]') {
        Write-Status "Invalid trace output path (contains shell metacharacters)" -Type Error
        return
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
    if (-not $proc.HasExited) {
        $proc | Stop-Process -Force -ErrorAction SilentlyContinue
        Write-Status "Stopped $AppName (PID $($proc.Id))" -Type Info
    }
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

    # Warn if script is in a temp or downloads location that may not persist
    $warnPaths = @($env:TEMP, "$env:USERPROFILE\Downloads", "$env:USERPROFILE\Desktop")
    foreach ($warnPath in $warnPaths) {
        if ($warnPath -and $scriptFullPath -like "$warnPath*") {
            Write-Status ("WARNING: Script is in '{0}' - if moved, the watchdog task will fail silently. Consider copying to a permanent location first." -f $warnPath) -Type Warning
        }
    }

    # Register event source for watchdog logging (idempotent)
    try {
        if (-not [System.Diagnostics.EventLog]::SourceExists('Disable-AdobeTelemetry')) {
            New-EventLog -LogName Application -Source 'Disable-AdobeTelemetry' -ErrorAction Stop
        }
    } catch { }

    # Wrap the scheduled action with a path check so failures are visible in Event Viewer.
    $escapedScriptPath = $scriptFullPath.Replace("'", "''")
    $watchdogCommandTemplate = 'if (-not (Test-Path -LiteralPath ''{0}'')) {{ try {{ Write-EventLog -LogName Application -Source ''Disable-AdobeTelemetry'' -EventId 1001 -EntryType Warning -Message ''Watchdog: script not found at {0}'' }} catch {{ }}; exit 1 }}; & ''{0}'' -Skip Kill'
    $watchdogCommand = $watchdogCommandTemplate -f $escapedScriptPath
    $encodedWatchdogCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($watchdogCommand))
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument "-NoProfile -ExecutionPolicy Bypass -EncodedCommand $encodedWatchdogCommand"
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
        SchemaVersion = 1
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

function Get-RunProfileProperty {
    param(
        [Parameter(Mandatory=$true)]$ProfileData,
        [Parameter(Mandatory=$true)][string]$Name
    )
    $property = $ProfileData.PSObject.Properties[$Name]
    if ($property) { return $property.Value }
    return $null
}

function Test-RunProfileData {
    param($ProfileData)

    $errors = New-Object System.Collections.Generic.List[string]
    if (-not $ProfileData) {
        $errors.Add('Profile JSON is empty or invalid')
        return [pscustomobject]@{ IsValid = $false; Errors = @($errors); Data = $null }
    }

    foreach ($requiredField in @('SchemaVersion', 'Version', 'Profile', 'Domains')) {
        if (-not $ProfileData.PSObject.Properties[$requiredField]) {
            $errors.Add("Missing required field: $requiredField")
        }
    }

    $schemaVersion = Get-RunProfileProperty -ProfileData $ProfileData -Name 'SchemaVersion'
    $schemaNumber = 0
    if ($null -ne $schemaVersion -and (-not [int]::TryParse([string]$schemaVersion, [ref]$schemaNumber) -or $schemaNumber -ne 1)) {
        $errors.Add("Unsupported schema version: $schemaVersion")
    }

    $version = Get-RunProfileProperty -ProfileData $ProfileData -Name 'Version'
    if ($version -and ([string]$version -notmatch '^\d+\.\d+\.\d+([-.][A-Za-z0-9.-]+)?$')) {
        $errors.Add("Invalid version: $version")
    }

    $profileTier = Get-RunProfileProperty -ProfileData $ProfileData -Name 'Profile'
    if ($profileTier -and @('Minimal', 'Standard', 'Aggressive') -notcontains [string]$profileTier) {
        $errors.Add("Invalid profile tier: $profileTier")
    }

    foreach ($phaseField in @('Only', 'Skip')) {
        $phaseValues = Get-RunProfileProperty -ProfileData $ProfileData -Name $phaseField
        if ($null -ne $phaseValues) {
            foreach ($phase in @($phaseValues)) {
                if ($phase -and $script:ValidPhases -notcontains [string]$phase) {
                    $errors.Add("Invalid $phaseField phase: $phase")
                }
            }
        }
    }

    $domains = Get-RunProfileProperty -ProfileData $ProfileData -Name 'Domains'
    $domainValues = @($domains) | Where-Object { $null -ne $_ -and [string]$_ -ne '' }
    if ($domainValues.Count -eq 0) {
        $errors.Add('Domains must contain at least one domain')
    } else {
        foreach ($domain in $domainValues) {
            if ([string]$domain -notmatch '^[a-zA-Z0-9]([a-zA-Z0-9\-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9\-]*[a-zA-Z0-9])?)+$') {
                $errors.Add("Invalid domain: $domain")
            }
        }
    }

    return [pscustomobject]@{
        IsValid = ($errors.Count -eq 0)
        Errors  = @($errors)
        Data    = $ProfileData
    }
}

function Import-RunProfile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Status "Profile not found: $Path" -Type Error
        exit 2
    }
    try {
        $profileData = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    } catch {
        Write-Status "Invalid profile JSON: $($_.Exception.Message)" -Type Error
        exit 2
    }

    $validation = Test-RunProfileData -ProfileData $profileData
    if (-not $validation.IsValid) {
        foreach ($validationError in $validation.Errors) {
            Write-Status "Invalid profile: $validationError" -Type Error
        }
        exit 2
    }

    $script:Profile = [string]$profileData.Profile
    $importedOnly = Get-RunProfileProperty -ProfileData $profileData -Name 'Only'
    $importedSkip = Get-RunProfileProperty -ProfileData $profileData -Name 'Skip'
    $script:Only = if ($null -ne $importedOnly -and @($importedOnly).Count -gt 0) { @($importedOnly) } else { $null }
    $script:Skip = if ($null -ne $importedSkip -and @($importedSkip).Count -gt 0) { @($importedSkip) } else { $null }
    $script:TelemetryDomains = @($profileData.Domains) | Sort-Object -Unique
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
    Invoke-PostApplyVerification
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
if ($ExportProfile -and $ImportProfile) {
    Write-Host "  [!!] Cannot use -ExportProfile and -ImportProfile together" -ForegroundColor Red
    exit 2
}
if ($ExportProfile) {
    Export-RunProfile -Path $ExportProfile
    exit 0
}
if ($ImportProfile) {
    Import-RunProfile -Path $ImportProfile
    if (-not $Only -and -not $Skip -and $Profile -eq 'Minimal') {
        $Skip = @('GrowthSDK', 'CCXProcess', 'Services', 'Tasks', 'Registry', 'Acrobat', 'Startup')
    }
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

# Suppress console banner in JSON status mode so stdout is pure JSON (fleet parsing)
$jsonStatus = $StatusOnly -and ($OutputFormat -eq 'JSON')
if (-not $jsonStatus) {
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

    if ($ShowRationale) {
        Write-Host '  Show rationale: enabled' -ForegroundColor Yellow
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
}

# Non-blocking update check (skipped in JSON status mode to keep stdout pure)
if (-not $jsonStatus) { Test-UpdateAvailable }

# Initialize log
$logHeader = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - Disable-AdobeTelemetry $script:DisplayVersion started"
if ($Undo)       { $logHeader += ' (UNDO mode)' }
if ($StatusOnly) { $logHeader += ' (STATUS mode)' }
if ($DryRun)     { $logHeader += ' (DRY RUN mode)' }
if ($Profile -ne 'Standard') { $logHeader += " (Profile: $Profile)" }
if ($Only)       { $logHeader += " (Only: $($Only -join ','))" }
if ($Skip)       { $logHeader += " (Skip: $($Skip -join ','))" }
if ($ShowRationale) { $logHeader += ' (ShowRationale)' }
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
    Write-SummaryEvent -Result Undo -Message "Undo completed via $(if ($manifestHandled) { 'manifest' } else { 'legacy' }) path. All recorded telemetry blocks reversed."
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
$eventDetail = "Domains sinkholed: $($script:Counters.DomainsBlocked); firewall rules: $($script:Counters.FirewallRulesAdded); services disabled: $($script:Counters.ServicesDisabled); tasks disabled: $($script:Counters.TasksDisabled); verification failures: $($script:Counters.VerificationFailures)."
if ($DryRun) {
    exit 0
} elseif ($script:Counters.Errors -gt 0) {
    Write-SummaryEvent -Result Partial -Message "Apply completed with $($script:Counters.Errors) error(s). $eventDetail"
    exit 3
} else {
    Write-SummaryEvent -Result Success -Message "Apply completed successfully. $eventDetail"
    exit 3010
}
