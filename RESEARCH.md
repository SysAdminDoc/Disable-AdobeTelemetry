# Research - Disable-AdobeTelemetry

## Executive Summary

Disable-AdobeTelemetry v2.3.1 is a Windows PowerShell 5.1 privacy utility for suppressing Adobe Creative Cloud telemetry, marketing surfaces, background services, scheduled tasks, firewall paths, hosts entries, Acrobat policy keys, and startup entries. Its strongest shape is the layered, reversible design: phase-gated apply, manifest-driven undo, dry run, JSON status, JSONL action logs, watchdog reassertion, WFP/plumbing diagnostics, and 52 Pester tests. Highest-value direction: make fleet and post-update operation fail closed and verifiable. Top opportunities: validate imported profiles before apply, add post-apply tamper verification for hosts/WAM/firewall state, make upstream domain merge auditable and cacheable, add mocked route/firewall/watchdog tests, bring the GUI to parity with existing CLI modes, publish a versioned release artifact, and expand status JSON to cover every registry policy the script writes.

## Product Map

- Core workflows: apply all protections, dry-run preview, phase-selective apply/skip, status check, manifest-driven undo, clean launcher, watchdog install/remove, profile export/import, connection report, WFP capture, plumbing test.
- User personas: Windows power users with legitimate Adobe installs; sysadmins packaging privacy controls for fleets; developers validating Adobe background traffic before and after updates.
- Platforms and distribution: Windows 10/11, PowerShell 5.1, administrator elevation, single CLI script plus WPF GUI companion, MIT license, GitHub-hosted source and tags.
- Key integrations and data flows: Adobe install discovery through registry/filesystem; Windows services/tasks/firewall/hosts/registry; Defender Dynamic Keywords when available; upstream domain list from `https://a.dove.isdumb.one/list.txt`; logs under `%TEMP%` and `%APPDATA%\Disable-AdobeTelemetry\logs`.

## Competitive Landscape

### a-dove-is-dumb
- Does well: very broad and actively maintained Adobe domain blocking list with simple DNS/hosts consumption.
- Learn from: keep upstream blocking data fresh and make list provenance visible to operators.
- Avoid: DNS-only blocking; this repo's process, service, IFEO, registry, firewall, and undo layers are stronger.

### Ruddernation-Designs/Adobe-URL-Block-List
- Does well: cross-platform Adobe URL blocking scripts and readable blocklist output.
- Learn from: explicit update/change reporting for blocklist refreshes.
- Avoid: importing broad lists without safelist filtering because sign-in, downloads, fonts, and stock services can break.

### WinMasterBlocker and Windows privacy scripts
- Does well: vendor-oriented blocking presets and broader Windows privacy automation patterns.
- Learn from: separate data inventories from execution logic when the single-file script becomes harder to audit.
- Avoid: turning this project into a multi-vendor tool; Adobe-specific depth is the differentiator.

### Sophia Script, Win11Debloat, privacy.sexy, and O&O ShutUp10++
- Do well: presets, exportable configurations, rollback awareness, and distribution patterns familiar to Windows admins.
- Learn from: profile schema validation, clear preset naming, release packaging, and operator-readable diff summaries.
- Avoid: broad OS tweak surfaces that dilute Adobe-specific reliability.

### simplewall, Portmaster, GlassWire, and NextDNS
- Do well: network visibility, per-app connection history, blocklist provenance, and user-facing status.
- Learn from: make the existing `-ConnectionReport`, `-WfpTrace`, JSON status, and GUI controls easier to discover.
- Avoid: long-running resident firewall replacement; this repo should remain an auditable script.

### Adobe enterprise documentation
- Does well: official endpoint, background-process, and Acrobat policy references.
- Learn from: keep registry policy coverage traceable to documented Adobe enterprise keys and separate availability-critical endpoints from telemetry endpoints.
- Avoid: blocking authentication/download endpoints unless a profile explicitly accepts breakage.

## Security, Privacy, and Reliability

- Verified: `Import-RunProfile` reads JSON with `ConvertFrom-Json` and then proceeds without schema validation, required field checks, domain validation, or a fail-closed parse path (`Disable-AdobeTelemetry.ps1:2628`). Fleet imports should reject malformed or partial profiles before any apply flow can continue.
- Verified: Adobe Creative Cloud WAM hosts-file rewriting remains a live ecosystem risk. The v2.3.1 regex handles old and CC v26.4+ marker formats (`Disable-AdobeTelemetry.ps1:1190`, `Disable-AdobeTelemetry.ps1:1921`), but there is no final post-apply verification that WAM stayed removed, that the repo marker is the last effective mapping for `detect-ccd.creativecloud.adobe.com`, or that firewall/Dynamic Keyword rules actually exist after creation.
- Verified: upstream merge is live network input (`Disable-AdobeTelemetry.ps1:423`). It filters safelisted domains but does not persist the source timestamp, added/filtered domain list, last-good cache, or suspicious-entry rejects. That makes fleet review harder if an upstream list rotates unexpectedly.
- Verified: route, firewall, Dynamic Keyword, watchdog, and profile behaviors are mostly protected by static/regex Pester checks rather than mocked behavioral tests (`Tests/Disable-AdobeTelemetry.Tests.ps1:356`, `Tests/Disable-AdobeTelemetry.Tests.ps1:378`, `Tests/Disable-AdobeTelemetry.Tests.ps1:546`). Static checks caught recent regressions, but mocked command assertions would better protect destructive Windows operations.
- Verified: `Get-StatusData` reports a useful high-level JSON snapshot but checks only a subset of registry values written by `Set-AdobeRegistryPolicies` and `Disable-AcrobatTelemetry` (`Disable-AdobeTelemetry.ps1:2188`). Operators cannot fully prove policy convergence from `-StatusOnly -OutputFormat JSON`.
- Likely: GitHub release packaging is behind the v2.3.1 tag. The repo has a `v2.3.1` tag, but unauthenticated release API access failed during this pass and the project has no tracked package manifest. Treat release artifact availability as needing verification before implementation.

## Architecture Assessment

- Single-file CLI plus WPF companion remains appropriate: no runtime dependencies, easy audit, and PowerShell 5.1 compatibility match the target Windows fleet.
- `Disable-AdobeTelemetry.ps1` has clear phase boundaries and helper seams: `Test-PhaseEnabled`, `Add-ManifestAction`, `Invoke-ManifestUndo`, `Get-StatusData`, `Merge-UpstreamDomains`, and `Write-Status`.
- Refactor candidates: profile import/export should become a small validated schema boundary around `Export-RunProfile` and `Import-RunProfile`; upstream merge should return a structured result rather than only mutating `$script:TelemetryDomains`; status registry checks should be generated from the same policy inventory used by apply.
- GUI gap: `Disable-AdobeTelemetry.GUI.ps1` exposes apply, status, undo, connection report, dry run, and rationale, but not watchdog install/remove, profile export/import, WFP trace, plumbing test, output paths, or JSON status save. Those are already implemented in the CLI and should be surfaced without adding new backend behavior.
- Test gaps: mocked assertions for `New-NetFirewallRule`, `Remove-NetFirewallRule`, `route.exe`, `Register-ScheduledTask`, `Set-ScheduledTask`, `Unregister-ScheduledTask`, malformed profile imports, and post-apply verification.
- Documentation gap: README documents primary use, JSON status, and JSONL logs; release/install channels remain source-clone oriented rather than a versioned ZIP/install asset.

## Rejected Ideas

- Binary patching Adobe executables: high legal and maintenance risk; breaks on every Adobe update; source: GenP-style community tooling.
- Blocking all Adobe auth and download domains: breaks legitimate sign-in, licensing, downloads, fonts, and stock workflows; source: Adobe endpoint docs and competitor blocklists.
- Deleting Adobe services instead of disabling/restoring them: conflicts with manifest undo and repairability; source: current undo design.
- Making Dynamic Keywords the only network layer: requires Defender and Network Protection; current IP, hosts, program firewall, and Dynamic Keyword layering is safer; source: Microsoft firewall docs.
- Requiring PowerShell 7: contradicts Windows 10/11 default availability and current PowerShell 5.1 target; source: current `#Requires -Version 5.1`.
- Adding macOS/Linux support to this script: launchd, plist, PF, and hosts workflows are different enough to warrant separate tools; source: platform architecture.
- Turning this into a general Windows privacy/debloat suite: weakens the Adobe-specific depth that competitors lack; source: Sophia Script, Win11Debloat, privacy.sexy.

## Sources

Competitors:
- https://github.com/ignaciocastro/a-dove-is-dumb
- https://github.com/Ruddernation-Designs/Adobe-URL-Block-List
- https://github.com/ph33nx/WinMasterBlocker
- https://github.com/blues32767/Windows-Adobe-Hosts-Update-and-Service-Removal-Tool
- https://github.com/ChrisTitusTech/winutil
- https://github.com/farag2/Sophia-Script-for-Windows
- https://github.com/Raphire/Win11Debloat
- https://github.com/undergroundwires/privacy.sexy
- https://www.oo-software.com/en/shutup10

Adjacent tools:
- https://github.com/henrypp/simplewall
- https://safing.io/
- https://www.glasswire.com/features/

Adobe, Microsoft, and standards:
- https://helpx.adobe.com/enterprise/kb/network-endpoints.html
- https://helpx.adobe.com/x-productkb/global/adobe-background-processes.html
- https://www.adobe.com/devnet-docs/acrobatetk/tools/PrefRef/Windows/FeatureLockDown.html
- https://www.stigviewer.com/stigs/adobe_acrobat_reader_dc_continuous_track/
- https://learn.microsoft.com/en-us/powershell/module/netsecurity/new-netfirewalldynamickeywordaddress
- https://learn.microsoft.com/en-us/powershell/module/netsecurity/new-netfirewallrule
- https://learn.microsoft.com/en-us/defender-endpoint/network-protection
- https://developer.chrome.com/blog/local-network-access
- https://wicg.github.io/private-network-access/

Community and tooling:
- https://piunikaweb.com/2026/04/01/adobe-creative-cloud-rewrites-hosts-file/
- https://www.osnews.com/story/144737/adobe-secretly-modifies-your-hosts-file-for-the-stupidest-reason/
- https://mjtsai.com/blog/2026/04/08/adobe-modifies-your-hosts-file-for-their-analytics/
- https://lilting.ch/en/articles/adobe-cc-wam-hosts-rewrite
- https://pester.dev/docs/usage/mocking
- https://learn.microsoft.com/en-us/powershell/gallery/concepts/publishing-guidelines
- https://github.com/ScoopInstaller/Scoop/wiki/App-Manifests
- https://docs.chocolatey.org/en-us/create/create-packages/
- https://learn.microsoft.com/en-us/windows/package-manager/winget/

## Open Questions

- None blocking. Release artifact state should be rechecked with authenticated GitHub access before doing release work.
