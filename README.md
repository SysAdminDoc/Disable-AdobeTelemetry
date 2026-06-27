<p align="center"><img src="icon.svg" width="128" height="128" alt="Disable-AdobeTelemetry"></p>

# Disable-AdobeTelemetry

![Version](https://img.shields.io/badge/version-v2.2.0-blue) ![License](https://img.shields.io/badge/license-MIT-green) ![Platform](https://img.shields.io/badge/platform-PowerShell-lightgrey)

A PowerShell script that comprehensively disables Adobe's background telemetry, analytics, in-app marketing (GrowthSDK), and persistent background processes that run even after closing Adobe applications.

## The Problem

Adobe Creative Cloud applications (Premiere Pro, Photoshop, etc.) install and continuously run background processes that:

- **GrowthSDK** (`%LocalAppData%Low\Adobe\GrowthSDK`) — Adobe's in-app marketing and analytics framework that serves upsell prompts, A/B tests UI elements, and phones home with usage data. Deleting the directory does nothing — it regenerates every launch.
- **CCXProcess.exe** (`C:\Program Files\Adobe\Adobe Creative Cloud Experience`) — The Creative Cloud Experience host. Persists after closing all Adobe apps and relaunches itself via scheduled tasks and other Adobe processes.
- **AdobeIPCBroker.exe** (`C:\Program Files (x86)\Common Files\Adobe\Adobe Desktop Common\IPCBox`) — Inter-process communication broker that facilitates telemetry and CC service communication. Also persists after closing Adobe apps.
- **Multiple background services and scheduled tasks** — AGSService, AdobeGCInvoker, Adobe Genuine Monitor, and others that maintain telemetry pipelines and "genuine" software checks.

Simply killing these processes or deleting their files is temporary — Adobe apps relaunch them on startup, and CC services recreate deleted directories.

## What This Script Does

| Action | Details |
|---|---|
| **Kill Processes** | Terminates CCXProcess, CCLibrary, AdobeIPCBroker, Adobe Desktop Service, AGSService, AGMService, AdobeNotificationClient, AdobeUpdateService, CoreSync, LogTransport2, AdobeCollabSync, CRWindowsClientService, CRLogTransport, acrotray, Adobe CEF Helper, and Adobe-spawned Node.js instances |
| **Neutralize GrowthSDK** | Removes the GrowthSDK directory across all user profiles and plants a read-only, system-hidden, ACL-denied blocker file in its place so it cannot be recreated |
| **Disable CCXProcess** | Renames the executable to `.disabled`, applies IFEO debugger redirect as a failsafe, and strips execute permissions via ACL deny |
| **Firewall AdobeIPCBroker** | Blocks outbound connections only — IPCBroker is required for Premiere/Photoshop to launch, so it is left functional but firewalled. The script also auto-restores IPCBroker if a previous run disabled it. |
| **Disable Scheduled Tasks** | Disables all Adobe-related scheduled tasks (AdobeGCInvoker, Genuine Monitor, updaters, etc.) |
| **Disable Services** | Stops and sets to Disabled: AGSService, AGMService, AdobeARMservice, AdobeUpdateService, CCXProcess |
| **Registry Policies** | Sets `DisableUsageData`, `DisableGrowth`, `DisableAutoupdates`, `AgsDisabled`, and disables the usage framework under enterprise policy keys |
| **Firewall Rules** | Resolves and blocks ~40 Adobe telemetry domains by IP (TCP+UDP), plus blocks known telemetry executables by program path |
| **Hosts File** | Sinkhole routes all Adobe telemetry/analytics domains to `0.0.0.0`, detects and removes Adobe WAM hosts injections, flushes DNS cache |
| **Startup Entries** | Disables Adobe auto-run registry entries across HKLM and HKCU |

## Blocked Domains

The script blocks outbound connections to the following Adobe telemetry and analytics endpoints:

```
cc-api-data.adobe.io         notify.adobe.io              prod.adobegc.com
ada.adobe.io                 assets.adobedtm.com          geo2.adobe.com
pv2.adobe.com                lcs-cops.adobe.io            lcs-robs.adobe.io
lcs-ulecs.adobe.io           sstats.adobe.com             stats.adobe.com
ic.adobe.io                  cc-cdn.adobe.com             p13n.adobe.io
platform.adobe.io            adobeid-na1.services.adobe.com
na1r.services.adobe.com      hlrc.adobegenuine.com        genuine.adobe.com
prod.adobegenuine.com        crs.cr.adobe.com             crlog-crcn.adobe.com
hbrcv.adobe.com              fp.adobestats.io             adobe.demdex.net
adobedc.demdex.net           odin.adobe.com               armmf.adobe.com
aepxlg.adobe.com             utut-service.adobe.com       senseimds.adobe.io
cai-splunk-proxy.adobe.io    client.messaging.adobe.com   server.messaging.adobe.com
ui.messaging.adobe.com       detect-ccd.creativecloud.adobe.com
prod-rel-ffc-ccm.oobesaas.adobe.com
r.openx.net                  dpm.demdex.net               bam.nr-data.net
fls.doubleclick.net
```

## The "Triple-Layer" Approach

For persistent executables like CCXProcess that Adobe apps relaunch on startup, the script uses three layers of defense:

1. **Rename** — The executable is renamed to `.disabled` so nothing can find it at the expected path.
2. **IFEO Redirect** — An Image File Execution Options debugger key is set to a non-existent path (`AdobeTelemetryBlock.invalid`). Even if Adobe restores the original executable (e.g., during an update), Windows intercepts the launch and silently kills it.
3. **ACL Deny** — If the rename fails due to a file lock, execute permissions are stripped via a deny ACL for Everyone.

For GrowthSDK, a similar approach is used: the directory is replaced with a read-only, system-hidden file with a deny ACL on write/delete, preventing Adobe from recreating the directory structure.

> **Note:** AdobeIPCBroker.exe is **not** given this treatment. It is required for Premiere Pro and Photoshop to start. Instead, it is blocked via outbound firewall rule only — it can still handle local inter-process communication but cannot phone home. If a previous run of the script disabled IPCBroker, the current version will automatically restore it.

## Usage

### Requirements

- Windows 10/11
- PowerShell 5.1+
- **Administrator privileges** (the script will exit if not elevated)

### GUI

```powershell
.\Disable-AdobeTelemetry.GUI.ps1
```

A WPF companion GUI with Catppuccin Mocha dark theme, profile selection, dry run toggle, and streaming log output. Auto-elevates to admin.

### CLI

```powershell
# Right-click PowerShell → Run as Administrator
.\Disable-AdobeTelemetry.ps1

# Preview what would change without writing anything
.\Disable-AdobeTelemetry.ps1 -DryRun

# Run only specific phases (Kill, GrowthSDK, CCXProcess, IPCBroker, Tasks, Services, Registry, Firewall, Hosts, Acrobat, Startup)
.\Disable-AdobeTelemetry.ps1 -Only Firewall,Hosts

# Run everything except process killing
.\Disable-AdobeTelemetry.ps1 -Skip Kill

# Light touch: block telemetry domains and kill processes only (no service/task/registry changes)
.\Disable-AdobeTelemetry.ps1 -Profile Minimal

# Maximum blocking: includes font domains and cloud library endpoints
.\Disable-AdobeTelemetry.ps1 -Profile Aggressive

# Clean launch: kill telemetry, run Photoshop, re-kill on exit (no permanent changes)
.\Disable-AdobeTelemetry.ps1 -Launcher Photoshop

# Check current status of all protections
.\Disable-AdobeTelemetry.ps1 -StatusOnly

# Install weekly watchdog (Mondays 9 AM) to reassert blocks after Adobe updates
.\Disable-AdobeTelemetry.ps1 -InstallWatchdog

# Reverse all changes
.\Disable-AdobeTelemetry.ps1 -Undo
```

The script executes immediately without confirmation prompts and recommends a reboot at completion.

### Best Results

For the cleanest run, close all Adobe applications before executing. If any rename operations report "file locked," reboot and re-run the script before opening any Adobe apps — the IFEO redirects will already be active as a failsafe in the meantime.

## What Still Works

Premiere Pro, Photoshop, Illustrator, After Effects, and other Creative Cloud applications continue to function normally. What you lose:

- In-app upsell/marketing popups
- CC Libraries panel sync
- Adobe usage analytics and telemetry
- Adobe Genuine Software checks
- Automatic background updates (you can still manually update via Creative Cloud)

## After Adobe Updates

CC application updates may restore disabled executables. The IFEO debugger redirects survive updates and will catch any restored processes automatically. Re-run the script after major updates if you want to re-rename the executables for cleanliness.

## Reversal

```powershell
.\Disable-AdobeTelemetry.ps1 -Undo
```

The `-Undo` switch automatically reverses all changes: re-enables services and scheduled tasks, removes firewall rules, removes the hosts file block, removes IFEO debugger redirects, restores renamed executables, removes GrowthSDK blocker files, removes registry policy overrides, and re-enables startup entries.

## License

MIT
