# Disable-AdobeTelemetry

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
| **Kill Processes** | Terminates CCXProcess, CCLibrary, AdobeIPCBroker, Adobe Desktop Service, AGSService, AdobeNotificationClient, AdobeUpdateService, and Adobe-spawned Node.js instances |
| **Neutralize GrowthSDK** | Removes the GrowthSDK directory across all user profiles and plants a read-only, system-hidden, ACL-denied blocker file in its place so it cannot be recreated |
| **Disable CCXProcess** | Renames the executable to `.disabled`, applies IFEO debugger redirect as a failsafe, and strips execute permissions via ACL deny |
| **Firewall AdobeIPCBroker** | Blocks outbound connections only — IPCBroker is required for Premiere/Photoshop to launch, so it is left functional but firewalled. The script also auto-restores IPCBroker if a previous run disabled it. |
| **Disable Scheduled Tasks** | Disables all Adobe-related scheduled tasks (AdobeGCInvoker, Genuine Monitor, updaters, etc.) |
| **Disable Services** | Stops and sets to Disabled: AGSService, AGMService, AdobeARMservice, AdobeUpdateService, CCXProcess |
| **Registry Policies** | Sets `DisableUsageData`, `DisableGrowth`, `DisableAutoupdates`, `AgsDisabled`, and disables the usage framework under enterprise policy keys |
| **Firewall Rules** | Resolves and blocks ~20 Adobe telemetry domains by IP, plus blocks known telemetry executables by program path |
| **Hosts File** | Sinkhole routes all Adobe telemetry/analytics domains to `0.0.0.0` |
| **Startup Entries** | Disables Adobe auto-run registry entries across HKLM and HKCU |

## Blocked Domains

The script blocks outbound connections to the following Adobe telemetry and analytics endpoints:

```
cc-api-data.adobe.io        notify.adobe.io             prod.adobegc.com
ada.adobe.io                assets.adobedtm.com         geo2.adobe.com
pv2.adobe.com               lcs-cops.adobe.io           lcs-robs.adobe.io
sstats.adobe.com             stats.adobe.com             ic.adobe.io
cc-cdn.adobe.com             p13n.adobe.io               platform.adobe.io
use.typekit.net              adobeid-na1.services.adobe.com
r.openx.net                 dpm.demdex.net              bam.nr-data.net
fls.doubleclick.net
```

## The "Triple-Layer" Approach

For persistent executables like CCXProcess that Adobe apps relaunch on startup, the script uses three layers of defense:

1. **Rename** — The executable is renamed to `.disabled` so nothing can find it at the expected path.
2. **IFEO Redirect** — An Image File Execution Options debugger key is set to `nul`. Even if Adobe restores the original executable (e.g., during an update), Windows intercepts the launch and silently kills it.
3. **ACL Deny** — If the rename fails due to a file lock, execute permissions are stripped via a deny ACL for Everyone.

For GrowthSDK, a similar approach is used: the directory is replaced with a read-only, system-hidden file with a deny ACL on write/delete, preventing Adobe from recreating the directory structure.

> **Note:** AdobeIPCBroker.exe is **not** given this treatment. It is required for Premiere Pro and Photoshop to start. Instead, it is blocked via outbound firewall rule only — it can still handle local inter-process communication but cannot phone home. If a previous run of the script disabled IPCBroker, the current version will automatically restore it.

## Usage

### Requirements

- Windows 10/11
- PowerShell 5.1+
- **Administrator privileges** (the script will exit if not elevated)

### Run

```powershell
# Right-click PowerShell → Run as Administrator
.\Disable-AdobeTelemetry.ps1
```

The script presents a confirmation prompt before making any changes and offers an optional reboot at completion.

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

To undo all changes:

1. Rename `CCXProcess.exe.disabled` back to `CCXProcess.exe` in the Adobe Creative Cloud Experience directory
2. Remove the IFEO registry key at `HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\CCXProcess.exe`
3. Delete the GrowthSDK blocker file and remove the deny ACLs
4. Re-enable disabled services: `Set-Service -Name AGSService -StartupType Automatic` (repeat for each service)
5. Remove firewall rules named `Block Adobe Telemetry*`
6. Remove the hosts file block between the `# --- Adobe Telemetry Block ---` markers
7. Re-enable scheduled tasks and restore startup registry entries

## License

MIT
