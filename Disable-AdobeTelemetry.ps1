#Requires -RunAsAdministrator
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
      7. Optionally blocks domains via hosts file

.NOTES
    Author  : Matt (Maven Imaging)
    Version : 1.0
    Date    : 2026-02-02
#>

# ── Config ──────────────────────────────────────────────────────────────────────

$ErrorActionPreference = 'SilentlyContinue'

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
    'node'  # Adobe CEF/Node helpers - filtered by path below
)

# GrowthSDK relative path under each user's LocalLow
$GrowthSDKRelPath = 'Adobe\GrowthSDK'

# Additional Adobe telemetry/cache directories to neutralize
$AdditionalPaths = @(
    'Adobe\OOBE\opm.db'
    'Adobe\OOBE\PDApp\CCM\Telemetry'
)

# Scheduled tasks to disable
$ScheduledTasks = @(
    'AdobeGCInvoker-1.0'
    'Adobe Acrobat Update Task'
    'Adobe Flash Player Updater'
    'Adobe Flash Player NPAPI Notifier'
    'Adobe Flash Player PPAPI Notifier'
    'AdobeAAMUpdater-1.0-*'
    'Adobe Genuine Monitor'
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
$TelemetryDomains = @(
    'cc-api-data.adobe.io'
    'notify.adobe.io'
    'prod.adobegc.com'
    'ada.adobe.io'
    'assets.adobedtm.com'
    'geo2.adobe.com'
    'pv2.adobe.com'
    'lcs-cops.adobe.io'
    'lcs-robs.adobe.io'
    'sstats.adobe.com'
    'stats.adobe.com'
    'r.openx.net'
    'dpm.demdex.net'
    'bam.nr-data.net'
    'fls.doubleclick.net'
    'ic.adobe.io'
    'cc-cdn.adobe.com'
    'use.typekit.net'           # Optional - font telemetry
    'p13n.adobe.io'             # Personalization / A-B testing
    'platform.adobe.io'         # Platform analytics
    'adobeid-na1.services.adobe.com' # Genuine check
)

# ── Functions ───────────────────────────────────────────────────────────────────

function Write-Status {
    param(
        [string]$Message,
        [ValidateSet('Info','Success','Warning','Error','Header')]
        [string]$Type = 'Info'
    )
    switch ($Type) {
        'Header'  { Write-Host "`n=== $Message ===`n" -ForegroundColor Cyan }
        'Success' { Write-Host "  [OK] $Message" -ForegroundColor Green }
        'Warning' { Write-Host "  [--] $Message" -ForegroundColor Yellow }
        'Error'   { Write-Host "  [!!] $Message" -ForegroundColor Red }
        'Info'    { Write-Host "  [..] $Message" -ForegroundColor Gray }
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
            $procs | Stop-Process -Force -ErrorAction SilentlyContinue
            Write-Status "Killed $($procs.Count) instance(s) of $procName" -Type Success
        } else {
            Write-Status "$procName not running" -Type Warning
        }
    }
}

function Remove-GrowthSDK {
    Write-Status 'Neutralizing GrowthSDK across all profiles' -Type Header

    # Get all user profile directories
    $profileRoot = Split-Path $env:USERPROFILE
    $profiles = Get-ChildItem $profileRoot -Directory -ErrorAction SilentlyContinue

    foreach ($profile in $profiles) {
        $localLow = Join-Path $profile.FullName 'AppData\LocalLow'
        if (-not (Test-Path $localLow)) { continue }

        $growthDir = Join-Path $localLow $GrowthSDKRelPath

        if (Test-Path $growthDir -PathType Container) {
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
                Write-Status "Removed and blocked GrowthSDK for $($profile.Name)" -Type Success
            } else {
                Write-Status "Could not remove GrowthSDK for $($profile.Name) (files locked?)" -Type Error
            }
        } else {
            if (Test-Path $growthDir -PathType Leaf) {
                Write-Status "GrowthSDK already blocked for $($profile.Name)" -Type Warning
            } else {
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
                Write-Status "Pre-blocked GrowthSDK for $($profile.Name)" -Type Success
            }
        }

        # Handle additional telemetry paths
        foreach ($relPath in $AdditionalPaths) {
            $targetPath = Join-Path $localLow $relPath
            if (Test-Path $targetPath -PathType Container) {
                Remove-Item $targetPath -Recurse -Force -ErrorAction SilentlyContinue
                Write-Status "Removed $relPath for $($profile.Name)" -Type Success
            }
        }
    }
}

function Disable-AdobeScheduledTasks {
    Write-Status 'Disabling Adobe scheduled tasks' -Type Header

    $allTasks = Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object {
        $_.TaskName -like '*Adobe*' -or $_.TaskPath -like '*Adobe*'
    }

    if (-not $allTasks) {
        Write-Status 'No Adobe scheduled tasks found' -Type Warning
        return
    }

    foreach ($task in $allTasks) {
        try {
            $task | Disable-ScheduledTask -ErrorAction Stop | Out-Null
            Write-Status "Disabled task: $($task.TaskName)" -Type Success
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
            if ($svc.Status -eq 'Running') {
                Stop-Service -Name $svcName -Force -ErrorAction SilentlyContinue
            }
            Set-Service -Name $svcName -StartupType Disabled -ErrorAction SilentlyContinue
            Write-Status "Disabled service: $svcName ($($svc.DisplayName))" -Type Success
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
        if (-not (Test-Path $entry.Path)) {
            New-Item -Path $entry.Path -Force | Out-Null
        }
        foreach ($name in $entry.Values.Keys) {
            $val = $entry.Values[$name]
            Set-ItemProperty -Path $entry.Path -Name $name -Value $val -Type DWord -Force
            Write-Status "Set $($entry.Path)\$name = $val" -Type Success
        }
    }
}

function Block-AdobeFirewall {
    Write-Status 'Creating firewall rules to block Adobe telemetry' -Type Header

    # Remove existing rules from a previous run
    $existing = Get-NetFirewallRule -DisplayName 'Block Adobe Telemetry*' -ErrorAction SilentlyContinue
    if ($existing) {
        $existing | Remove-NetFirewallRule -ErrorAction SilentlyContinue
        Write-Status 'Removed previous firewall rules' -Type Info
    }

    # Block outbound to telemetry domains by resolving IPs
    $resolvedIPs = @()
    foreach ($domain in $TelemetryDomains) {
        try {
            $ips = [System.Net.Dns]::GetHostAddresses($domain) |
                   Where-Object { $_.AddressFamily -eq 'InterNetwork' } |
                   Select-Object -ExpandProperty IPAddressToString
            if ($ips) { $resolvedIPs += $ips }
        } catch {
            # Domain may not resolve - that's fine
        }
    }

    $resolvedIPs = $resolvedIPs | Sort-Object -Unique

    if ($resolvedIPs.Count -gt 0) {
        New-NetFirewallRule -DisplayName 'Block Adobe Telemetry - Outbound IPs' `
            -Direction Outbound `
            -Action Block `
            -RemoteAddress $resolvedIPs `
            -Protocol TCP `
            -Profile Any `
            -Enabled True `
            -Description 'Blocks outbound connections to Adobe telemetry/analytics servers.' |
            Out-Null
        Write-Status "Blocked $($resolvedIPs.Count) telemetry IPs via firewall" -Type Success
    } else {
        Write-Status 'Could not resolve any telemetry domains (offline?)' -Type Warning
    }

    # Also block known Adobe telemetry executables
    $adobeExePaths = @(
        "$env:ProgramFiles\Common Files\Adobe\OOBE\PDApp\core\PDApp.exe"
        "$env:ProgramFiles\Common Files\Adobe\AdobeGCClient\AdobeGCClient.exe"
        "$env:ProgramFiles\Common Files\Adobe\OOBE\PDApp\UWA\UpdaterStartupUtility.exe"
        "${env:ProgramFiles(x86)}\Common Files\Adobe\OOBE\PDApp\core\PDApp.exe"
        "${env:ProgramFiles(x86)}\Common Files\Adobe\AdobeGCClient\AdobeGCClient.exe"
    )

    $ruleCount = 0
    foreach ($exePath in $adobeExePaths) {
        if (Test-Path $exePath) {
            $exeName = Split-Path $exePath -Leaf
            New-NetFirewallRule -DisplayName "Block Adobe Telemetry - $exeName" `
                -Direction Outbound `
                -Action Block `
                -Program $exePath `
                -Profile Any `
                -Enabled True `
                -Description "Blocks $exeName from reaching Adobe analytics servers." |
                Out-Null
            $ruleCount++
        }
    }

    if ($ruleCount -gt 0) {
        Write-Status "Blocked $ruleCount Adobe executables via firewall" -Type Success
    } else {
        Write-Status 'No known Adobe telemetry executables found on disk' -Type Warning
    }
}

function Block-AdobeHostsFile {
    Write-Status 'Blocking Adobe telemetry via hosts file' -Type Header

    $hostsPath = "$env:SystemRoot\System32\drivers\etc\hosts"
    $marker    = '# --- Adobe Telemetry Block (Disable-AdobeTelemetry.ps1) ---'
    $endMarker = '# --- End Adobe Telemetry Block ---'

    $hostsContent = Get-Content $hostsPath -Raw -ErrorAction SilentlyContinue

    # Remove previous block if it exists
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
        if (-not (Test-Path $ccxExe)) { continue }

        # Kill it first
        Get-Process -Name 'CCXProcess' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 500

        # Rename the executable so Adobe apps can't launch it
        $backupName = Join-Path $ccxDir 'CCXProcess.exe.disabled'
        if (Test-Path $ccxExe) {
            try {
                Rename-Item -Path $ccxExe -NewName 'CCXProcess.exe.disabled' -Force -ErrorAction Stop
                Write-Status "Renamed CCXProcess.exe -> CCXProcess.exe.disabled in $ccxDir" -Type Success
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
                } catch {
                    Write-Status "Could not modify CCXProcess.exe - try after closing all Adobe apps" -Type Error
                }
            }
        }

        # Also handle the Node.js helper that CCXProcess spawns
        $nodeExe = Join-Path $ccxDir 'libs\node.exe'
        if (Test-Path $nodeExe) {
            try {
                Rename-Item -Path $nodeExe -NewName 'node.exe.disabled' -Force -ErrorAction Stop
                Write-Status "Renamed CCX node.exe -> node.exe.disabled" -Type Success
            } catch {
                Write-Status "CCX node.exe rename failed (may be locked)" -Type Warning
            }
        }
    }

    # IFEO debugger redirect as a fallback - if anything tries to launch
    # CCXProcess.exe, Windows redirects it to a nonexistent debugger and it dies
    $ifeoPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\CCXProcess.exe'
    if (-not (Test-Path $ifeoPath)) {
        New-Item -Path $ifeoPath -Force | Out-Null
    }
    Set-ItemProperty -Path $ifeoPath -Name 'Debugger' -Value 'nul' -Type String -Force
    Write-Status 'Set IFEO debugger redirect for CCXProcess.exe (failsafe)' -Type Success

    # Block it in firewall by program path (in case it ever gets restored)
    foreach ($ccxDir in $ccxPaths) {
        $ccxExe = Join-Path $ccxDir 'CCXProcess.exe'
        $disabledExe = Join-Path $ccxDir 'CCXProcess.exe.disabled'
        $targetExe = if (Test-Path $ccxExe) { $ccxExe } elseif (Test-Path $disabledExe) { $ccxExe } else { $null }
        if ($targetExe) {
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
                Rename-Item -Path $disabledExe -NewName 'AdobeIPCBroker.exe' -Force -ErrorAction SilentlyContinue
                Write-Status "Restored previously disabled AdobeIPCBroker.exe in $ipcDir" -Type Success
                $ipcExe = Join-Path $ipcDir 'AdobeIPCBroker.exe'
            } else {
                continue
            }
        }

        # Remove any deny ACLs from a previous run
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

        # Firewall rule - block outbound only (local IPC still works)
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

    # Remove IFEO redirect if set by a previous run
    $ifeoPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\AdobeIPCBroker.exe'
    if (Test-Path $ifeoPath) {
        Remove-Item -Path $ifeoPath -Recurse -Force -ErrorAction SilentlyContinue
        Write-Status 'Removed previous IFEO redirect for AdobeIPCBroker.exe' -Type Success
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
                    Set-ItemProperty -Path $runPath -Name $name -Value "REM $val" -Force
                    Write-Status "Disabled startup entry: $name" -Type Success
                } else {
                    Write-Status "Already disabled: $name" -Type Warning
                }
            }
        }
    }
}

# ── Main Execution ──────────────────────────────────────────────────────────────

Write-Host ''
Write-Host '  =============================================' -ForegroundColor Cyan
Write-Host '   Disable-AdobeTelemetry v1.0' -ForegroundColor White
Write-Host '   Comprehensive Adobe GrowthSDK + Telemetry' -ForegroundColor White
Write-Host '   Removal and Blocking Utility' -ForegroundColor White
Write-Host '  =============================================' -ForegroundColor Cyan

# Verify admin
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)
if (-not $isAdmin) {
    Write-Status 'This script must be run as Administrator. Exiting.' -Type Error
    exit 1
}

# Confirm
Write-Host ''
Write-Host '  This script will:' -ForegroundColor White
Write-Host '    - Kill Adobe background processes' -ForegroundColor Gray
Write-Host '    - Remove GrowthSDK and plant blocker files' -ForegroundColor Gray
Write-Host '    - Permanently neutralize CCXProcess.exe' -ForegroundColor Gray
Write-Host '    - Firewall AdobeIPCBroker.exe (outbound only)' -ForegroundColor Gray
Write-Host '    - Disable Adobe scheduled tasks and services' -ForegroundColor Gray
Write-Host '    - Set registry policies against telemetry' -ForegroundColor Gray
Write-Host '    - Block telemetry via Windows Firewall' -ForegroundColor Gray
Write-Host '    - Block telemetry via hosts file' -ForegroundColor Gray
Write-Host '    - Disable Adobe startup/run entries' -ForegroundColor Gray
Write-Host ''

$confirm = Read-Host '  Proceed? (Y/N)'
if ($confirm -notin @('Y','y','Yes','yes')) {
    Write-Host '  Aborted.' -ForegroundColor Yellow
    exit 0
}

Stop-AdobeProcesses
Remove-GrowthSDK
Disable-CCXProcess
Disable-AdobeIPCBroker
Disable-AdobeScheduledTasks
Disable-AdobeServices
Set-AdobeRegistryPolicies
Block-AdobeFirewall
Block-AdobeHostsFile
Disable-AdobeStartupEntries

Write-Status 'Complete' -Type Header
Write-Host '  All Adobe telemetry and GrowthSDK components have been disabled.' -ForegroundColor Green
Write-Host '  A reboot is recommended to ensure all changes take effect.' -ForegroundColor Yellow
Write-Host '  Note: Premiere/Photoshop will continue to function normally.' -ForegroundColor Gray
Write-Host ''

$reboot = Read-Host '  Reboot now? (Y/N)'
if ($reboot -in @('Y','y','Yes','yes')) {
    Restart-Computer -Force
}
