# CLAUDE.md - Disable-AdobeTelemetry

## Overview
Comprehensive Adobe telemetry and GrowthSDK suppression for Windows. 11 operations covering processes, filesystem, registry, firewall, hosts file, Acrobat telemetry, and startup entries. v1.1.0.

## Tech Stack
- PowerShell 5.1, CLI/console (no GUI)

## Key Details
- Single-file script, auto-elevates to admin
- 11 operations: kill Adobe processes, remove/block GrowthSDK directory (ACL-locked decoy), neutralize CCXProcess.exe (rename + IFEO redirect), firewall AdobeIPCBroker (outbound only), disable services/tasks, enterprise registry policies, block 27 telemetry domains via Firewall + hosts file, Acrobat DC telemetry registry lockdown, disable startup Run entries
- `-Undo` switch: reverses ALL changes (services, tasks, firewall rules, hosts block, IFEO, renamed exes, GrowthSDK blockers, registry policies, startup entries)
- `-StatusOnly` switch: displays current state of all telemetry components without making changes
- All output logged to `$env:TEMP\Disable-AdobeTelemetry.log` with timestamps
- No confirmation prompts - executes immediately
- Informs user a reboot is recommended (no reboot prompt)

## Build/Run
```powershell
# Apply all blocks (auto-elevates)
.\Disable-AdobeTelemetry.ps1

# Check current status
.\Disable-AdobeTelemetry.ps1 -StatusOnly

# Reverse all changes
.\Disable-AdobeTelemetry.ps1 -Undo
```

## Version History
- 1.1.0 - Undo support, status check, Acrobat telemetry, file logging, 6 new domains, auto-elevate, removed confirmation/reboot prompts
- 1.0 - Initial release

## Version
1.1.0
