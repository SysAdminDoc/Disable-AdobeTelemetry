# CLAUDE.md - Disable-AdobeTelemetry

## Overview
Comprehensive Adobe telemetry and GrowthSDK suppression for Windows. Nine operations covering processes, filesystem, registry, firewall, hosts file, and startup entries. v1.0.

## Tech Stack
- PowerShell 5.1, CLI/console (no GUI)

## Key Details
- ~620 lines, single-file
- 9 operations: kill Adobe processes, remove/block GrowthSDK directory (ACL-locked decoy), neutralize CCXProcess.exe (rename + IFEO redirect), firewall AdobeIPCBroker (outbound only), disable services/tasks, enterprise registry policies, block 21 telemetry domains via Firewall + hosts file, disable startup Run entries
- Prompts for confirmation before proceeding
- Offers reboot at completion

## Build/Run
```powershell
# Run as Administrator
.\Disable-AdobeTelemetry.ps1
```

## Version
1.0
