# Disable-AdobeTelemetry Roadmap

PowerShell script that kills Adobe CC telemetry, neutralizes GrowthSDK, firewalls IPCBroker, and sinkholes ~40 telemetry domains. Tracks work beyond v2.3.0.

No actionable items remaining. See Roadmap_Blocked.md for items awaiting credentials, external resources, or operator decisions.

## Research-Driven Additions

- [ ] P0 - Fail closed on invalid imported profiles
  Why: A malformed or partial profile can reach the apply flow after a misleading load message, which is unsafe for fleet automation.
  Evidence: `Disable-AdobeTelemetry.ps1:2628`; O&O ShutUp10++ and Windows privacy tools rely on importable settings as a trust boundary.
  Touches: `Disable-AdobeTelemetry.ps1`, `Tests/Disable-AdobeTelemetry.Tests.ps1`, `README.md`
  Acceptance: `-ImportProfile` rejects malformed JSON, missing schema/version fields, invalid profile tiers, invalid phase names, and invalid domains with a non-zero exit before any phase runs; Pester covers valid and invalid imports.
  Complexity: S

- [ ] P0 - Add post-apply tamper verification
  Why: Adobe CC WAM hosts rewriting is an active countermeasure, and successful writes should be verified after apply rather than assumed.
  Evidence: `Disable-AdobeTelemetry.ps1:1158`, `Disable-AdobeTelemetry.ps1:2098`; PiunikaWeb/Michael Tsai/OSNews/Lilting WAM reports.
  Touches: `Disable-AdobeTelemetry.ps1`, `Tests/Disable-AdobeTelemetry.Tests.ps1`, `README.md`
  Acceptance: apply runs a verification pass that checks hosts marker presence, WAM marker absence, effective `detect-ccd.creativecloud.adobe.com` mapping, firewall rule count, Dynamic Keyword presence when available, and remaining Adobe-owned outbound connections; failures increment error count and appear in text, JSONL, and `-StatusOnly -OutputFormat JSON`.
  Complexity: M

- [ ] P1 - Make upstream domain merges auditable and cacheable
  Why: Live upstream blocklist input is useful but needs provenance, diff visibility, and last-good fallback for repeatable fleet runs.
  Evidence: `Disable-AdobeTelemetry.ps1:421`; a-dove-is-dumb and Ruddernation blocklist update patterns.
  Touches: `Disable-AdobeTelemetry.ps1`, `Tests/Disable-AdobeTelemetry.Tests.ps1`, `README.md`
  Acceptance: merge records upstream URL, fetch timestamp, added domains, safelisted domains, rejected malformed entries, and final count to JSONL; invalid fetches use a last-good cache when present; dry run shows the same diff without mutating domain state.
  Complexity: M

- [ ] P1 - Add mocked behavioral tests for firewall, routes, watchdog, and undo
  Why: Current tests lean on static source assertions for Windows-mutating operations; mocked command assertions catch argument regressions without touching the host.
  Evidence: `Tests/Disable-AdobeTelemetry.Tests.ps1:356`, `Tests/Disable-AdobeTelemetry.Tests.ps1:378`; Pester mocking docs.
  Touches: `Tests/Disable-AdobeTelemetry.Tests.ps1`, `Disable-AdobeTelemetry.ps1`
  Acceptance: Pester mocks validate `New-NetFirewallRule`, `Remove-NetFirewallRule`, Dynamic Keyword creation/removal, `route.exe` add/delete, watchdog register/update/remove, and manifest undo order.
  Complexity: M

- [ ] P1 - Expand JSON status to full policy convergence
  Why: Fleet operators need `-StatusOnly -OutputFormat JSON` to prove every registry policy written by apply is present and correct.
  Evidence: `Disable-AdobeTelemetry.ps1:836`, `Disable-AdobeTelemetry.ps1:1534`, `Disable-AdobeTelemetry.ps1:2188`; Adobe Acrobat ETK and DISA STIG references.
  Touches: `Disable-AdobeTelemetry.ps1`, `Tests/Disable-AdobeTelemetry.Tests.ps1`, `README.md`
  Acceptance: status registry checks are generated from the same policy inventory used by apply, include Acrobat/Reader/Wow6432Node/Substance/current-user keys, and expose per-key path/name/expected/actual/state in JSON.
  Complexity: M

- [ ] P2 - Bring the WPF GUI to CLI parity
  Why: The CLI already supports watchdog, profile import/export, WFP trace, plumbing tests, and JSON status, but the GUI exposes only apply/status/undo/connection report.
  Evidence: `Disable-AdobeTelemetry.GUI.ps1:120`, `Disable-AdobeTelemetry.ps1:2666`; GlassWire/simplewall/Portmaster UX patterns.
  Touches: `Disable-AdobeTelemetry.GUI.ps1`, `Tests/Disable-AdobeTelemetry.Tests.ps1`, `README.md`
  Acceptance: GUI exposes watchdog install/remove, profile import/export file pickers, WFP trace output path, plumbing test app/minutes, JSON status save, and clear completion/error state while keeping async execution and log streaming.
  Complexity: L

- [ ] P2 - Publish a versioned release ZIP and install channel plan
  Why: Source-only usage is workable for developers but weak for Windows operators who need pinned, checksummed artifacts.
  Evidence: `README.md`; PowerShell Gallery, Scoop, Chocolatey, and winget packaging docs.
  Touches: `README.md`, release artifact contents, optional package manifests outside the runtime script
  Acceptance: each version ships a ZIP containing CLI, GUI, README, LICENSE, checksum file, and version tag; README documents direct ZIP install and checksum verification; release state is verified from GitHub after push.
  Complexity: M

- [ ] P3 - Split static inventories from execution logic when the next feature touches domains/processes/policies
  Why: Domain, process, service, executable, and policy inventories now occupy large inline arrays, making review harder as Adobe rotates endpoints.
  Evidence: `Disable-AdobeTelemetry.ps1:250`, `Disable-AdobeTelemetry.ps1:333`, `Disable-AdobeTelemetry.ps1:836`; WinMasterBlocker/vendor-preset patterns.
  Touches: `Disable-AdobeTelemetry.ps1`, `Tests/Disable-AdobeTelemetry.Tests.ps1`, `README.md`
  Acceptance: inventories remain dependency-free and signed into the repo, tests prove generated runtime arrays match current behavior, and single-file distribution is preserved through a build/pack step if files are split.
  Complexity: L
