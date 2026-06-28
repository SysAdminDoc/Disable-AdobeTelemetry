# Disable-AdobeTelemetry Roadmap

PowerShell script that kills Adobe CC telemetry, neutralizes GrowthSDK, firewalls IPCBroker, and sinkholes ~40 telemetry domains. Tracks work beyond v2.3.0.

No actionable items remaining. See Roadmap_Blocked.md for items awaiting credentials, external resources, or operator decisions.

## Research-Driven Additions

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
