# Disable-AdobeTelemetry

![Version](https://img.shields.io/badge/version-v2.4.1-blue) ![License](https://img.shields.io/badge/license-MIT-green) ![Platform](https://img.shields.io/badge/platform-PowerShell-lightgrey)

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
| **Firewall Rules** | Resolves and blocks the profile's Adobe telemetry domains (60 in Standard) by IP (TCP+UDP), plus blocks known telemetry executables by program path |
| **Hosts File** | Sinkhole routes all Adobe telemetry/analytics domains to `0.0.0.0`, detects and removes Adobe WAM hosts injections, flushes DNS cache |
| **Startup Entries** | Disables Adobe auto-run registry entries across HKLM and HKCU |

## Blocked Domains

Domains are tiered by profile: **Minimal** (22 pure-telemetry domains), **Standard** (default, 60 domains — adds messaging, crash reporting, Firefly/GenAI, Sensei, genuine/license checks), and **Aggressive** (75 domains — adds fonts/Typekit, CC extensions, home/search, RUM). Aggressive also blocks the primary apps' outbound traffic (`Acrobat.exe`/`AcroRd32.exe`), recursively firewalls every `.exe` under the Adobe install paths, and blocks DNS-over-TLS (port 853). The canonical lists live in [`Data/Inventories.psd1`](Data/Inventories.psd1). Activation and download endpoints (`ims-na1.adobelogin.com`, `auth.services.adobe.com`, `ccmdls.adobe.com`, `ardownload2.adobe.com`, `fonts.adobe.com`, etc.) are safelisted and never blocked, so licensing and sign-in keep working.

The Standard profile blocks outbound connections to:

```
acp-ss-ew1.adobe.io          ada.adobe.io                 adobe.demdex.net
adobe.tt.omtrdc.net          adobedc.demdex.net           adobeid-na1.services.adobe.com
aepxlg.adobe.com             analytics.adobe.com          armmf.adobe.com
assets.adobedtm.com          bam.nr-data.net              cai-splunk-proxy.adobe.io
cc-api-data.adobe.io         cc-cdn.adobe.com             cc-collab.adobe.io
cdn.experience.adobe.net     client.messaging.adobe.com   crlog-crcn.adobe.com
crs.cr.adobe.com             dc-genai-access-provisioning-api.adobe.io
dcs.adobedc.net              detect-ccd.creativecloud.adobe.com
dpm.demdex.net               fire-fly.adobe.io            firefly-ae.adobe.io
fls.doubleclick.net          fp.adobestats.io             genuine.adobe.com
geo2.adobe.com               hbc.adobe.io                 hbrcv.adobe.com
hz-telemetry-next.adobe.io   hz-telemetry.adobe.io        ic.adobe.io
js-agent.newrelic.com        lcs-cops.adobe.io            lcs-entitlement.adobe.io
lcs-robs.adobe.io            lcs-ulecs.adobe.io           na1r.services.adobe.com
notify.adobe.io              o1383653.ingest.sentry.io    o1383653.ingest.us.sentry.io
odin.adobe.com               p13n.adobe.io                platform.adobe.io
prod-rel-ffc-ccm.oobesaas.adobe.com                       prod.adobegc.com
prod.adobegenuine.com        r.openx.net                  scss-prod-ew1.adobesc.com
scss.adobesc.com             sensei-irl1.adobe.io         senseicore-ew1.adobe.io
senseimds.adobe.io           server.messaging.adobe.com   sstats.adobe.com
stats.adobe.com              ui.messaging.adobe.com       utut-service.adobe.com
```

## The "Triple-Layer" Approach

For persistent executables like CCXProcess that Adobe apps relaunch on startup, the script uses three layers of defense:

1. **Rename** — The executable is renamed to `.disabled` so nothing can find it at the expected path.
2. **IFEO Redirect** — An Image File Execution Options debugger key is set to a non-existent path (`AdobeTelemetryBlock.invalid`). Even if Adobe restores the original executable (e.g., during an update), Windows intercepts the launch and silently kills it.
3. **ACL Deny** — If the rename fails due to a file lock, execute permissions are stripped via a deny ACL for Everyone.

For GrowthSDK, a similar approach is used: the directory is replaced with a read-only, system-hidden file with a deny ACL on write/delete, preventing Adobe from recreating the directory structure.

> **Note:** AdobeIPCBroker.exe is **not** given this treatment. It is required for Premiere Pro and Photoshop to start. Instead, it is blocked via outbound firewall rule only — it can still handle local inter-process communication but cannot phone home. If a previous run of the script disabled IPCBroker, the current version will automatically restore it.

## Antivirus / EDR Notes (IFEO)

The IFEO debugger redirect used to neutralize `CCXProcess.exe`, `Creative Cloud Helper.exe`, and `AdobeNotificationClient.exe` sets an `Image File Execution Options\<exe>\Debugger` registry value pointing at a non-existent path. This is a legitimate, documented Windows mechanism, but it is also catalogued as [MITRE ATT&CK T1546.012 (Image File Execution Options Injection)](https://attack.mitre.org/techniques/T1546/012/) because malware abuses the same key for persistence.

As a result, some security products may flag the script's registry writes:

- **Malwarebytes** may report `RiskWare.IFEOHijack`.
- **EDR/SIEM** (Elastic, Splunk, Defender for Endpoint) may raise a registry-modification alert on the IFEO path.

These are expected false positives for this defensive use. In managed environments, whitelist the script before running:

- Add a path/hash exclusion for `Disable-AdobeTelemetry.ps1` in your AV/EDR console.
- The redirects target only the three Adobe executables above; the debugger value always resolves to `%SystemRoot%\System32\AdobeTelemetryBlock.invalid`, so the entries are easy to identify and audit.
- `-Undo` removes all IFEO entries the script created.

If you prefer to avoid IFEO entirely, the executables are also renamed to `.disabled` and ACL-denied (see the triple-layer approach above); run with `-Skip CCXProcess` to omit the IFEO layer, accepting that an Adobe update which restores the original executable will not be caught automatically.

## Install

Download the latest release ZIP from [GitHub Releases](https://github.com/SysAdminDoc/Disable-AdobeTelemetry/releases/latest), extract, and run. Each release includes the CLI script, GUI companion, README, and LICENSE.

```powershell
# Verify the download checksum
(Get-FileHash Disable-AdobeTelemetry-v2.4.1.zip -Algorithm SHA256).Hash
# Compare against the hash in SHA256SUMS.txt from the same release
```

Or clone the repo directly:

```powershell
git clone https://github.com/SysAdminDoc/Disable-AdobeTelemetry.git
cd Disable-AdobeTelemetry
```

## Usage

### Requirements

- Windows 10/11
- PowerShell 5.1+
- **Administrator privileges** (the script auto-elevates via UAC if not already elevated)

### GUI

```powershell
.\Disable-AdobeTelemetry.GUI.ps1
```

A WPF companion GUI with Catppuccin Mocha dark theme at full CLI parity. Includes profile selection, dry run toggle, streaming log output, watchdog install/remove, profile import/export with file pickers, JSON status save, WFP trace configuration, and plumbing test controls. Auto-elevates to admin.

### CLI

```powershell
# Run from any PowerShell prompt (auto-elevates via UAC)
.\Disable-AdobeTelemetry.ps1

# Preview what would change without writing anything
.\Disable-AdobeTelemetry.ps1 -DryRun

# Run only specific phases (Kill, GrowthSDK, CCXProcess, IPCBroker, Tasks, Services, Registry, Firewall, Hosts, Acrobat, Startup)
.\Disable-AdobeTelemetry.ps1 -Only Firewall,Hosts

# Run everything except process killing
.\Disable-AdobeTelemetry.ps1 -Skip Kill

# -Only and -Skip can be combined; -Skip always wins (this runs Firewall only)
.\Disable-AdobeTelemetry.ps1 -Only Firewall,Hosts -Skip Hosts

# Also deny SYSTEM write on the hosts file so Adobe WAM cannot re-inject its entry
# (opt-in: the SYSTEM watchdog can no longer reassert hosts entries while locked)
.\Disable-AdobeTelemetry.ps1 -LockHostsFile

# Light touch: block telemetry domains and kill processes only (no service/task/registry changes)
.\Disable-AdobeTelemetry.ps1 -Profile Minimal

# Maximum blocking: includes font domains and cloud library endpoints
.\Disable-AdobeTelemetry.ps1 -Profile Aggressive

# Clean launch: kill telemetry, run Photoshop, re-kill on exit (no permanent changes)
.\Disable-AdobeTelemetry.ps1 -Launcher Photoshop

# Export or import a validated fleet profile
.\Disable-AdobeTelemetry.ps1 -ExportProfile .\standard-profile.json
.\Disable-AdobeTelemetry.ps1 -ImportProfile .\standard-profile.json

# Check current status of all protections
.\Disable-AdobeTelemetry.ps1 -StatusOnly

# Install weekly watchdog (Mondays 9 AM) to reassert blocks after Adobe updates
.\Disable-AdobeTelemetry.ps1 -InstallWatchdog

# Reverse all changes
.\Disable-AdobeTelemetry.ps1 -Undo
```

The script executes immediately without confirmation prompts and recommends a reboot at completion.

Imported profiles fail closed before any protection phase runs. A profile must contain `SchemaVersion`, `Version`, `Profile`, and `Domains`; invalid JSON, unsupported schema versions, invalid profile tiers, invalid phase names, or malformed domains exit with code `2`.

After apply, the script verifies that the hosts block remains present, Adobe WAM hosts markers are absent, `detect-ccd.creativecloud.adobe.com` resolves to a sinkhole entry, firewall block rules exist, Dynamic Keyword rules exist when supported, and no Adobe-owned outbound connections remain. Verification failures are written to console output, JSONL logs, and `-StatusOnly -OutputFormat JSON`.

Upstream domain merges are audited in the JSONL log with source URL, fetch timestamp, added domains, safelisted domains, rejected malformed entries, and final domain count. Successful live fetches update a last-good cache under `%APPDATA%\Disable-AdobeTelemetry`; failed fetches use that cache when available. `-DryRun` merges upstream domains in memory so all subsequent phase counts are accurate, but does not persist the cache or make any system changes.

### Machine-Readable Output

```powershell
# JSON status snapshot for fleet management / automation
.\Disable-AdobeTelemetry.ps1 -StatusOnly -OutputFormat JSON
```

JSON status includes registry policy convergence entries for Adobe enterprise, Acrobat/Reader, Wow6432Node, Substance 3D, and current-user policies. Each entry includes `Phase`, `Path`, `Name`, `Type`, `Expected`, `Actual`, and `State` for fleet compliance checks.

Each apply/undo run also writes a structured JSONL log to `%APPDATA%\Disable-AdobeTelemetry\logs\Disable-AdobeTelemetry-<timestamp>.jsonl` with per-action entries for ingestion by fleet management tools.

A run-summary entry is also written to the **Windows Application event log** (source `Disable-AdobeTelemetry`) so SIEM/EDR pipelines can track outcomes without parsing files. Event IDs: `1000` = apply success, `2000` = apply partial (one or more phase errors), `3000` = failure, `4000` = undo. Dry runs do not write events. `-StatusOnly` reports whether the event source is registered.

### Intune Proactive Remediation

The [`fleet/`](fleet/) directory contains a detection/remediation script pair for Microsoft Intune (Proactive Remediations / device remediations):

- **`fleet/Detect-AdobeTelemetry.ps1`** — runs the main script in `-StatusOnly -OutputFormat JSON`, evaluates stable compliance signals (hosts block present, firewall rules present, target services blocked), and exits `0` (compliant) or `1` (remediate).
- **`fleet/Remediate-AdobeTelemetry.ps1`** — applies protections and maps the main script's exit codes (`0`/`3010` = success) to Intune's `0`/`1` convention.

Deploy `Disable-AdobeTelemetry.ps1` to the endpoint (e.g. `%ProgramData%\Disable-AdobeTelemetry\`) or pass `-ScriptPath`; both wrappers auto-search common locations. Run them in the **system** context (64-bit) — no interactive elevation is required because SYSTEM is already elevated.

### Exit Codes

| Code | Meaning |
|------|---------|
| `0` | Success (no reboot needed) or dry run completed |
| `1` | Fatal error |
| `2` | Invalid arguments |
| `3` | Partial success (some phases encountered errors) |
| `3010` | Success, reboot recommended (SCCM/Intune convention) |

### Best Results

For the cleanest run, close all Adobe applications before executing. If any rename operations report "file locked," reboot and re-run the script before opening any Adobe apps — the IFEO redirects will already be active as a failsafe in the meantime.

### Update Notifications

On each run the script performs a **non-blocking** check for a newer GitHub release. It reports from a local cache (refreshed at most once every 24 hours in a background job), so it never delays the run or blocks on the network. If a newer version is available, a warning with the releases URL is printed. The check is skipped in JSON status mode and never downloads anything automatically.

### DNS-over-HTTPS (DoH)

Hosts-file sinkholing works at the OS resolver level, but **DNS-over-HTTPS bypasses it entirely** — a browser or the OS resolving names over an encrypted HTTPS channel never consults the hosts file. The script detects system auto-DoH, per-interface enforced DoH, and Edge/Chrome/Firefox DoH policies, and warns you when any are active. `-StatusOnly` reports DoH state under **Hosts File**. When DoH is enabled, rely on the firewall and persistent-route layers (which block by IP regardless of how the name was resolved) or disable DoH for full hosts-level coverage.

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

The `-Undo` switch automatically reverses all changes: re-enables services and scheduled tasks, removes firewall rules, removes the hosts file block, removes any hosts-file SYSTEM deny-write lock, removes IFEO debugger redirects, restores renamed executables (including disabled startup shortcuts), removes GrowthSDK blocker files, removes registry policy overrides, and re-enables startup entries.

## Development

Static inventories (processes, services, telemetry domains, paths) are maintained in `Data/Inventories.psd1`. After editing the data file, run `Build.ps1` to regenerate the main script:

```powershell
.\Build.ps1           # Regenerate Disable-AdobeTelemetry.ps1 from data file
.\Build.ps1 -Verify   # Check if data file and script are in sync
```

Tests:

```powershell
Invoke-Pester -Path .\Tests -Output Detailed
```

## License

MIT
