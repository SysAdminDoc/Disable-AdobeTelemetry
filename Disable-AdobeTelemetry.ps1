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

.NOTES
    Author  : Matt (Maven Imaging)
    Version : 2.1.0
    Date    : 2026-06-20
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
    [string]$ImportProfile
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
    Start-Process powershell.exe -Verb RunAs -ArgumentList $argList
    exit 0
}

# ── Config ──────────────────────────────────────────────────────────────────────

$ErrorActionPreference = 'Continue'

$script:LogFile = Join-Path $env:TEMP 'Disable-AdobeTelemetry.log'

# ── Undo Manifest ────────────────────────────────────────────────────────────
# JSON manifest recording every action so -Undo can be fully deterministic
$script:ManifestDir = Join-Path $env:APPDATA 'Disable-AdobeTelemetry'
$script:ManifestPath = Join-Path $script:ManifestDir 'undo-manifest.json'
$script:ManifestActions = @()

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
    if (-not (Test-Path $script:ManifestDir)) {
        New-Item -Path $script:ManifestDir -ItemType Directory -Force | Out-Null
    }
    $manifest = @{
        Version   = '2.1.0'
        CreatedAt = (Get-Date -Format 'o')
        Actions   = $script:ManifestActions
    }
    $manifest | ConvertTo-Json -Depth 5 | Set-Content -Path $script:ManifestPath -Force -Encoding UTF8
    Write-Status "Undo manifest saved to $($script:ManifestPath)" -Type Info
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
        exit 1
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
    'Adobe CEF Helper'
    'node'  # Adobe CEF/Node helpers - filtered by path below
)

# GrowthSDK relative path under each user's LocalLow
$GrowthSDKRelPath = 'Adobe\GrowthSDK'

# Additional Adobe telemetry/cache directories to neutralize
$AdditionalPaths = @(
    'Adobe\OOBE\opm.db'
    'Adobe\OOBE\PDApp\CCM\Telemetry'
)

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
    Add-Content -Path $script:LogFile -Value $logLine -ErrorAction SilentlyContinue

    switch ($Type) {
        'Header'  { Write-Host "`n=== $Message ===`n" -ForegroundColor Cyan }
        'Success' { Write-Host "  [OK] $Message" -ForegroundColor Green }
        'Warning' { Write-Host "  [--] $Message" -ForegroundColor Yellow }
        'Error'   { Write-Host "  [!!] $Message" -ForegroundColor Red }
        'Info'    { Write-Host "  [..] $Message" -ForegroundColor Gray }
        'DryRun'  { Write-Host "  [>>] $Message" -ForegroundColor Magenta }
    }
}

function Stop-AdobeProcesses {
    Write-Status 'Terminating Adobe background processes' -Type Header

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
            $script:Counters.TasksDisabled++
        } catch {
            Write-Status "Failed to disable task: $($task.TaskName) - $($_.Exception.Message)" -Type Error
        }
    }
}

function Disable-AdobeServices {
    Write-Status 'Disabling Adobe telemetry services' -Type Header

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
                Stop-Service -Name $svcName -Force -ErrorAction SilentlyContinue
            }
            Set-Service -Name $svcName -StartupType Disabled -ErrorAction SilentlyContinue
            Write-Status "Disabled service: $svcName ($($svc.DisplayName))" -Type Success
            $script:Counters.ServicesDisabled++
        } else {
            Write-Status "Service not found: $svcName" -Type Warning
        }
    }
}

function Set-AdobeRegistryPolicies {
    Write-Status 'Setting registry policies to disable telemetry' -Type Header

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
            Path  = 'HKLM:\SOFTWARE\Adobe\Adobe Genuine Service'
            Values = @{
                'AgsDisabled'           = 1
            }
        },
        @{
            Path  = 'HKCU:\SOFTWARE\Adobe\CommonFiles\UsageCC'
            Values = @{
                'AUSUF'                 = 0     # Disable usage framework
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
            if (-not (Test-Path $entry.Path)) {
                New-Item -Path $entry.Path -Force | Out-Null
            }
            Set-ItemProperty -Path $entry.Path -Name $name -Value $val -Type DWord -Force
            Write-Status "Set $($entry.Path)\$name = $val" -Type Success
            $script:Counters.RegistryKeysSet++
        }
    }
}

function Block-AdobeFirewall {
    Write-Status 'Creating firewall rules to block Adobe telemetry' -Type Header

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

    # Block outbound to telemetry domains by resolving IPs
    # Log every domain's resolved IPs for audit purposes
    $resolvedIPs = @()
    $domainIPMap = @{}
    foreach ($domain in $TelemetryDomains) {
        try {
            $ips = [System.Net.Dns]::GetHostAddresses($domain) |
                   Where-Object { $_.AddressFamily -eq 'InterNetwork' } |
                   Select-Object -ExpandProperty IPAddressToString
            if ($ips) {
                $resolvedIPs += $ips
                $domainIPMap[$domain] = $ips
                Write-Status "$domain -> $($ips -join ', ')" -Type Info
            } else {
                Write-Status "$domain -> no IPv4 records" -Type Warning
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

    $resolvedIPs = $resolvedIPs | Sort-Object -Unique

    if ($resolvedIPs.Count -gt 0) {
        if ($DryRun) {
            Write-Status "Would block $($resolvedIPs.Count) telemetry IPs via firewall" -Type DryRun
        } else {
            New-NetFirewallRule -DisplayName 'Block Adobe Telemetry - Outbound IPs (TCP)' `
                -Direction Outbound `
                -Action Block `
                -RemoteAddress $resolvedIPs `
                -Protocol TCP `
                -Profile Any `
                -Enabled True `
                -Description 'Blocks outbound TCP to Adobe telemetry/analytics servers.' |
                Out-Null
            New-NetFirewallRule -DisplayName 'Block Adobe Telemetry - Outbound IPs (UDP)' `
                -Direction Outbound `
                -Action Block `
                -RemoteAddress $resolvedIPs `
                -Protocol UDP `
                -Profile Any `
                -Enabled True `
                -Description 'Blocks outbound UDP/QUIC to Adobe telemetry/analytics servers.' |
                Out-Null
            Write-Status "Blocked $($resolvedIPs.Count) telemetry IPs via firewall (TCP+UDP)" -Type Success
        }
        $script:Counters.FirewallIPsBlocked = $resolvedIPs.Count
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
    $telemetryExeNames = @('LogTransport2.exe', 'CRWindowsClientService.exe', 'CRLogTransport.exe', 'AdobeCollabSync.exe')
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
            }
            $script:Counters.FirewallRulesAdded++
        }
    }

    if ($script:Counters.FirewallRulesAdded -gt 1) {
        Write-Status "Blocked $($script:Counters.FirewallRulesAdded - 1) Adobe executables via firewall" -Type Success
    } else {
        Write-Status 'No known Adobe telemetry executables found on disk' -Type Warning
    }

    # Add persistent null routes for resolved telemetry IPs
    if ($resolvedIPs.Count -gt 0) {
        $routesAdded = 0
        foreach ($ip in $resolvedIPs) {
            $existing = route print $ip 2>&1 | Select-String $ip -ErrorAction SilentlyContinue
            if ($existing) { continue }
            if ($DryRun) {
                $routesAdded++
            } else {
                & route -p add $ip mask 255.255.255.255 0.0.0.0 2>&1 | Out-Null
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
}

function Block-AdobeHostsFile {
    Write-Status 'Blocking Adobe telemetry via hosts file' -Type Header

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

    # Remove Adobe WAM injected entries if present
    $wamMarker = '# Adobe Creative Cloud WAM - Start'
    $wamEndMarker = '# Adobe Creative Cloud WAM - End'
    if ($hostsContent -match [regex]::Escape($wamMarker)) {
        $wamPattern = "(?s)\r?\n?$([regex]::Escape($wamMarker)).*?$([regex]::Escape($wamEndMarker))\r?\n?"
        $hostsContent = $hostsContent -replace $wamPattern, ''
        Set-Content -Path $hostsPath -Value $hostsContent.TrimEnd() -Force -Encoding ASCII
        Write-Status 'Removed Adobe WAM hosts injection' -Type Success
    }

    # Remove previous block if it exists (idempotent refresh)
    if ($hostsContent -match [regex]::Escape($marker)) {
        $pattern = "(?s)$([regex]::Escape($marker)).*?$([regex]::Escape($endMarker))\r?\n?"
        $hostsContent = $hostsContent -replace $pattern, ''
        Set-Content -Path $hostsPath -Value $hostsContent.TrimEnd() -Force -Encoding ASCII
    }

    # Append new block
    $blockEntries = @($marker)
    foreach ($domain in $TelemetryDomains) {
        $blockEntries += "0.0.0.0    $domain"
    }
    $blockEntries += $endMarker

    $newBlock = "`r`n" + ($blockEntries -join "`r`n") + "`r`n"
    Add-Content -Path $hostsPath -Value $newBlock -Encoding ASCII
    Write-Status "Added $($TelemetryDomains.Count) domains to hosts file" -Type Success
    $script:Counters.DomainsBlocked = $TelemetryDomains.Count

    # Flush DNS cache so changes take effect immediately
    & ipconfig /flushdns 2>&1 | Out-Null
    Write-Status 'DNS cache flushed' -Type Info
}

function Disable-CCXProcess {
    Write-Status 'Permanently neutralizing CCXProcess' -Type Header

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
        Set-ItemProperty -Path $ifeoPath -Name 'Debugger' -Value $ifeoTarget -Type String -Force
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
            }
            $script:Counters.FirewallRulesAdded++
        }
    }
}

function Disable-AdobeIPCBroker {
    Write-Status 'Restricting AdobeIPCBroker (firewall only - required for app launch)' -Type Header

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
                    }
                    $script:Counters.StartupDisabled++
                } else {
                    Write-Status "Already disabled: $name" -Type Warning
                }
            }
        }
    }
}

function Disable-AcrobatTelemetry {
    Write-Status 'Disabling Adobe Acrobat/Reader telemetry via registry' -Type Header

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
            if (-not (Test-Path $entry.Path)) {
                New-Item -Path $entry.Path -Force | Out-Null
            }
            $regType = if ($entry.Type) { $entry.Type } else { 'DWord' }
            Set-ItemProperty -Path $entry.Path -Name $name -Value $val -Type $regType -Force
            Write-Status "Set $($entry.Path)\$name = $val" -Type Success
            $script:Counters.RegistryKeysSet++
        }
    }
}

# ── Undo Function ────────────────────────────────────────────────────────────

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

    # 3b. Remove persistent null routes for telemetry IPs
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
    $ifeoPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\CCXProcess.exe'
    if (Test-Path $ifeoPath) {
        Remove-Item -Path $ifeoPath -Recurse -Force -ErrorAction SilentlyContinue
        Write-Status 'Removed IFEO redirect for CCXProcess.exe' -Type Success
    } else {
        Write-Status 'No IFEO redirect found for CCXProcess.exe' -Type Warning
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

    Write-Status 'Undo Complete' -Type Header
    Write-Host '  All Adobe telemetry blocks have been reversed.' -ForegroundColor Green
    Write-Host '  A reboot is recommended to ensure all changes take effect.' -ForegroundColor Yellow
    Write-Host ''
}

# ── Status Function ──────────────────────────────────────────────────────────

function Show-Status {
    Write-Status 'Adobe Telemetry Status Report' -Type Header
    Write-Host ''

    # Services
    Write-Host '  --- Services ---' -ForegroundColor Cyan
    foreach ($svcName in $Services) {
        $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
        if ($svc) {
            $startType = (Get-CimInstance Win32_Service -Filter "Name='$svcName'" -ErrorAction SilentlyContinue).StartMode
            Write-Host "    $svcName : $($svc.Status) ($startType)" -ForegroundColor $(if ($svc.Status -eq 'Stopped' -or $startType -eq 'Disabled') { 'Green' } else { 'Red' })
        } else {
            Write-Host "    $svcName : NotFound" -ForegroundColor DarkGray
        }
    }

    # Scheduled Tasks
    Write-Host ''
    Write-Host '  --- Scheduled Tasks ---' -ForegroundColor Cyan
    $allTasks = Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object {
        $_.TaskName -like '*Adobe*' -or $_.TaskPath -like '*Adobe*'
    }
    if ($allTasks) {
        foreach ($task in $allTasks) {
            $color = if ($task.State -eq 'Disabled') { 'Green' } else { 'Red' }
            Write-Host "    $($task.TaskName) : $($task.State)" -ForegroundColor $color
        }
    } else {
        Write-Host '    No Adobe scheduled tasks found' -ForegroundColor DarkGray
    }

    # GrowthSDK
    Write-Host ''
    Write-Host '  --- GrowthSDK ---' -ForegroundColor Cyan
    $profileRoot = Split-Path $env:USERPROFILE
    $userProfiles = Get-ChildItem $profileRoot -Directory -ErrorAction SilentlyContinue
    foreach ($userProf in $userProfiles) {
        $localLow = Join-Path $userProf.FullName 'AppData\LocalLow'
        if (-not (Test-Path $localLow)) { continue }
        $growthDir = Join-Path $localLow $GrowthSDKRelPath
        if (Test-Path $growthDir -PathType Leaf) {
            Write-Host "    $($userProf.Name) : Blocked (decoy file)" -ForegroundColor Green
        } elseif (Test-Path $growthDir -PathType Container) {
            Write-Host "    $($userProf.Name) : Present (ACTIVE)" -ForegroundColor Red
        } else {
            Write-Host "    $($userProf.Name) : NotFound" -ForegroundColor DarkGray
        }
    }

    # Firewall Rules
    Write-Host ''
    Write-Host '  --- Firewall Rules ---' -ForegroundColor Cyan
    $fwRules = Get-NetFirewallRule -DisplayName 'Block Adobe Telemetry*' -ErrorAction SilentlyContinue
    $count = if ($fwRules) { @($fwRules).Count } else { 0 }
    $fwColor = if ($count -gt 0) { 'Green' } else { 'Yellow' }
    Write-Host "    Adobe telemetry block rules: $count" -ForegroundColor $fwColor

    # Hosts File
    Write-Host ''
    Write-Host '  --- Hosts File ---' -ForegroundColor Cyan
    $hostsPath = "$env:SystemRoot\System32\drivers\etc\hosts"
    $marker = '# --- Adobe Telemetry Block (Disable-AdobeTelemetry.ps1) ---'
    $hostsContent = Get-Content $hostsPath -Raw -ErrorAction SilentlyContinue
    if ($hostsContent -and $hostsContent -match [regex]::Escape($marker)) {
        Write-Host '    Adobe telemetry block: Present' -ForegroundColor Green
    } else {
        Write-Host '    Adobe telemetry block: Not present' -ForegroundColor Yellow
    }

    # IFEO
    Write-Host ''
    Write-Host '  --- IFEO Redirects ---' -ForegroundColor Cyan
    $ifeoPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\CCXProcess.exe'
    if (Test-Path $ifeoPath) {
        $debugger = (Get-ItemProperty -Path $ifeoPath -Name 'Debugger' -ErrorAction SilentlyContinue).Debugger
        if ($debugger) {
            Write-Host "    CCXProcess.exe IFEO: Active (Debugger=$debugger)" -ForegroundColor Green
        } else {
            Write-Host '    CCXProcess.exe IFEO: Key exists but no Debugger value' -ForegroundColor Yellow
        }
    } else {
        Write-Host '    CCXProcess.exe IFEO: Not set' -ForegroundColor Yellow
    }

    # Registry Policies
    Write-Host ''
    Write-Host '  --- Registry Policies ---' -ForegroundColor Cyan
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
        @{ Path = 'HKCU:\SOFTWARE\Adobe\CommonFiles\CRLog'; Name = 'Never Ask'; Expected = '1' }
    )
    foreach ($check in $regChecks) {
        if (Test-Path $check.Path) {
            $val = (Get-ItemProperty -Path $check.Path -Name $check.Name -ErrorAction SilentlyContinue).($check.Name)
            if ($null -ne $val) {
                $color = if ($val -eq $check.Expected) { 'Green' } else { 'Red' }
                Write-Host "    $($check.Name) = $val (expected $($check.Expected))" -ForegroundColor $color
            } else {
                Write-Host "    $($check.Name) : Not set" -ForegroundColor Yellow
            }
        } else {
            Write-Host "    $($check.Name) : Path not found" -ForegroundColor Yellow
        }
    }

    # Startup entries
    Write-Host ''
    Write-Host '  --- Startup Entries ---' -ForegroundColor Cyan
    $runPaths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
    )
    $foundStartup = $false
    foreach ($runPath in $runPaths) {
        if (-not (Test-Path $runPath)) { continue }
        $props = Get-ItemProperty $runPath -ErrorAction SilentlyContinue
        foreach ($name in $props.PSObject.Properties.Name) {
            if ($name -match 'Adobe|CCXProcess|AdobeGC|AdobeAAM') {
                $val = $props.$name
                $foundStartup = $true
                if ($val -like 'REM *') {
                    Write-Host "    $name : Disabled" -ForegroundColor Green
                } else {
                    Write-Host "    $name : Enabled (ACTIVE)" -ForegroundColor Red
                }
            }
        }
    }
    if (-not $foundStartup) {
        Write-Host '    No Adobe startup entries found' -ForegroundColor DarkGray
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

    Write-Host ''
}

# ── Launcher Mode ──────────────────────────────────────────────────────────────

function Invoke-CleanLauncher {
    param([string]$AppName)

    # Discover the Adobe app executable
    $appExe = $null
    $appMap = @{
        'Photoshop'       = 'Photoshop.exe'
        'Illustrator'     = 'Illustrator.exe'
        'Premiere'        = 'Adobe Premiere Pro.exe'
        'PremierePro'     = 'Adobe Premiere Pro.exe'
        'AfterEffects'    = 'AfterFX.exe'
        'InDesign'        = 'InDesign.exe'
        'Lightroom'       = 'Lightroom.exe'
        'LightroomClassic' = 'Lightroom.exe'
        'Audition'        = 'Adobe Audition.exe'
        'Animate'         = 'Animate.exe'
        'MediaEncoder'    = 'Adobe Media Encoder.exe'
    }

    $exeName = $appMap[$AppName]
    if (-not $exeName) {
        $exeName = "$AppName.exe"
    }

    foreach ($installPath in $script:AdobeInstallPaths) {
        if (-not (Test-Path $installPath)) { continue }
        $found = Get-ChildItem -Path $installPath -Filter $exeName -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($found) { $appExe = $found.FullName; break }
    }

    if (-not $appExe) {
        Write-Status "Could not find $exeName in any Adobe install path" -Type Error
        exit 1
    }

    Write-Status "Clean Launcher: $AppName" -Type Header
    Write-Status "Executable: $appExe" -Type Info

    # Kill telemetry processes before launch
    Stop-AdobeProcesses

    # Launch the app
    Write-Status "Launching $AppName..." -Type Info
    $proc = Start-Process -FilePath $appExe -PassThru

    Write-Status "Waiting for $AppName to exit (PID $($proc.Id))..." -Type Info
    $proc.WaitForExit()
    Write-Status "$AppName exited" -Type Info

    # Re-kill telemetry processes after exit
    Start-Sleep -Seconds 2
    Stop-AdobeProcesses
    Write-Status 'Telemetry processes cleaned up' -Type Success
}

# ── Profile Export/Import ─────────────────────────────────────────────────────

function Export-RunProfile {
    param([string]$Path)
    $profileData = @{
        Version   = '2.1.0'
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

# Handle special modes before the standard flow
if ($ExportProfile) {
    Export-RunProfile -Path $ExportProfile
    exit 0
}
if ($ImportProfile) {
    Import-RunProfile -Path $ImportProfile
}

if ($Launcher) {
    Invoke-CleanLauncher -AppName $Launcher
    exit 0
}

Write-Host ''
Write-Host '  =============================================' -ForegroundColor Cyan
Write-Host '   Disable-AdobeTelemetry v2.1.0' -ForegroundColor White
Write-Host '   Comprehensive Adobe GrowthSDK + Telemetry' -ForegroundColor White
Write-Host '   Removal and Blocking Utility' -ForegroundColor White
Write-Host '  =============================================' -ForegroundColor Cyan

if ($DryRun) {
    Write-Host ''
    Write-Host '  *** DRY RUN MODE - No changes will be made ***' -ForegroundColor Magenta
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
$logHeader = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - Disable-AdobeTelemetry v2.1.0 started"
if ($Undo)       { $logHeader += ' (UNDO mode)' }
if ($StatusOnly) { $logHeader += ' (STATUS mode)' }
if ($DryRun)     { $logHeader += ' (DRY RUN mode)' }
if ($Profile -ne 'Standard') { $logHeader += " (Profile: $Profile)" }
if ($Only)       { $logHeader += " (Only: $($Only -join ','))" }
if ($Skip)       { $logHeader += " (Skip: $($Skip -join ','))" }
Add-Content -Path $script:LogFile -Value $logHeader -ErrorAction SilentlyContinue

if ($StatusOnly) {
    Show-Status
    exit 0
}

if ($Undo) {
    Invoke-Undo
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
        $srEnabled = (Get-ComputerRestorePoint -ErrorAction SilentlyContinue) -ne $null -or $true
        Checkpoint-Computer -Description 'Pre-Disable-AdobeTelemetry' -RestorePointType MODIFY_SETTINGS -ErrorAction Stop
        Write-Status 'System restore point created' -Type Success
    } catch {
        Write-Status "Could not create restore point: $($_.Exception.Message)" -Type Warning
    }
} else {
    Write-Status 'Would create system restore point' -Type DryRun
}

# Execute each phase if enabled
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

Show-Summary

if ($DryRun) {
    Write-Host '  No changes were made (dry run).' -ForegroundColor Magenta
} else {
    Write-Host '  All Adobe telemetry and GrowthSDK components have been disabled.' -ForegroundColor Green
    Write-Host '  A reboot is recommended to ensure all changes take effect.' -ForegroundColor Yellow
}
Write-Host '  Note: Premiere/Photoshop will continue to function normally.' -ForegroundColor Gray
Write-Host "  Log saved to: $script:LogFile" -ForegroundColor Gray
Write-Host ''
