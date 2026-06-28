BeforeAll {
    $scriptPath = Join-Path $PSScriptRoot '..\Disable-AdobeTelemetry.ps1'
    $scriptContent = Get-Content $scriptPath -Raw

    # Extract the domain list from the script
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$null, [ref]$null)
    $script:ScriptAst = $ast

    # Dot-source just the config/function definitions by parsing the script
    # We cannot dot-source the whole script (it auto-elevates and runs), so we
    # extract testable pieces via AST or regex.

    # Extract all domain strings from all tier arrays (Minimal + Standard + Aggressive)
    $script:TelemetryDomains = @()
    $allMatches = [regex]::Matches($scriptContent, "TelemetryDomains\w*\s*=\s*(?:[^@]*)?@\(([^)]+)\)")
    foreach ($m in $allMatches) {
        $domainBlock = $m.Groups[1].Value
        $domains = $domainBlock -split "`n" |
            ForEach-Object { $_.Trim().Trim("'").Trim('"') } |
            Where-Object { $_ -and $_ -notmatch '^\s*#' -and $_ -ne '' -and $_ -notmatch '^\$' }
        $script:TelemetryDomains += $domains
    }
    $script:TelemetryDomains = $script:TelemetryDomains | Sort-Object -Unique

    # Extract $AdobeProcesses array
    if ($scriptContent -match '\$AdobeProcesses\s*=\s*@\(([\s\S]*?)\)') {
        $procBlock = $Matches[1]
        $script:AdobeProcesses = $procBlock -split "`n" |
            ForEach-Object { ($_ -split '#')[0].Trim().Trim("'").Trim('"') } |
            Where-Object { $_ -and $_ -ne '' }
    }

    # Extract $Services array
    if ($scriptContent -match '\$Services\s*=\s*@\(([\s\S]*?)\)') {
        $svcBlock = $Matches[1]
        $script:Services = $svcBlock -split "`n" |
            ForEach-Object { ($_ -split '#')[0].Trim().Trim("'").Trim('"') } |
            Where-Object { $_ -and $_ -ne '' }
    }

    # Extract valid phase names
    if ($scriptContent -match '\$script:ValidPhases\s*=\s*@\(([\s\S]*?)\)') {
        $phaseBlock = $Matches[1]
        $script:ValidPhases = $phaseBlock -split "[`n,]" |
            ForEach-Object { $_.Trim().Trim("'").Trim('"') } |
            Where-Object { $_ -and $_ -ne '' }
    }
}

Describe 'Script Syntax' {
    It 'parses without errors' {
        $errors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile(
            (Join-Path $PSScriptRoot '..\Disable-AdobeTelemetry.ps1'),
            [ref]$null, [ref]$errors
        )
        $errors.Count | Should -Be 0
    }
}

Describe 'Domain List Validation' {
    It 'contains at least 30 domains' {
        $script:TelemetryDomains.Count | Should -BeGreaterOrEqual 30
    }

    It 'has no duplicate domains' {
        $unique = $script:TelemetryDomains | Sort-Object -Unique
        $unique.Count | Should -Be $script:TelemetryDomains.Count
    }

    It 'has no empty entries' {
        $script:TelemetryDomains | ForEach-Object {
            $_ | Should -Not -BeNullOrEmpty
        }
    }

    It 'does not contain Microsoft domains' {
        $script:TelemetryDomains | ForEach-Object {
            $_ | Should -Not -BeLike '*.microsoft.com'
            $_ | Should -Not -BeLike '*.office.com'
            $_ | Should -Not -BeLike '*.windows.com'
        }
    }

    It 'does not contain use.typekit.net in Minimal or Standard tiers' {
        $scriptContent = Get-Content (Join-Path $PSScriptRoot '..\Disable-AdobeTelemetry.ps1') -Raw
        $standardDomains = @()
        foreach ($tier in @('TelemetryDomainsMinimal', 'TelemetryDomainsStandard')) {
            $matches = [regex]::Match($scriptContent, "$tier\s*=\s*(?:[^@]*)?@\(([^)]+)\)")
            if ($matches.Success) {
                $standardDomains += $matches.Groups[1].Value -split "`n" |
                    ForEach-Object { $_.Trim().Trim("'").Trim('"') } |
                    Where-Object { $_ -and $_ -notmatch '^\s*#' }
            }
        }
        $standardDomains | Should -Not -Contain 'use.typekit.net'
    }

    It 'all domains have valid format' {
        $script:TelemetryDomains | ForEach-Object {
            $_ | Should -Match '^[a-zA-Z0-9]([a-zA-Z0-9\-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9\-]*[a-zA-Z0-9])?)+$'
        }
    }

    It 'contains key telemetry domains' {
        $script:TelemetryDomains | Should -Contain 'cc-api-data.adobe.io'
        $script:TelemetryDomains | Should -Contain 'ic.adobe.io'
        $script:TelemetryDomains | Should -Contain 'fp.adobestats.io'
        $script:TelemetryDomains | Should -Contain 'genuine.adobe.com'
    }

    It 'contains WAM detection domain' {
        $script:TelemetryDomains | Should -Contain 'detect-ccd.creativecloud.adobe.com'
    }

    It 'contains crash reporting domains' {
        $script:TelemetryDomains | Should -Contain 'crs.cr.adobe.com'
        $script:TelemetryDomains | Should -Contain 'crlog-crcn.adobe.com'
    }

    It 'contains messaging domains' {
        $script:TelemetryDomains | Should -Contain 'client.messaging.adobe.com'
        $script:TelemetryDomains | Should -Contain 'server.messaging.adobe.com'
    }
}

Describe 'Process List Validation' {
    It 'contains at least 15 processes' {
        $script:AdobeProcesses.Count | Should -BeGreaterOrEqual 15
    }

    It 'includes core telemetry processes' {
        $script:AdobeProcesses | Should -Contain 'CCXProcess'
        $script:AdobeProcesses | Should -Contain 'AGSService'
        $script:AdobeProcesses | Should -Contain 'AdobeIPCBroker'
    }

    It 'includes crash reporter processes' {
        $script:AdobeProcesses | Should -Contain 'CRWindowsClientService'
        $script:AdobeProcesses | Should -Contain 'CRLogTransport'
    }

    It 'includes sync and transport processes' {
        $script:AdobeProcesses | Should -Contain 'CoreSync'
        $script:AdobeProcesses | Should -Contain 'LogTransport2'
        $script:AdobeProcesses | Should -Contain 'AdobeCollabSync'
    }

    It 'includes Substance suite processes' {
        $script:AdobeProcesses | Should -Contain 'Adobe Substance 3D Painter'
        $script:AdobeProcesses | Should -Contain 'Adobe Substance 3D Designer'
        $script:AdobeProcesses | Should -Contain 'Adobe Substance 3D Sampler'
        $script:AdobeProcesses | Should -Contain 'Adobe Substance 3D Stager'
        $script:AdobeProcesses | Should -Contain 'Adobe Substance 3D Modeler'
    }

    It 'includes Dimension process' {
        $script:AdobeProcesses | Should -Contain 'Adobe Dimension'
    }
}

Describe 'Services List Validation' {
    It 'contains at least 5 services' {
        $script:Services.Count | Should -BeGreaterOrEqual 5
    }

    It 'includes critical services' {
        $script:Services | Should -Contain 'AGSService'
        $script:Services | Should -Contain 'AGMService'
        $script:Services | Should -Contain 'AdobeARMservice'
    }
}

Describe 'Phase System Validation' {
    It 'defines exactly 11 valid phases' {
        $script:ValidPhases.Count | Should -Be 11
    }

    It 'includes all expected phases' {
        $expected = @('Kill', 'GrowthSDK', 'CCXProcess', 'IPCBroker', 'Tasks', 'Services', 'Registry', 'Firewall', 'Hosts', 'Acrobat', 'Startup')
        foreach ($phase in $expected) {
            $script:ValidPhases | Should -Contain $phase
        }
    }
}

Describe 'Script Configuration' {
    It 'does not use global SilentlyContinue' {
        $scriptContent = Get-Content (Join-Path $PSScriptRoot '..\Disable-AdobeTelemetry.ps1') -Raw
        $scriptContent | Should -Not -Match "\`\$ErrorActionPreference\s*=\s*'SilentlyContinue'"
    }

    It 'IFEO target is not nul' {
        $scriptContent = Get-Content (Join-Path $PSScriptRoot '..\Disable-AdobeTelemetry.ps1') -Raw
        $scriptContent | Should -Not -Match "-Value\s+'nul'\s+-Type\s+String"
    }

    It 'sets IFEO redirects for CC helper processes' {
        $scriptContent = Get-Content (Join-Path $PSScriptRoot '..\Disable-AdobeTelemetry.ps1') -Raw
        $scriptContent | Should -Match 'Creative Cloud Helper\.exe'
        $scriptContent | Should -Match 'AdobeNotificationClient\.exe'
    }

    It 'includes Substance telemetry registry policies' {
        $scriptContent = Get-Content (Join-Path $PSScriptRoot '..\Disable-AdobeTelemetry.ps1') -Raw
        $scriptContent | Should -Match 'Substance 3D'
        $scriptContent | Should -Match 'DisableAnalytics'
        $scriptContent | Should -Match 'enable_analytics'
    }

    It 'manifest-driven undo is wired up as primary path' {
        $scriptContent = Get-Content (Join-Path $PSScriptRoot '..\Disable-AdobeTelemetry.ps1') -Raw
        $scriptContent | Should -Match 'Invoke-ManifestUndo'
    }

    It 'version strings are consistent' {
        $scriptContent = Get-Content (Join-Path $PSScriptRoot '..\Disable-AdobeTelemetry.ps1') -Raw
        $versions = [regex]::Matches($scriptContent, 'v(\d+\.\d+\.\d+)') | ForEach-Object { $_.Groups[1].Value }
        $versions | Sort-Object -Unique | Should -HaveCount 1
    }
}

Describe 'IPv6 and Safelist' {
    It 'resolves both InterNetwork and InterNetworkV6 in firewall function' {
        $scriptContent = Get-Content (Join-Path $PSScriptRoot '..\Disable-AdobeTelemetry.ps1') -Raw
        $scriptContent | Should -Match 'InterNetworkV6'
    }

    It 'adds IPv6 sinkhole entries in hosts file block' {
        $scriptContent = Get-Content (Join-Path $PSScriptRoot '..\Disable-AdobeTelemetry.ps1') -Raw
        $scriptContent | Should -Match '::.*\$domain'
    }

    It 'defines a domain safelist for upstream merge' {
        $scriptContent = Get-Content (Join-Path $PSScriptRoot '..\Disable-AdobeTelemetry.ps1') -Raw
        $scriptContent | Should -Match 'DomainSafelist'
        $scriptContent | Should -Match 'ims-na1\.adobelogin\.com'
        $scriptContent | Should -Match 'auth\.services\.adobe\.com'
    }

    It 'safelist contains authentication and download domains' {
        $scriptContent = Get-Content (Join-Path $PSScriptRoot '..\Disable-AdobeTelemetry.ps1') -Raw
        $safelistMatch = [regex]::Match($scriptContent, '\$script:DomainSafelist\s*=\s*@\(([^)]+)\)')
        $safelistMatch.Success | Should -BeTrue
        $safelistDomains = $safelistMatch.Groups[1].Value -split "`n" |
            ForEach-Object { $_.Trim().Trim("'").Trim('"') } |
            Where-Object { $_ -and $_ -ne '' }
        $safelistDomains | Should -Contain 'ims-na1.adobelogin.com'
        $safelistDomains | Should -Contain 'auth.services.adobe.com'
        $safelistDomains.Count | Should -BeGreaterOrEqual 5
    }
}

Describe 'Hosts File Markers' {
    It 'uses matching start and end markers' {
        $scriptContent = Get-Content (Join-Path $PSScriptRoot '..\Disable-AdobeTelemetry.ps1') -Raw
        $scriptContent | Should -Match '# --- Adobe Telemetry Block \(Disable-AdobeTelemetry\.ps1\) ---'
        $scriptContent | Should -Match '# --- End Adobe Telemetry Block ---'
    }

    It 'detects WAM markers in both old and new CC v26.4+ formats' {
        $scriptContent = Get-Content (Join-Path $PSScriptRoot '..\Disable-AdobeTelemetry.ps1') -Raw
        # The WAM detection regex must handle both single-# and double-## marker formats
        $scriptContent | Should -Match 'Adobe Creative Cloud WAM'
        # Verify the regex uses #{1,2} to match both old and new formats
        $scriptContent | Should -Match '#\{1,2\}'
    }

    It 'reads the first effective hosts mapping for detect-ccd' {
        $funcDefs = $script:ScriptAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
        $hostsMappingFunc = $funcDefs | Where-Object { $_.Name -eq 'Get-HostsDomainMappings' }
        $hostsMappingFunc | Should -Not -BeNullOrEmpty

        Invoke-Expression $hostsMappingFunc.Extent.Text
        $hostsContent = @'
166.117.29.222 detect-ccd.creativecloud.adobe.com
# --- Adobe Telemetry Block (Disable-AdobeTelemetry.ps1) ---
0.0.0.0 detect-ccd.creativecloud.adobe.com
:: detect-ccd.creativecloud.adobe.com
# --- End Adobe Telemetry Block ---
'@

        $mappings = @(Get-HostsDomainMappings -HostsContent $hostsContent)
        $mappings.Count | Should -Be 3
        $mappings[0].Address | Should -Be '166.117.29.222'
        $mappings[1].Address | Should -Be '0.0.0.0'
    }
}

Describe 'Exit Codes and OutputFormat' {
    It 'defines structured exit codes (0, 2, 3, 3010)' {
        $scriptContent = Get-Content (Join-Path $PSScriptRoot '..\Disable-AdobeTelemetry.ps1') -Raw
        $scriptContent | Should -Match 'exit 0'
        $scriptContent | Should -Match 'exit 2'
        $scriptContent | Should -Match 'exit 3\b'
        $scriptContent | Should -Match 'exit 3010'
    }

    It 'supports OutputFormat parameter' {
        $scriptContent = Get-Content (Join-Path $PSScriptRoot '..\Disable-AdobeTelemetry.ps1') -Raw
        $scriptContent | Should -Match "ValidateSet\('Text','JSON'\)"
        $scriptContent | Should -Match 'OutputFormat'
    }

    It 'tracks error count in Counters' {
        $scriptContent = Get-Content (Join-Path $PSScriptRoot '..\Disable-AdobeTelemetry.ps1') -Raw
        $scriptContent | Should -Match 'Errors\s*=\s*0'
        $scriptContent | Should -Match 'Counters\.Errors'
    }
}

Describe 'Manifest Round-Trip' {
    It 'Add-ManifestAction and Save-Manifest produce valid JSON' {
        $scriptContent = Get-Content (Join-Path $PSScriptRoot '..\Disable-AdobeTelemetry.ps1') -Raw
        $funcDefs = $script:ScriptAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
        $addManifest = $funcDefs | Where-Object { $_.Name -eq 'Add-ManifestAction' }
        $saveManifest = $funcDefs | Where-Object { $_.Name -eq 'Save-Manifest' }
        $getManifestDetail = $funcDefs | Where-Object { $_.Name -eq 'Get-ManifestDetail' }
        $initDir = $funcDefs | Where-Object { $_.Name -eq 'Initialize-AppDataDirectory' }
        $writeStatus = $funcDefs | Where-Object { $_.Name -eq 'Write-Status' }

        $addManifest | Should -Not -BeNullOrEmpty
        $saveManifest | Should -Not -BeNullOrEmpty
        $getManifestDetail | Should -Not -BeNullOrEmpty

        $tempDir = Join-Path $env:TEMP "PesterManifestTest_$(Get-Random)"
        New-Item -Path $tempDir -ItemType Directory -Force | Out-Null
        try {
            $script:ManifestDir = $tempDir
            $script:ManifestPath = Join-Path $tempDir 'undo-manifest.json'
            $script:ManifestActions = @()
            $script:LogDir = Join-Path $tempDir 'logs'
            $script:LogFile = Join-Path $tempDir 'test.log'
            $script:JsonLogFile = Join-Path $tempDir 'test.jsonl'
            $script:Version = '0.0.0-test'
            $script:Counters = @{ Errors = 0 }
            $DryRun = $false
            $Profile = 'Standard'
            $Only = $null
            $Skip = $null
            $Undo = $false
            $StatusOnly = $false
            $ShowRationale = $false
            $OutputFormat = 'Text'

            Invoke-Expression $initDir.Extent.Text
            function Write-Status { param([string]$Message, [string]$Type = 'Info') }
            Invoke-Expression $addManifest.Extent.Text
            Invoke-Expression $saveManifest.Extent.Text
            Invoke-Expression $getManifestDetail.Extent.Text

            Add-ManifestAction -Phase 'TestPhase' -Action 'SetRegistryValue' -Details @{
                Path = 'HKLM:\TEST'; Name = 'TestVal'; Value = 1; Type = 'DWord'
                PreviousExists = $true; PreviousValue = 0; PreviousType = 'DWord'
            }
            Add-ManifestAction -Phase 'TestPhase' -Action 'AddFirewallRule' -Details @{
                DisplayName = 'Test Rule'
            }

            $script:ManifestActions.Count | Should -Be 2

            Save-Manifest

            Test-Path $script:ManifestPath | Should -BeTrue
            $json = Get-Content $script:ManifestPath -Raw | ConvertFrom-Json
            $json.SchemaVersion | Should -Be 2
            $json.Actions.Count | Should -Be 2
            (Get-ManifestDetail $json.Actions[0].Details 'Path') | Should -Be 'HKLM:\TEST'
            (Get-ManifestDetail $json.Actions[1].Details 'DisplayName') | Should -Be 'Test Rule'
        } finally {
            Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Dynamic Keywords FQDN' {
    It 'includes FQDN wildcard patterns for Adobe domains' {
        $scriptContent = Get-Content (Join-Path $PSScriptRoot '..\Disable-AdobeTelemetry.ps1') -Raw
        $scriptContent | Should -Match '\*\.adobe\.io'
        $scriptContent | Should -Match '\*\.adobestats\.io'
        $scriptContent | Should -Match '\*\.demdex\.net'
    }

    It 'checks Defender and Network Protection prerequisites' {
        $scriptContent = Get-Content (Join-Path $PSScriptRoot '..\Disable-AdobeTelemetry.ps1') -Raw
        $scriptContent | Should -Match 'Get-MpComputerStatus'
        $scriptContent | Should -Match 'Get-MpPreference'
        $scriptContent | Should -Match 'EnableNetworkProtection'
    }

    It 'handles AddDynamicKeyword action type in manifest undo' {
        $scriptContent = Get-Content (Join-Path $PSScriptRoot '..\Disable-AdobeTelemetry.ps1') -Raw
        $scriptContent | Should -Match "'AddDynamicKeyword'"
        $scriptContent | Should -Match 'Remove-NetFirewallDynamicKeywordAddress'
    }
}

Describe 'Watchdog Scheduled Task' {
    It 'uses an encoded command for scheduled task arguments' {
        $scriptContent = Get-Content (Join-Path $PSScriptRoot '..\Disable-AdobeTelemetry.ps1') -Raw
        $funcDefs = $script:ScriptAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
        $installWatchdog = $funcDefs | Where-Object { $_.Name -eq 'Install-Watchdog' } | Select-Object -First 1
        $funcBody = $scriptContent.Substring($installWatchdog.Extent.StartOffset, $installWatchdog.Extent.EndOffset - $installWatchdog.Extent.StartOffset)

        $funcBody | Should -Match '-EncodedCommand'
        $funcBody | Should -Match 'ToBase64String'
        $funcBody | Should -Not -Match '-Command `"\$preCheck'
    }
}

Describe 'DISA STIG Hardening' {
    It 'includes STIG registry keys for Aggressive profile' {
        $scriptContent = Get-Content (Join-Path $PSScriptRoot '..\Disable-AdobeTelemetry.ps1') -Raw
        $scriptContent | Should -Match 'bProtectedMode'
        $scriptContent | Should -Match 'iProtectedView'
        $scriptContent | Should -Match 'bEnhancedSecurityStandalone'
        $scriptContent | Should -Match 'bEnhancedSecurityInBrowser'
        $scriptContent | Should -Match 'bDisableTrustedFolders'
        $scriptContent | Should -Match 'bEnableProtectedModeAppContainer'
        $scriptContent | Should -Match 'iURLPerms'
        $scriptContent | Should -Match 'iUnknownURLPerms'
    }

    It 'only applies STIG keys when Profile is Aggressive' {
        $scriptContent = Get-Content (Join-Path $PSScriptRoot '..\Disable-AdobeTelemetry.ps1') -Raw
        $scriptContent | Should -Match "Profile -eq 'Aggressive'[\s\S]*?bProtectedMode"
    }
}

Describe 'Upstream Domain Merge Filtering' {
    It 'Merge-UpstreamDomains function filters safelist domains' {
        $scriptContent = Get-Content (Join-Path $PSScriptRoot '..\Disable-AdobeTelemetry.ps1') -Raw
        $scriptContent | Should -Match 'DomainSafelist\s+-contains\s+\$candidate'
    }

    It 'safelist includes critical authentication domains' {
        $scriptContent = Get-Content (Join-Path $PSScriptRoot '..\Disable-AdobeTelemetry.ps1') -Raw
        $safelistMatch = [regex]::Match($scriptContent, '\$script:DomainSafelist\s*=\s*@\(([^)]+)\)')
        $safelistDomains = $safelistMatch.Groups[1].Value -split "`n" |
            ForEach-Object { $_.Trim().Trim("'").Trim('"') } |
            Where-Object { $_ -and $_ -ne '' }
        $safelistDomains | Should -Contain 'ims-na1.adobelogin.com'
        $safelistDomains | Should -Contain 'auth.services.adobe.com'
        $safelistDomains | Should -Contain 'ccmdls.adobe.com'
        $safelistDomains | Should -Contain 'ardownload2.adobe.com'
    }

    It 'builds auditable upstream merge diffs with safelist and malformed rejects' {
        $funcDefs = $script:ScriptAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
        $mergeResultFunc = $funcDefs | Where-Object { $_.Name -eq 'Get-UpstreamDomainMergeResult' }
        $mergeResultFunc | Should -Not -BeNullOrEmpty

        Invoke-Expression $mergeResultFunc.Extent.Text
        $script:UpstreamUrl = 'https://example.invalid/list.txt'
        $script:DomainSafelist = @('auth.services.adobe.com')
        $raw = @'
0.0.0.0 new-telemetry.adobe.io
auth.services.adobe.com
not a domain
existing.adobe.io
'@

        $result = Get-UpstreamDomainMergeResult -RawContent $raw -ExistingDomains @('existing.adobe.io') -Source 'Network'
        $result.AddedDomains | Should -Contain 'new-telemetry.adobe.io'
        $result.AddedDomains | Should -Not -Contain 'existing.adobe.io'
        $result.SafelistedDomains | Should -Contain 'auth.services.adobe.com'
        $result.RejectedMalformedEntries | Should -Contain 'not a domain'
        $result.FinalCount | Should -Be 2
    }

    It 'records upstream merge audit and cache plumbing' {
        $scriptContent = Get-Content (Join-Path $PSScriptRoot '..\Disable-AdobeTelemetry.ps1') -Raw
        $scriptContent | Should -Match 'UpstreamCachePath'
        $scriptContent | Should -Match 'Write-JsonLogEvent -Event ''UpstreamDomainMerge'''
        $scriptContent | Should -Match 'Get-UpstreamDomainCacheResult'
        $scriptContent | Should -Match 'Would merge'
        $scriptContent | Should -Match 'Save-UpstreamDomainCache'
    }
}

Describe 'GUI Script' {
    It 'parses without errors' {
        $guiPath = Join-Path $PSScriptRoot '..\Disable-AdobeTelemetry.GUI.ps1'
        if (-not (Test-Path $guiPath)) { Set-ItResult -Skipped -Because 'GUI script not present'; return }
        $errors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile($guiPath, [ref]$null, [ref]$errors)
        $errors.Count | Should -Be 0
    }

    It 'version strings match main script version' {
        $mainContent = Get-Content (Join-Path $PSScriptRoot '..\Disable-AdobeTelemetry.ps1') -Raw
        $guiPath = Join-Path $PSScriptRoot '..\Disable-AdobeTelemetry.GUI.ps1'
        if (-not (Test-Path $guiPath)) { Set-ItResult -Skipped -Because 'GUI script not present'; return }
        $guiContent = Get-Content $guiPath -Raw

        $mainVersion = ([regex]::Match($mainContent, "DisplayVersion\s*=\s*'v(\d+\.\d+\.\d+)'")).Groups[1].Value
        $mainVersion | Should -Not -BeNullOrEmpty

        $guiNotesVersion = ([regex]::Match($guiContent, 'Version\s*:\s*(\d+\.\d+\.\d+)')).Groups[1].Value
        $guiNotesVersion | Should -Be $mainVersion

        $guiTitleVersion = ([regex]::Match($guiContent, 'Title="[^"]*v(\d+\.\d+\.\d+)"')).Groups[1].Value
        $guiTitleVersion | Should -Be $mainVersion

        $guiStatusVersion = ([regex]::Match($guiContent, 'Text="v(\d+\.\d+\.\d+)"')).Groups[1].Value
        $guiStatusVersion | Should -Be $mainVersion
    }
}

Describe 'Negative / Edge-Case Tests' {
    It 'Invoke-ManifestUndo returns false for malformed JSON manifest' {
        $funcDefs = $script:ScriptAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
        $manifestUndo = $funcDefs | Where-Object { $_.Name -eq 'Invoke-ManifestUndo' }
        $getManifestDetail = $funcDefs | Where-Object { $_.Name -eq 'Get-ManifestDetail' }
        $initDir = $funcDefs | Where-Object { $_.Name -eq 'Initialize-AppDataDirectory' }

        $tempDir = Join-Path $env:TEMP "PesterNegative_$(Get-Random)"
        New-Item -Path $tempDir -ItemType Directory -Force | Out-Null
        try {
            $script:ManifestDir = $tempDir
            $script:ManifestPath = Join-Path $tempDir 'undo-manifest.json'
            $script:LogDir = Join-Path $tempDir 'logs'
            $script:LogFile = Join-Path $tempDir 'test.log'
            $script:JsonLogFile = Join-Path $tempDir 'test.jsonl'
            $script:Counters = @{ Errors = 0 }
            $DryRun = $false; $Undo = $false; $StatusOnly = $false; $ShowRationale = $false
            $Profile = 'Standard'; $OutputFormat = 'Text'

            Invoke-Expression $initDir.Extent.Text
            function Write-Status { param([string]$Message, [string]$Type = 'Info') }
            Invoke-Expression $manifestUndo.Extent.Text
            Invoke-Expression $getManifestDetail.Extent.Text

            # Write malformed JSON
            Set-Content -Path $script:ManifestPath -Value '{ this is not valid JSON !!!' -Force
            $result = Invoke-ManifestUndo
            $result | Should -Be $false
        } finally {
            Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'Invoke-ManifestUndo returns false for old schema version 1' {
        $funcDefs = $script:ScriptAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
        $manifestUndo = $funcDefs | Where-Object { $_.Name -eq 'Invoke-ManifestUndo' }
        $getManifestDetail = $funcDefs | Where-Object { $_.Name -eq 'Get-ManifestDetail' }
        $initDir = $funcDefs | Where-Object { $_.Name -eq 'Initialize-AppDataDirectory' }

        $tempDir = Join-Path $env:TEMP "PesterOldSchema_$(Get-Random)"
        New-Item -Path $tempDir -ItemType Directory -Force | Out-Null
        try {
            $script:ManifestDir = $tempDir
            $script:ManifestPath = Join-Path $tempDir 'undo-manifest.json'
            $script:LogDir = Join-Path $tempDir 'logs'
            $script:LogFile = Join-Path $tempDir 'test.log'
            $script:JsonLogFile = Join-Path $tempDir 'test.jsonl'
            $script:Counters = @{ Errors = 0 }
            $DryRun = $false; $Undo = $false; $StatusOnly = $false; $ShowRationale = $false
            $Profile = 'Standard'; $OutputFormat = 'Text'

            Invoke-Expression $initDir.Extent.Text
            function Write-Status { param([string]$Message, [string]$Type = 'Info') }
            Invoke-Expression $manifestUndo.Extent.Text
            Invoke-Expression $getManifestDetail.Extent.Text

            # Write old schema version 1 manifest
            $oldManifest = @{ SchemaVersion = 1; Actions = @() } | ConvertTo-Json -Depth 3
            Set-Content -Path $script:ManifestPath -Value $oldManifest -Force
            $result = Invoke-ManifestUndo
            $result | Should -Be $false
        } finally {
            Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'safelist domains never appear in any telemetry tier' {
        $scriptContent = Get-Content (Join-Path $PSScriptRoot '..\Disable-AdobeTelemetry.ps1') -Raw
        $scriptContent | Should -Match 'DomainSafelist\s+-contains\s+\$candidate'
        $safelistMatch = [regex]::Match($scriptContent, '\$script:DomainSafelist\s*=\s*@\(([^)]+)\)')
        $safelistDomains = $safelistMatch.Groups[1].Value -split "`n" |
            ForEach-Object { $_.Trim().Trim("'").Trim('"') } |
            Where-Object { $_ -and $_ -ne '' }
        $safelistDomains.Count | Should -BeGreaterOrEqual 5

        foreach ($tier in @('TelemetryDomainsMinimal', 'TelemetryDomainsStandard', 'TelemetryDomainsAggressive')) {
            $tierMatch = [regex]::Match($scriptContent, "\`$$tier\s*=\s*(?:[^@]*)?@\(([^)]+)\)")
            if ($tierMatch.Success) {
                $tierDomains = $tierMatch.Groups[1].Value -split "`n" |
                    ForEach-Object { $_.Trim().Trim("'").Trim('"') } |
                    Where-Object { $_ -and $_ -ne '' -and $_ -notmatch '^\$' }
                foreach ($safeDomain in $safelistDomains) {
                    $tierDomains | Should -Not -Contain $safeDomain -Because "$safeDomain is safelisted but found in $tier"
                }
            }
        }
    }

    It 'profile export/import round-trip preserves domains' {
        $funcDefs = $script:ScriptAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
        $exportFunc = $funcDefs | Where-Object { $_.Name -eq 'Export-RunProfile' }
        $importFunc = $funcDefs | Where-Object { $_.Name -eq 'Import-RunProfile' }
        $profilePropertyFunc = $funcDefs | Where-Object { $_.Name -eq 'Get-RunProfileProperty' }
        $profileValidationFunc = $funcDefs | Where-Object { $_.Name -eq 'Test-RunProfileData' }
        $initDir = $funcDefs | Where-Object { $_.Name -eq 'Initialize-AppDataDirectory' }

        $exportFunc | Should -Not -BeNullOrEmpty
        $importFunc | Should -Not -BeNullOrEmpty
        $profilePropertyFunc | Should -Not -BeNullOrEmpty
        $profileValidationFunc | Should -Not -BeNullOrEmpty

        $tempDir = Join-Path $env:TEMP "PesterProfileTest_$(Get-Random)"
        New-Item -Path $tempDir -ItemType Directory -Force | Out-Null
        try {
            $script:ManifestDir = $tempDir
            $script:LogDir = Join-Path $tempDir 'logs'
            $script:LogFile = Join-Path $tempDir 'test.log'
            $script:JsonLogFile = Join-Path $tempDir 'test.jsonl'
            $script:Version = '0.0.0-test'
            $script:Counters = @{ Errors = 0 }
            $DryRun = $false; $Undo = $false; $StatusOnly = $false; $ShowRationale = $false
            $Profile = 'Standard'; $OutputFormat = 'Text'
            $Only = $null; $Skip = $null
            $TelemetryDomains = @('test1.adobe.io', 'test2.adobe.io', 'test3.demdex.net')

            Invoke-Expression $initDir.Extent.Text
            function Write-Status { param([string]$Message, [string]$Type = 'Info') }
            Invoke-Expression $profilePropertyFunc.Extent.Text
            Invoke-Expression $profileValidationFunc.Extent.Text
            Invoke-Expression $exportFunc.Extent.Text
            Invoke-Expression $importFunc.Extent.Text

            $profilePath = Join-Path $tempDir 'test-profile.json'
            Export-RunProfile -Path $profilePath
            Test-Path $profilePath | Should -BeTrue

            $json = Get-Content $profilePath -Raw | ConvertFrom-Json
            $json.SchemaVersion | Should -Be 1
            $json.Version | Should -Be '0.0.0-test'
            $json.Profile | Should -Be 'Standard'
            $json.Domains.Count | Should -Be 3

            $TelemetryDomains = @()
            Import-RunProfile -Path $profilePath
            $script:TelemetryDomains.Count | Should -Be 3
            $script:TelemetryDomains | Should -Contain 'test1.adobe.io'
        } finally {
            Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'rejects invalid imported profile data before mutation' {
        $funcDefs = $script:ScriptAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
        $profilePropertyFunc = $funcDefs | Where-Object { $_.Name -eq 'Get-RunProfileProperty' }
        $profileValidationFunc = $funcDefs | Where-Object { $_.Name -eq 'Test-RunProfileData' }

        $profilePropertyFunc | Should -Not -BeNullOrEmpty
        $profileValidationFunc | Should -Not -BeNullOrEmpty

        Invoke-Expression $profilePropertyFunc.Extent.Text
        Invoke-Expression $profileValidationFunc.Extent.Text
        $script:ValidPhases = @(
            'Kill', 'GrowthSDK', 'CCXProcess', 'IPCBroker',
            'Tasks', 'Services', 'Registry', 'Firewall',
            'Hosts', 'Acrobat', 'Startup'
        )

        $validProfile = [pscustomobject]@{
            SchemaVersion = 1
            Version       = '2.3.2'
            Profile       = 'Standard'
            Only          = @('Firewall', 'Hosts')
            Skip          = @()
            Domains       = @('cc-api-data.adobe.io', 'fp.adobestats.io')
        }
        (Test-RunProfileData -ProfileData $validProfile).IsValid | Should -BeTrue

        $invalidProfiles = @(
            [pscustomobject]@{ Version = '2.3.2'; Profile = 'Standard'; Domains = @('cc-api-data.adobe.io') },
            [pscustomobject]@{ SchemaVersion = 99; Version = '2.3.2'; Profile = 'Standard'; Domains = @('cc-api-data.adobe.io') },
            [pscustomobject]@{ SchemaVersion = 1; Version = '2.3.2'; Profile = 'Maximum'; Domains = @('cc-api-data.adobe.io') },
            [pscustomobject]@{ SchemaVersion = 1; Version = '2.3.2'; Profile = 'Standard'; Only = @('BogusPhase'); Domains = @('cc-api-data.adobe.io') },
            [pscustomobject]@{ SchemaVersion = 1; Version = '2.3.2'; Profile = 'Standard'; Domains = @('not a domain') },
            [pscustomobject]@{ SchemaVersion = 1; Version = '2.3.2'; Profile = 'Standard'; Domains = @() }
        )

        foreach ($invalidProfile in $invalidProfiles) {
            $result = Test-RunProfileData -ProfileData $invalidProfile
            $result.IsValid | Should -BeFalse
            $result.Errors.Count | Should -BeGreaterThan 0
        }
    }

    It 'Get-StatusData defines all required status fields' {
        $scriptContent = Get-Content (Join-Path $PSScriptRoot '..\Disable-AdobeTelemetry.ps1') -Raw
        # Extract the Get-StatusData function and verify it initializes all required fields
        $funcMatch = [regex]::Match($scriptContent, '(?s)function Get-StatusData\s*\{(.+?)^\}', [System.Text.RegularExpressions.RegexOptions]::Multiline)
        $funcMatch.Success | Should -BeTrue
        $funcBody = $funcMatch.Groups[1].Value
        $funcBody | Should -Match 'Version'
        $funcBody | Should -Match 'Timestamp'
        $funcBody | Should -Match 'Computer'
        $funcBody | Should -Match 'Services'
        $funcBody | Should -Match 'Tasks'
        $funcBody | Should -Match 'GrowthSDK'
        $funcBody | Should -Match 'Firewall'
        $funcBody | Should -Match 'Connections'
        $funcBody | Should -Match 'HostsFile'
        $funcBody | Should -Match 'IFEO'
        $funcBody | Should -Match 'Registry'
        $funcBody | Should -Match 'Startup'
        $funcBody | Should -Match 'Watchdog'
        $funcBody | Should -Match 'DynamicKeywords'
        $funcBody | Should -Match 'Verification'
        $scriptContent | Should -Match 'Invoke-PostApplyVerification'
        $scriptContent | Should -Match 'VerificationFailures'
    }
}
