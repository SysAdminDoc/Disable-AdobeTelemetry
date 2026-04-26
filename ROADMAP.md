# Disable-AdobeTelemetry Roadmap

PowerShell script that kills Adobe CC telemetry, neutralizes GrowthSDK, firewalls IPCBroker, and sinkholes ~20 telemetry domains. Tracks work beyond v1.1.0.

## Planned Features

### Core
- Full JSON undo manifest logging every file rename, ACL deny, registry key, firewall rule, hosts line, service state, task state (so `-Undo` becomes real)
- `-DryRun` mode reporting all planned actions without writing
- `-Only` / `-Skip` phase flags (`Kill,GrowthSDK,IPCBroker,Tasks,Services,Registry,Firewall,Hosts,Startup`) for surgical reruns
- `-Status` mode listing current state of every protection (is GrowthSDK blocker present? IFEO active? firewall rule present? hosts line present?)
- Idempotent re-runs: detect existing blockers and skip/refresh instead of piling up duplicate firewall rules
- Re-run guard: verify IPCBroker restore worked before continuing (currently handled but lacks assertion)

### Coverage Expansion
- Extend domain blocklist via an externalized `adobe-telemetry-domains.json` updated from a community source (AdGuard / hagezi / 0ticks Adobe lists)
- Block Adobe Genuine Service v2 (`adobegcclient.exe`) after confirming no licensing impact on legit subscribers
- Handle Substance suite, Acrobat DC, and Dimension binaries (currently CC-focused)
- Detect Premiere Pro / Photoshop / Illustrator install paths dynamically instead of hard-coding Program Files
- Catch the Adobe Desktop Common Notification app (`AdobeNotificationClient`) and its cloud-only upsells
- Neutralize the Adobe CEF-based Creative Cloud app window that auto-pops after updates

### Safety
- Pre-run check: abort if an Adobe app is open; offer to close it (opt-in)
- Save the original IFEO key values before writing so restore is exact
- Log every blocked domain's resolved IPs before writing firewall rules so the user can audit
- Pre-flight hosts file backup to `%APPDATA%\Disable-AdobeTelemetry\hosts.bak.<ts>`
- Refuse to run if Little Snitch / NetLimiter / similar is controlling outbound — user should drive via that tool instead

### CLI / UX
- Structured logging (JSONL at `%APPDATA%\Disable-AdobeTelemetry\logs\`) alongside transcript
- Colored summary at the end: X processes killed, Y firewall rules added, Z domains blocked
- `-Verbose` gets per-step rationale; default stays dense
- `Install-Module Disable-AdobeTelemetry` publish path

### Packaging
- Authenticode-sign the `.ps1`; publish SHA256SUMS per release
- GitHub Action release workflow: tag → attached `.ps1` + `.zip` + checksums
- Companion winget manifest (`sysadmindoc.Disable-AdobeTelemetry`)

### Documentation
- Per-blocked-domain explanation in `docs/DOMAINS.md` (why each is sinkholed, what feature it breaks)
- Matrix of "what Adobe feature breaks under this tool" (Libraries sync, Fonts, font auto-activation, crash reporter)
- "Before you file a bug in Premiere" checklist that isolates whether an issue is caused by this script

## Competitive Research

- **Adobe GC Invoker Utility disablers (various GitHub)** — Usually just rename GCCore + disable a service; Disable-AdobeTelemetry already goes further with IFEO + ACL deny, so continue to be the comprehensive option.
- **AdGuard / Pi-hole blocklists** — Network-level blocking is complementary; the script should document how to combine (`If you already run Pi-hole, skip -OnlyHostsAndFirewall`).
- **Adobe Cleaner tool (official)** — Full uninstall/clean; reference as an orthogonal solution for users who want zero Adobe rather than quiet Adobe.
- **Creative Cloud Uninstaller (community)** — Rips out all Adobe; cite as "nuclear option" in the README so the scope remains clear.

## Nice-to-Haves

- WPF companion GUI (`Disable-AdobeTelemetry.GUI.ps1`) with Catppuccin Mocha theme and streaming log
- Live telemetry-connection counter using `Get-NetTCPConnection` filtered to Adobe processes so users can see outbound attempts before/after
- Integration with Windows Firewall `WFP` tracing for forensic "did it try to phone home" reports
- Optional re-run watchdog as a scheduled task (weekly) that reasserts IFEO/hosts/firewall entries after Adobe updates
- Detection of Suno / Figma / JetBrains telemetry as future sibling scripts (shared engine)
- "Plumbing test" mode that launches Premiere Pro under the protections and captures 10 minutes of `netstat` + `ProcMon`-lite output for review

## Open-Source Research (Round 2)

### Related OSS Projects
- **ignaciocastro/a-dove-is-dumb** — https://github.com/ignaciocastro/a-dove-is-dumb — Continuously updated hosts-file block list for Adobe telemetry domains; tracks domain rotations (e.g., `*.adobe.io` → `*.prod.cloud.adobe.io`).
- **benhkr/Adobe** — https://github.com/benhkr/Adobe — Mirror/sibling of a-dove-is-dumb, also updated continuously.
- **blues32767/Windows-Adobe-Hosts-Update-and-Service-Removal-Tool** — https://github.com/blues32767/Windows-Adobe-Hosts-Update-and-Service-Removal-Tool — PowerShell automation for hosts + firewall + scheduled-task + service disable; covers AGSService/AGMService start=4, AGCInvokerUtility termination.
- **brian6932/CC-Clean-Launcher** — https://github.com/brian6932/CC-Clean-Launcher — Clean-launcher wrapper: kills telemetry processes before the user's actual Adobe app launches, restores on exit.
- **athkiasaris1/Creative-Cloud-Process-Killer** — https://github.com/athkiasaris1/Creative-Cloud-Process-Killer — Batch-file targeted taskkill + schtasks disable for CC startup.
- **CaptainChicky/Remove-Adobe-Genuine-Client** — https://github.com/CaptainChicky/Remove-Adobe-Genuine-Client — Nukes `AdobeGenuineClient` folder contents + ACLs it so Adobe can't regenerate.
- **eugene8080/adobe-creative-cloud-remover** — https://github.com/eugene8080/adobe-creative-cloud-remover — Full CC removal; solves the classic "components are open" uninstall failure.
- **pjobson/adobe-cleanup gist** — https://gist.github.com/pjobson/3b9ee369734745125f0b567fb1399875 — macOS `launchctl` reference (AGSService / AAM-Updater / CCXProcess launch-agents).

### Features to Borrow
- Hosts block list consumed from a live upstream source rather than hardcoded in-script — borrow from `a-dove-is-dumb` (fetch `a.dove.isdumb.one/list.txt` with fallback).
- Launcher-wrapper pattern: user runs `CC-Clean-Premiere.cmd` which kills telemetry, launches Premiere, then re-kills on exit — borrow from `CC-Clean-Launcher`.
- Folder-permissions lockout (delete contents + `icacls /deny SYSTEM:(OI)(CI)F`) so Adobe cannot regenerate the dir — borrow from `Remove-Adobe-Genuine-Client`.
- Scheduled-task sweep-by-query (`schtasks /query /fo LIST` → filter by `Adobe-`/`AdobeGCInvoker`) rather than hardcoded names — borrow from `blues32767` tool.
- Firewall-by-program-path rules (block by exe path, not just by domain IP, because Adobe rotates domains) — borrow from `blues32767`.
- Registry DWORD fix for AdobeCollabSync regeneration (`HKCU\Software\Adobe\Adobe Acrobat\DC\Workflows`) — borrow from `winutil` discussion #3213.
- macOS parallel via `launchctl` for users on dual systems — borrow from `pjobson` gist (even if this repo is Windows-only, linking a companion is useful).
- Restore/undo pair for each op (re-enable service, re-add task, remove hosts entries) — borrow from `blues32767` tool structure.

### Patterns & Architectures Worth Studying
- `a-dove-is-dumb`'s update cadence + multi-format outputs (plain hosts / Windows-line-endings / uBlock / AdGuard) — model for shipping DisableAdobeTelemetry's block list as a consumable artifact.
- `CC-Clean-Launcher`'s "process-wrapper" design — avoids permanent uninstall damage while still getting a clean-process runtime; opt-in alternative to the existing destructive path.
- `blues32767` combined attack surface (hosts + firewall + services + tasks + registry) as a coverage template — use as checklist to spot gaps in the current script.
