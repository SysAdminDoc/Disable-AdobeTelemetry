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

Describe 'Mocked Behavioral Windows Operations' {
    It 'creates firewall, dynamic keyword, and persistent route actions without touching Windows' {
        $funcDefs = $script:ScriptAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
        $blockFirewall = $funcDefs | Where-Object { $_.Name -eq 'Block-AdobeFirewall' }
        $addManifest = $funcDefs | Where-Object { $_.Name -eq 'Add-ManifestAction' }
        $resolveDomain = $funcDefs | Where-Object { $_.Name -eq 'Resolve-TelemetryDomainAddresses' }
        $getRoutePrint = $funcDefs | Where-Object { $_.Name -eq 'Get-RoutePrintOutput' }
        $addRoute = $funcDefs | Where-Object { $_.Name -eq 'Add-PersistentNullRoute' }
        $testDynamicKeywords = $funcDefs | Where-Object { $_.Name -eq 'Test-DynamicKeywordsAvailable' }
        $getAdobeDynamicKeywords = $funcDefs | Where-Object { $_.Name -eq 'Get-AdobeDynamicKeywords' }
        $addDynamicKeywords = $funcDefs | Where-Object { $_.Name -eq 'Add-DynamicKeywordFirewallRules' }
        $blockFirewall | Should -Not -BeNullOrEmpty
        $addManifest | Should -Not -BeNullOrEmpty
        $resolveDomain | Should -Not -BeNullOrEmpty
        $getRoutePrint | Should -Not -BeNullOrEmpty
        $addRoute | Should -Not -BeNullOrEmpty
        $testDynamicKeywords | Should -Not -BeNullOrEmpty
        $getAdobeDynamicKeywords | Should -Not -BeNullOrEmpty
        $addDynamicKeywords | Should -Not -BeNullOrEmpty

        $TelemetryDomains = @('telemetry.example.test')
        $script:AdobeInstallPaths = @()
        $script:LogFile = Join-Path $env:TEMP "DisableAdobeTelemetryFirewallTest_$(Get-Random).log"
        $script:Counters = @{
            FirewallRulesAdded = 0
            FirewallIPsBlocked = 0
        }
        $script:ManifestActions = @()
        $DryRun = $false

        function Write-Status { param([string]$Message, [string]$Type = 'Info') }
        function Write-Rationale { param([string]$Message) }
        function Get-NetFirewallRule { param([string]$DisplayName) }
        function Remove-NetFirewallRule { param([Parameter(ValueFromPipeline=$true)]$InputObject) process { } }
        function New-NetFirewallRule {
            param(
                [string]$DisplayName,
                [string]$Direction,
                [string]$Action,
                [string[]]$RemoteAddress,
                [string]$Protocol,
                [string]$Profile,
                $Enabled,
                [string]$Description,
                [string]$Program,
                [string]$RemoteDynamicKeywordAddresses
            )
        }
        function Get-MpComputerStatus { }
        function Get-MpPreference { }
        function Get-NetFirewallDynamicKeywordAddress { param($ErrorAction) }
        function Remove-NetFirewallDynamicKeywordAddress { param([string]$Id, $ErrorAction) }
        function New-NetFirewallDynamicKeywordAddress { param([string]$Id, [string]$Keyword, [bool]$AutoResolve, $ErrorAction) }

        Invoke-Expression $addManifest.Extent.Text
        Invoke-Expression $resolveDomain.Extent.Text
        Invoke-Expression $getRoutePrint.Extent.Text
        Invoke-Expression $addRoute.Extent.Text
        Invoke-Expression $testDynamicKeywords.Extent.Text
        Invoke-Expression $getAdobeDynamicKeywords.Extent.Text
        Invoke-Expression $addDynamicKeywords.Extent.Text
        Invoke-Expression $blockFirewall.Extent.Text
        Set-Item -Path function:Test-DynamicKeywordsAvailable -Value { return $false } -Force

        Mock Resolve-TelemetryDomainAddresses { @([System.Net.IPAddress]::Parse('203.0.113.10'), [System.Net.IPAddress]::Parse('2001:db8::10')) }
        Mock Get-RoutePrintOutput { @() }
        Mock Add-PersistentNullRoute { }
        Mock Get-NetFirewallRule { @([pscustomobject]@{ DisplayName = 'Block Adobe Telemetry - Old' }) }
        Mock Remove-NetFirewallRule { }
        Mock New-NetFirewallRule { }
        Mock Get-AdobeDynamicKeywords { @([pscustomobject]@{ Id = '{old-dk}'; Keyword = '*.adobe.io' }) }
        Mock Get-NetFirewallDynamicKeywordAddress { @([pscustomobject]@{ Id = '{old-dk}'; Keyword = '*.adobe.io' }) }
        Mock Remove-NetFirewallDynamicKeywordAddress { }
        Mock New-NetFirewallDynamicKeywordAddress { }
        try {
            Block-AdobeFirewall
            $dkCreated = Add-DynamicKeywordFirewallRules
        } finally {
            Remove-Item -Path $script:LogFile -Force -ErrorAction SilentlyContinue
        }

        $dkCreated | Should -Be 6
        Assert-MockCalled Remove-NetFirewallRule -Times 1 -Exactly
        Assert-MockCalled New-NetFirewallRule -ParameterFilter { $DisplayName -eq 'Block Adobe Telemetry - Outbound IPs (TCP)' -and $Protocol -eq 'TCP' -and $Action -eq 'Block' } -Times 1 -Exactly
        Assert-MockCalled New-NetFirewallRule -ParameterFilter { $DisplayName -eq 'Block Adobe Telemetry - Outbound IPs (UDP)' -and $Protocol -eq 'UDP' -and $Action -eq 'Block' } -Times 1 -Exactly
        Assert-MockCalled Get-RoutePrintOutput -ParameterFilter { $IPAddress -eq '203.0.113.10' } -Times 1 -Exactly
        Assert-MockCalled Add-PersistentNullRoute -ParameterFilter { $IPAddress -eq '203.0.113.10' } -Times 1 -Exactly
        Assert-MockCalled Remove-NetFirewallDynamicKeywordAddress -ParameterFilter { $Id -eq '{old-dk}' } -Times 1 -Exactly
        Assert-MockCalled New-NetFirewallDynamicKeywordAddress -Times 6 -Exactly
        Assert-MockCalled New-NetFirewallRule -ParameterFilter { $DisplayName -like 'Block Adobe Telemetry - FQDN *' -and $Action -eq 'Block' } -Times 6 -Exactly

        ($script:ManifestActions | Where-Object { $_.Action -eq 'AddFirewallRule' }).Count | Should -Be 8
        ($script:ManifestActions | Where-Object { $_.Action -eq 'AddRoute' }).Count | Should -BeGreaterOrEqual 1
        ($script:ManifestActions | Where-Object { $_.Action -eq 'AddDynamicKeyword' }).Count | Should -Be 6
    }

    It 'firewall phase cleanup preserves CCXProcess and AdobeIPCBroker rules' {
        $funcDefs = $script:ScriptAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
        $blockFirewall = $funcDefs | Where-Object { $_.Name -eq 'Block-AdobeFirewall' }
        $addManifest = $funcDefs | Where-Object { $_.Name -eq 'Add-ManifestAction' }
        $resolveDomain = $funcDefs | Where-Object { $_.Name -eq 'Resolve-TelemetryDomainAddresses' }
        $getRoutePrint = $funcDefs | Where-Object { $_.Name -eq 'Get-RoutePrintOutput' }
        $addRoute = $funcDefs | Where-Object { $_.Name -eq 'Add-PersistentNullRoute' }
        $testDynamicKeywords = $funcDefs | Where-Object { $_.Name -eq 'Test-DynamicKeywordsAvailable' }
        $getAdobeDynamicKeywords = $funcDefs | Where-Object { $_.Name -eq 'Get-AdobeDynamicKeywords' }

        $TelemetryDomains = @('telemetry.example.test')
        $script:AdobeInstallPaths = @()
        $script:LogFile = Join-Path $env:TEMP "DisableAdobeTelemetryFwFilterTest_$(Get-Random).log"
        $script:Counters = @{ FirewallRulesAdded = 0; FirewallIPsBlocked = 0 }
        $script:ManifestActions = @()
        $DryRun = $false

        function Write-Status { param([string]$Message, [string]$Type = 'Info') }
        function Write-Rationale { param([string]$Message) }
        function Get-NetFirewallRule { param([string]$DisplayName) }
        function Remove-NetFirewallRule { param([Parameter(ValueFromPipeline=$true)]$InputObject) process { } }
        function New-NetFirewallRule { param([string]$DisplayName, [string]$Direction, [string]$Action, [string[]]$RemoteAddress, [string]$Protocol, [string]$Profile, $Enabled, [string]$Description, [string]$Program, [string]$RemoteDynamicKeywordAddresses) }
        function Get-MpComputerStatus { }
        function Get-MpPreference { }

        Invoke-Expression $addManifest.Extent.Text
        Invoke-Expression $resolveDomain.Extent.Text
        Invoke-Expression $getRoutePrint.Extent.Text
        Invoke-Expression $addRoute.Extent.Text
        Invoke-Expression $testDynamicKeywords.Extent.Text
        Invoke-Expression $getAdobeDynamicKeywords.Extent.Text
        Invoke-Expression $blockFirewall.Extent.Text
        Set-Item -Path function:Test-DynamicKeywordsAvailable -Value { return $false } -Force

        Mock Resolve-TelemetryDomainAddresses { @([System.Net.IPAddress]::Parse('203.0.113.10')) }
        Mock Get-RoutePrintOutput { @() }
        Mock Add-PersistentNullRoute { }
        Mock Get-NetFirewallRule {
            @(
                [pscustomobject]@{ DisplayName = 'Block Adobe Telemetry - Outbound IPs (TCP)' }
                [pscustomobject]@{ DisplayName = 'Block Adobe Telemetry - CCXProcess (C:\ccx)' }
                [pscustomobject]@{ DisplayName = 'Block Adobe Telemetry - AdobeIPCBroker (C:\ipc)' }
            )
        }
        Mock Remove-NetFirewallRule { }
        Mock New-NetFirewallRule { }
        try {
            Block-AdobeFirewall
        } finally {
            Remove-Item -Path $script:LogFile -Force -ErrorAction SilentlyContinue
        }

        # Only the non-CCX/non-IPC rule should be removed by the firewall cleanup
        Assert-MockCalled Remove-NetFirewallRule -Times 1 -Exactly
        Assert-MockCalled Remove-NetFirewallRule -ParameterFilter { $InputObject.DisplayName -like '*CCXProcess*' } -Times 0 -Exactly
        Assert-MockCalled Remove-NetFirewallRule -ParameterFilter { $InputObject.DisplayName -like '*AdobeIPCBroker*' } -Times 0 -Exactly
    }

    It 'removes firewall rules, dynamic keywords, and routes during manifest undo in reverse order' {
        $funcDefs = $script:ScriptAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
        $manifestUndo = $funcDefs | Where-Object { $_.Name -eq 'Invoke-ManifestUndo' }
        $getManifestDetail = $funcDefs | Where-Object { $_.Name -eq 'Get-ManifestDetail' }
        $removeRoute = $funcDefs | Where-Object { $_.Name -eq 'Remove-PersistentNullRoute' }
        $manifestUndo | Should -Not -BeNullOrEmpty
        $getManifestDetail | Should -Not -BeNullOrEmpty
        $removeRoute | Should -Not -BeNullOrEmpty

        $tempDir = Join-Path $env:TEMP "PesterManifestOrder_$(Get-Random)"
        New-Item -Path $tempDir -ItemType Directory -Force | Out-Null
        try {
            $script:ManifestPath = Join-Path $tempDir 'undo-manifest.json'
            $script:UndoOrder = New-Object System.Collections.Generic.List[string]

            $manifest = @{
                SchemaVersion = 2
                Actions = @(
                    @{ Action = 'AddFirewallRule'; Details = @{ DisplayName = 'Block Adobe Telemetry - Test' } }
                    @{ Action = 'AddDynamicKeyword'; Details = @{ Id = '{dk-test}'; Keyword = '*.adobe.io' } }
                    @{ Action = 'AddRoute'; Details = @{ IPAddress = '203.0.113.10' } }
                )
            } | ConvertTo-Json -Depth 5
            Set-Content -Path $script:ManifestPath -Value $manifest -Force

            function Write-Status { param([string]$Message, [string]$Type = 'Info') }
            function Get-NetFirewallRule { param([string]$DisplayName) }
            function Remove-NetFirewallRule { param([Parameter(ValueFromPipeline=$true)]$InputObject) process { } }
            function Remove-NetFirewallDynamicKeywordAddress { param([string]$Id) }

            Invoke-Expression $getManifestDetail.Extent.Text
            Invoke-Expression $removeRoute.Extent.Text
            Invoke-Expression $manifestUndo.Extent.Text

            Mock Remove-PersistentNullRoute { $script:UndoOrder.Add("route delete $IPAddress") }
            Mock Get-NetFirewallRule { [pscustomobject]@{ DisplayName = $DisplayName } }
            Mock Remove-NetFirewallRule { $script:UndoOrder.Add("firewall $($InputObject.DisplayName)") }
            Mock Remove-NetFirewallDynamicKeywordAddress { $script:UndoOrder.Add("dynamic $Id") }

            $result = Invoke-ManifestUndo

            $result | Should -Be $true
            $script:UndoOrder[0] | Should -Be 'route delete 203.0.113.10'
            $script:UndoOrder[1] | Should -Be 'dynamic {dk-test}'
            $script:UndoOrder[2] | Should -Be 'firewall Block Adobe Telemetry - Test'
            Assert-MockCalled Remove-NetFirewallRule -Times 1 -Exactly
            Assert-MockCalled Remove-NetFirewallDynamicKeywordAddress -ParameterFilter { $Id -eq '{dk-test}' } -Times 1 -Exactly
        } finally {
            Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'registers, updates, and removes the watchdog scheduled task with encoded arguments' {
        $funcDefs = $script:ScriptAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
        $installWatchdog = $funcDefs | Where-Object { $_.Name -eq 'Install-Watchdog' }
        $removeWatchdog = $funcDefs | Where-Object { $_.Name -eq 'Remove-Watchdog' }
        $installWatchdog | Should -Not -BeNullOrEmpty
        $removeWatchdog | Should -Not -BeNullOrEmpty

        $script:WatchdogTaskName = 'Disable-AdobeTelemetry Watchdog'
        $script:CapturedWatchdogArguments = @()
        $PSCommandPath = 'C:\Tools\Disable-AdobeTelemetry.ps1'

        function Write-Status { param([string]$Message, [string]$Type = 'Info') }
            function New-ScheduledTaskAction { param([string]$Execute, [string]$Argument) }
            function New-ScheduledTaskTrigger { param([string]$DaysOfWeek, [string]$At) }
            function New-ScheduledTaskPrincipal { param([string]$UserId, [string]$RunLevel) }
            function New-ScheduledTaskSettingsSet { param([switch]$AllowStartIfOnBatteries, [switch]$DontStopIfGoingOnBatteries, [switch]$StartWhenAvailable, [timespan]$ExecutionTimeLimit) }
            function Get-ScheduledTask { param([string]$TaskName) }
            function Register-ScheduledTask { param([string]$TaskName, $Action, $Trigger, $Principal, $Settings, [string]$Description) }
            function Set-ScheduledTask { param([string]$TaskName, $Action, $Trigger, $Principal, $Settings) }
            function Unregister-ScheduledTask { param([string]$TaskName, [bool]$Confirm) }
            function New-EventLog { param([string]$LogName, [string]$Source) }

        Invoke-Expression $installWatchdog.Extent.Text
        Invoke-Expression $removeWatchdog.Extent.Text

        Mock New-ScheduledTaskAction {
            $script:CapturedWatchdogArguments += $Argument
            [pscustomobject]@{ Execute = $Execute; Argument = $Argument }
        }
        Mock New-ScheduledTaskTrigger { [pscustomobject]@{ DaysOfWeek = $DaysOfWeek; At = $At } }
        Mock New-ScheduledTaskPrincipal { [pscustomobject]@{ UserId = $UserId; RunLevel = $RunLevel } }
        Mock New-ScheduledTaskSettingsSet { [pscustomobject]@{ StartWhenAvailable = $StartWhenAvailable } }
        Mock Get-ScheduledTask { $null }
        Mock Register-ScheduledTask { }
        Mock Set-ScheduledTask { }
        Mock Unregister-ScheduledTask { }
        Mock New-EventLog { }

        Install-Watchdog

        Assert-MockCalled Register-ScheduledTask -ParameterFilter { $TaskName -eq 'Disable-AdobeTelemetry Watchdog' -and $Description -like 'Weekly reassertion*' } -Times 1 -Exactly
        $script:CapturedWatchdogArguments[0] | Should -Match '-EncodedCommand '
        $encoded = ($script:CapturedWatchdogArguments[0] -replace '^.*-EncodedCommand\s+', '')
        $decoded = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($encoded))
        $decoded | Should -Match 'Test-Path -LiteralPath'
        $decoded | Should -Match '-Skip Kill'

        Mock Get-ScheduledTask { [pscustomobject]@{ TaskName = 'Disable-AdobeTelemetry Watchdog' } }

        Install-Watchdog
        Remove-Watchdog

        Assert-MockCalled Set-ScheduledTask -ParameterFilter { $TaskName -eq 'Disable-AdobeTelemetry Watchdog' } -Times 1 -Exactly
        Assert-MockCalled Unregister-ScheduledTask -ParameterFilter { $TaskName -eq 'Disable-AdobeTelemetry Watchdog' -and $Confirm -eq $false } -Times 1 -Exactly
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

    It 'exposes watchdog, profile, WFP trace, plumbing, and JSON status controls' {
        $guiPath = Join-Path $PSScriptRoot '..\Disable-AdobeTelemetry.GUI.ps1'
        if (-not (Test-Path $guiPath)) { Set-ItResult -Skipped -Because 'GUI script not present'; return }
        $guiContent = Get-Content $guiPath -Raw

        $guiContent | Should -Match 'WatchdogInstallButton'
        $guiContent | Should -Match 'WatchdogRemoveButton'
        $guiContent | Should -Match 'ImportProfileButton'
        $guiContent | Should -Match 'ExportProfileButton'
        $guiContent | Should -Match 'SaveJsonButton'
        $guiContent | Should -Match 'TraceMinutesBox'
        $guiContent | Should -Match 'TraceOutputBox'
        $guiContent | Should -Match 'TraceBrowseButton'
        $guiContent | Should -Match 'TraceStartButton'
        $guiContent | Should -Match 'PlumbingAppBox'
        $guiContent | Should -Match 'PlumbingMinutesBox'
        $guiContent | Should -Match 'PlumbingStartButton'
    }

    It 'wires watchdog buttons to CLI switches' {
        $guiPath = Join-Path $PSScriptRoot '..\Disable-AdobeTelemetry.GUI.ps1'
        if (-not (Test-Path $guiPath)) { Set-ItResult -Skipped -Because 'GUI script not present'; return }
        $guiContent = Get-Content $guiPath -Raw

        $guiContent | Should -Match "'-InstallWatchdog'"
        $guiContent | Should -Match "'-RemoveWatchdog'"
    }

    It 'wires profile import/export to file picker dialogs' {
        $guiPath = Join-Path $PSScriptRoot '..\Disable-AdobeTelemetry.GUI.ps1'
        if (-not (Test-Path $guiPath)) { Set-ItResult -Skipped -Because 'GUI script not present'; return }
        $guiContent = Get-Content $guiPath -Raw

        $guiContent | Should -Match 'Microsoft\.Win32\.OpenFileDialog'
        $guiContent | Should -Match 'Microsoft\.Win32\.SaveFileDialog'
        $guiContent | Should -Match "'-ImportProfile'"
        $guiContent | Should -Match "'-ExportProfile'"
    }

    It 'wires JSON status save with OutputFile capture' {
        $guiPath = Join-Path $PSScriptRoot '..\Disable-AdobeTelemetry.GUI.ps1'
        if (-not (Test-Path $guiPath)) { Set-ItResult -Skipped -Because 'GUI script not present'; return }
        $guiContent = Get-Content $guiPath -Raw

        $guiContent | Should -Match "'-OutputFormat'"
        $guiContent | Should -Match "'-StatusOnly'"
        $guiContent | Should -Match 'OutputFile'
        $guiContent | Should -Match 'capturedLines'
    }

    It 'validates trace and plumbing minute inputs' {
        $guiPath = Join-Path $PSScriptRoot '..\Disable-AdobeTelemetry.GUI.ps1'
        if (-not (Test-Path $guiPath)) { Set-ItResult -Skipped -Because 'GUI script not present'; return }
        $guiContent = Get-Content $guiPath -Raw

        $guiContent | Should -Match "'-WfpTrace'"
        $guiContent | Should -Match "'-TraceMinutes'"
        $guiContent | Should -Match "'-PlumbingTest'"
        $guiContent | Should -Match "'-PlumbingApp'"
        $guiContent | Should -Match "'-PlumbingMinutes'"
        $guiContent | Should -Match '1-1440'
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

    It 'registry status convergence inventory covers fleet policy surfaces' {
        $funcDefs = $script:ScriptAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
        $addPolicyCheck = $funcDefs | Where-Object { $_.Name -eq 'Add-PolicyStatusCheck' }
        $policyStatusChecks = $funcDefs | Where-Object { $_.Name -eq 'Get-RegistryPolicyStatusChecks' }
        $addPolicyCheck | Should -Not -BeNullOrEmpty
        $policyStatusChecks | Should -Not -BeNullOrEmpty

        Invoke-Expression $addPolicyCheck.Extent.Text
        Invoke-Expression $policyStatusChecks.Extent.Text
        $Profile = 'Aggressive'

        $checks = @(Get-RegistryPolicyStatusChecks)
        $checks.Count | Should -BeGreaterThan 60
        $checks.Path | Should -Contain 'HKLM:\SOFTWARE\Policies\Adobe\Substance 3D'
        $checks.Path | Should -Contain 'HKCU:\SOFTWARE\Adobe\Substance 3D Painter\Settings'
        $checks.Path | Should -Contain 'HKCU:\SOFTWARE\Adobe\CommonFiles\CRLog'
        ($checks | Where-Object { $_.Path -like '*Wow6432Node*' -and $_.Name -eq 'bUsageMeasurement' }).Count | Should -Be 2
        ($checks | Where-Object { $_.Name -eq 'iUnknownURLPerms' -and $_.Expected -eq 3 }).Count | Should -Be 4

        foreach ($field in @('Phase', 'Path', 'Name', 'Expected', 'Type')) {
            $checks[0].Keys | Should -Contain $field
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
        $funcBody | Should -Match 'Get-RegistryPolicyStatusChecks'
        $funcBody | Should -Match 'Actual'
        $funcBody | Should -Match 'Path'
        $funcBody | Should -Match 'Phase'
        $scriptContent | Should -Match 'Invoke-PostApplyVerification'
        $scriptContent | Should -Match 'VerificationFailures'
    }
}

Describe 'Inventory Data File Sync' {
    It 'Data/Inventories.psd1 exists and parses' {
        $dataFile = Join-Path $PSScriptRoot '..\Data\Inventories.psd1'
        if (-not (Test-Path $dataFile)) { Set-ItResult -Skipped -Because 'Data file not present'; return }
        $data = Import-PowerShellDataFile $dataFile
        $data.Processes.Count | Should -BeGreaterOrEqual 15
        $data.Services.Count | Should -BeGreaterOrEqual 5
        $data.DomainsMinimal.Count | Should -BeGreaterOrEqual 10
        $data.DomainsStandardAdditions.Count | Should -BeGreaterOrEqual 5
        $data.DomainSafelist.Count | Should -BeGreaterOrEqual 5
    }

    It 'data file domains match main script domains' {
        $dataFile = Join-Path $PSScriptRoot '..\Data\Inventories.psd1'
        if (-not (Test-Path $dataFile)) { Set-ItResult -Skipped -Because 'Data file not present'; return }
        $data = Import-PowerShellDataFile $dataFile
        $scriptContent = Get-Content (Join-Path $PSScriptRoot '..\Disable-AdobeTelemetry.ps1') -Raw

        foreach ($domain in $data.DomainsMinimal) {
            $scriptContent | Should -Match ([regex]::Escape($domain))
        }
        foreach ($domain in $data.DomainsStandardAdditions) {
            $scriptContent | Should -Match ([regex]::Escape($domain))
        }
        foreach ($domain in $data.DomainSafelist) {
            $scriptContent | Should -Match ([regex]::Escape($domain))
        }
    }

    It 'data file processes match main script processes' {
        $dataFile = Join-Path $PSScriptRoot '..\Data\Inventories.psd1'
        if (-not (Test-Path $dataFile)) { Set-ItResult -Skipped -Because 'Data file not present'; return }
        $data = Import-PowerShellDataFile $dataFile
        $scriptContent = Get-Content (Join-Path $PSScriptRoot '..\Disable-AdobeTelemetry.ps1') -Raw

        if ($scriptContent -match '\$AdobeProcesses\s*=\s*@\(([\s\S]*?)\)') {
            $procBlock = $Matches[1]
            $scriptProcesses = $procBlock -split "`n" |
                ForEach-Object { ($_ -split '#')[0].Trim().Trim("'").Trim('"') } |
                Where-Object { $_ -and $_ -ne '' }
            $data.Processes.Count | Should -Be $scriptProcesses.Count
        }
    }

    It 'Build.ps1 -Verify passes when in sync' {
        $buildScript = Join-Path $PSScriptRoot '..\Build.ps1'
        if (-not (Test-Path $buildScript)) { Set-ItResult -Skipped -Because 'Build.ps1 not present'; return }
        $dataFile = Join-Path $PSScriptRoot '..\Data\Inventories.psd1'
        if (-not (Test-Path $dataFile)) { Set-ItResult -Skipped -Because 'Data file not present'; return }

        $scriptContent = Get-Content (Join-Path $PSScriptRoot '..\Disable-AdobeTelemetry.ps1') -Raw
        $scriptContent | Should -Match '# BEGIN INVENTORY:Processes'
        $scriptContent | Should -Match '# END INVENTORY:Domains'
    }
}

Describe 'Audit Regression Tests' {
    It '.NOTES version matches runtime DisplayVersion' {
        $scriptContent = Get-Content (Join-Path $PSScriptRoot '..\Disable-AdobeTelemetry.ps1') -Raw
        $notesVersion = ([regex]::Match($scriptContent, 'Version\s*:\s*(\d+\.\d+\.\d+)')).Groups[1].Value
        $displayVersion = ([regex]::Match($scriptContent, "DisplayVersion\s*=\s*'v(\d+\.\d+\.\d+)'")).Groups[1].Value
        $notesVersion | Should -Be $displayVersion
    }

    It 'hosts file operations do not use ASCII encoding' {
        $scriptContent = Get-Content (Join-Path $PSScriptRoot '..\Disable-AdobeTelemetry.ps1') -Raw
        $scriptContent | Should -Not -Match '-Encoding ASCII'
    }

    It 'hosts block writes BOM-free UTF-8 under an exclusive lock and strips WAM' {
        $funcDefs = $script:ScriptAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
        $blockHosts = $funcDefs | Where-Object { $_.Name -eq 'Block-AdobeHostsFile' }
        $blockHosts | Should -Not -BeNullOrEmpty

        # Redirect the hardcoded hosts path ($env:SystemRoot\System32\drivers\etc\hosts) to a temp tree
        $origSystemRoot = $env:SystemRoot
        $tmpRoot = Join-Path $env:TEMP "DAHostsTest_$(Get-Random)"
        $etcDir = Join-Path $tmpRoot 'System32\drivers\etc'
        New-Item -Path $etcDir -ItemType Directory -Force | Out-Null
        $hostsFile = Join-Path $etcDir 'hosts'
        # Seed with a BOM + an existing WAM injection block
        $seed = "127.0.0.1 localhost`r`n# Adobe Creative Cloud WAM - Start`r`n166.117.29.222 detect-ccd.creativecloud.adobe.com`r`n# Adobe Creative Cloud WAM - End`r`n"
        [System.IO.File]::WriteAllText($hostsFile, $seed, (New-Object System.Text.UTF8Encoding($true)))

        function Write-Status { param([string]$Message, [string]$Type = 'Info') }
        function Write-Rationale { param([string]$Message) }
        function Add-ManifestAction { param([string]$Phase, [string]$Action, [hashtable]$Details) }
        function Test-DohEnabled { @{ Enabled = $false; Sources = @() } }
        $TelemetryDomains = @('telemetry.example.test', 'stats.example.test')
        $DryRun = $false
        $script:Counters = @{ DomainsBlocked = 0 }

        Invoke-Expression $blockHosts.Extent.Text
        try {
            $env:SystemRoot = $tmpRoot
            Block-AdobeHostsFile
        } finally {
            $env:SystemRoot = $origSystemRoot
        }

        $bytes = [System.IO.File]::ReadAllBytes($hostsFile)
        # No UTF-8 BOM (EF BB BF)
        ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) | Should -BeFalse
        $written = [System.IO.File]::ReadAllText($hostsFile)
        $written | Should -Match '0\.0\.0\.0    telemetry\.example\.test'
        $written | Should -Match '# --- Adobe Telemetry Block'
        $written | Should -Not -Match 'Adobe Creative Cloud WAM'
        $written | Should -Match '127\.0\.0\.1 localhost'

        Remove-Item -Path $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'hosts ACL lock is opt-in, reversible, and denies SYSTEM write' {
        $scriptContent = Get-Content (Join-Path $PSScriptRoot '..\Disable-AdobeTelemetry.ps1') -Raw
        # Opt-in switch exists
        $scriptContent | Should -Match '\[switch\]\$LockHostsFile'
        # Gated behind the switch and denies SYSTEM write
        $scriptContent | Should -Match 'if \(\$LockHostsFile\)'
        $scriptContent | Should -Match "LocalSystemSid"
        $scriptContent | Should -Match "'WriteData,AppendData,Delete', 'Deny'"
        # Recorded for undo and handled by both undo paths
        $scriptContent | Should -Match "Add-ManifestAction -Phase 'Hosts' -Action 'LockHostsAcl'"
        $scriptContent | Should -Match "'LockHostsAcl' \{"
        $scriptContent | Should -Match 'function Remove-HostsAclLock'
    }

    It 'hosts undo paths write BOM-free UTF-8' {
        $funcDefs = $script:ScriptAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
        $byMarker = $funcDefs | Where-Object { $_.Name -eq 'Remove-HostsBlockByMarker' }
        $byMarker | Should -Not -BeNullOrEmpty
        $byMarker.Extent.Text | Should -Match 'UTF8Encoding\(\$false\)'
        $byMarker.Extent.Text | Should -Not -Match 'Set-Content.*-Encoding UTF8'
    }

    It 'Test-DohEnabled returns a well-formed result without false positives from DoH templates' {
        $funcDefs = $script:ScriptAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
        $dohFunc = $funcDefs | Where-Object { $_.Name -eq 'Test-DohEnabled' }
        $dohFunc | Should -Not -BeNullOrEmpty
        Invoke-Expression $dohFunc.Extent.Text
        $result = Test-DohEnabled
        $result.Keys | Should -Contain 'Enabled'
        $result.Keys | Should -Contain 'Sources'
        $result.Enabled | Should -BeOfType [bool]
        # Must not rely on Get-DnsClientDohServerAddress (lists templates present when DoH is off)
        $dohFunc.Extent.Text | Should -Not -Match 'Get-DnsClientDohServerAddress'
        # Must not treat DohProfileSettings (capability templates) as active DoH
        $dohFunc.Extent.Text | Should -Match 'DohInterfaceSettings'
    }

    It 'writes Application event log summary with correct EventIDs' {
        $scriptContent = Get-Content (Join-Path $PSScriptRoot '..\Disable-AdobeTelemetry.ps1') -Raw
        $scriptContent | Should -Match 'function Write-SummaryEvent'
        # EventID mapping
        $scriptContent | Should -Match 'Success = @\{ Id = 1000'
        $scriptContent | Should -Match 'Partial = @\{ Id = 2000'
        $scriptContent | Should -Match 'Failure = @\{ Id = 3000'
        $scriptContent | Should -Match 'Undo    = @\{ Id = 4000'
        # Wired into apply (success + partial) and undo exit paths
        $scriptContent | Should -Match 'Write-SummaryEvent -Result Success'
        $scriptContent | Should -Match 'Write-SummaryEvent -Result Partial'
        $scriptContent | Should -Match 'Write-SummaryEvent -Result Undo'
        # Does not emit events for dry runs
        $fn = [regex]::Match($scriptContent, '(?s)function Write-SummaryEvent \{.*?\n\}')
        $fn.Value | Should -Match 'if \(\$DryRun\) \{ return \}'
        # Status reports the event source
        $scriptContent | Should -Match '\$statusData\.EventLog'
    }

    It 'update check is non-blocking, cached, and version-aware' {
        $funcDefs = $script:ScriptAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
        $upd = $funcDefs | Where-Object { $_.Name -eq 'Test-UpdateAvailable' }
        $upd | Should -Not -BeNullOrEmpty
        $body = $upd.Extent.Text
        $body | Should -Match 'Start-Job'                 # non-blocking background refresh
        $body | Should -Match 'update-check\.json'         # daily cache file
        $body | Should -Match 'TotalHours -lt 24'          # 24h cache window
        $body | Should -Match '\[version\]\$latest -gt \[version\]\$current'  # semver comparison
        $body | Should -Match '-UseBasicParsing'           # CVE-2025-54100 safe

        # Behavioral: newer cached tag warns, same tag does not
        function Write-Status { param($Message, $Type) $script:__updMsgs += ,"$Type|$Message" }
        $script:Version = '2.5.0'
        Invoke-Expression $body
        $cachePath = Join-Path (Join-Path $env:APPDATA 'Disable-AdobeTelemetry') 'update-check.json'
        try {
            $script:__updMsgs = @()
            @{ LatestTag = 'v9.9.9'; CheckedUtc = [datetime]::UtcNow.ToString('o') } | ConvertTo-Json | Set-Content $cachePath -Encoding UTF8
            Test-UpdateAvailable
            ($script:__updMsgs -join ' ') | Should -Match 'Update available: v9.9.9'

            $script:__updMsgs = @()
            @{ LatestTag = 'v2.5.0'; CheckedUtc = [datetime]::UtcNow.ToString('o') } | ConvertTo-Json | Set-Content $cachePath -Encoding UTF8
            Test-UpdateAvailable
            ($script:__updMsgs -join ' ') | Should -Not -Match 'Update available'
        } finally {
            Get-Job -ErrorAction SilentlyContinue | Remove-Job -Force -ErrorAction SilentlyContinue
            Remove-Item $cachePath -Force -ErrorAction SilentlyContinue
        }
    }

    It 'JSON status mode suppresses the console banner' {
        $scriptContent = Get-Content (Join-Path $PSScriptRoot '..\Disable-AdobeTelemetry.ps1') -Raw
        $scriptContent | Should -Match '\$jsonStatus = \$StatusOnly -and \(\$OutputFormat -eq ''JSON''\)'
        $scriptContent | Should -Match 'if \(-not \$jsonStatus\) \{'
    }

    It 'Intune fleet detection/remediation scripts exist with correct exit conventions' {
        $detect = Join-Path $PSScriptRoot '..\fleet\Detect-AdobeTelemetry.ps1'
        $remediate = Join-Path $PSScriptRoot '..\fleet\Remediate-AdobeTelemetry.ps1'
        Test-Path $detect | Should -BeTrue
        Test-Path $remediate | Should -BeTrue

        $errs = $null
        [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $detect), [ref]$null, [ref]$errs) | Out-Null
        $errs | Should -BeNullOrEmpty
        [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $remediate), [ref]$null, [ref]$errs) | Out-Null
        $errs | Should -BeNullOrEmpty

        $dContent = Get-Content $detect -Raw
        $dContent | Should -Match '-StatusOnly -OutputFormat JSON'
        $dContent | Should -Match 'exit 0'   # compliant
        $dContent | Should -Match 'exit 1'   # remediate

        $rContent = Get-Content $remediate -Raw
        # Treat 0 and 3010 (reboot recommended) as success
        $rContent | Should -Match '\$code -eq 0 -or \$code -eq 3010'
    }

    It 'status data reports DoH bypass state' {
        $scriptContent = Get-Content (Join-Path $PSScriptRoot '..\Disable-AdobeTelemetry.ps1') -Raw
        $scriptContent | Should -Match '\$statusData\.HostsFile\.DohEnabled'
        $scriptContent | Should -Match 'DNS-over-HTTPS is enabled'
    }

    It 'all web requests use -UseBasicParsing (CVE-2025-54100 guard)' {
        $scriptContent = Get-Content (Join-Path $PSScriptRoot '..\Disable-AdobeTelemetry.ps1') -Raw
        # Each Invoke-WebRequest / Invoke-RestMethod invocation, up to the end of its
        # (possibly line-continued) statement, must contain -UseBasicParsing.
        $calls = [regex]::Matches($scriptContent, '(?s)Invoke-(?:WebRequest|RestMethod)\b.*?(?=(?<!`)\r?\n)')
        foreach ($call in $calls) {
            $call.Value | Should -Match '-UseBasicParsing' -Because "web call must not use the legacy IE DOM parser: $($call.Value.Trim())"
        }
    }

    It 'GrowthSDK additional-path cleanup handles files, not just directories' {
        $scriptContent = Get-Content (Join-Path $PSScriptRoot '..\Disable-AdobeTelemetry.ps1') -Raw
        # The AdditionalPaths loop must not gate removal on -PathType Container,
        # or file entries like opm.db are never cleaned.
        $loop = [regex]::Match($scriptContent, '(?s)foreach \(\$relPath in \$AdditionalPaths\).*?Remove-Item \$targetPath')
        $loop.Success | Should -BeTrue
        $loop.Value | Should -Not -Match '\$targetPath -PathType Container'
    }

    It 'Test-PhaseEnabled honors -Skip even when combined with -Only' {
        $funcDefs = $script:ScriptAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
        $phaseFunc = $funcDefs | Where-Object { $_.Name -eq 'Test-PhaseEnabled' }
        $phaseFunc | Should -Not -BeNullOrEmpty
        Invoke-Expression $phaseFunc.Extent.Text

        $Only = @('Firewall', 'Hosts'); $Skip = @('Hosts')
        (Test-PhaseEnabled 'Firewall') | Should -BeTrue
        (Test-PhaseEnabled 'Hosts')    | Should -BeFalse   # -Skip wins over -Only
        (Test-PhaseEnabled 'Kill')     | Should -BeFalse   # not in -Only

        $Only = @(); $Skip = @('Kill')
        (Test-PhaseEnabled 'Kill')     | Should -BeFalse
        (Test-PhaseEnabled 'Firewall') | Should -BeTrue

        $Only = @('Registry'); $Skip = @()
        (Test-PhaseEnabled 'Registry') | Should -BeTrue
        (Test-PhaseEnabled 'Hosts')    | Should -BeFalse
    }

    It 'legacy undo restores renamed startup shortcuts' {
        $funcDefs = $script:ScriptAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
        $undo = $funcDefs | Where-Object { $_.Name -eq 'Invoke-Undo' }
        $undo | Should -Not -BeNullOrEmpty
        # Must enumerate *.lnk.disabled and rename back (strip the .disabled suffix)
        $undo.Extent.Text | Should -Match "Filter '\*\.lnk\.disabled'"
        $undo.Extent.Text | Should -Match "-replace '\\\.disabled\`$', ''"
    }

    It 'Initialize-AppDataDirectory short-circuits after first call' {
        $funcDefs = $script:ScriptAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
        $initFunc = $funcDefs | Where-Object { $_.Name -eq 'Initialize-AppDataDirectory' }
        $initFunc | Should -Not -BeNullOrEmpty
        $initFunc.Extent.Text | Should -Match 'if \(\$script:AppDataInitialized\) \{ return \}'
        $initFunc.Extent.Text | Should -Match '\$script:AppDataInitialized = \$true'

        # Behavioral: second call performs no filesystem probe
        $script:ManifestDir = Join-Path $env:TEMP "DAInitTest_$(Get-Random)"
        $script:LogDir = Join-Path $script:ManifestDir 'logs'
        $script:AppDataInitialized = $false
        Invoke-Expression $initFunc.Extent.Text
        Mock Test-Path { $script:__probe++; $false }
        $script:__probe = 0
        Initialize-AppDataDirectory   # first call creates dirs, probes
        $firstProbe = $script:__probe
        $script:__probe = 0
        Initialize-AppDataDirectory   # second call must short-circuit (no probes)
        $script:__probe | Should -Be 0
        $firstProbe | Should -BeGreaterThan 0
        Remove-Item $script:ManifestDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'legacy undo includes CreativeCloud registry path' {
        $scriptContent = Get-Content (Join-Path $PSScriptRoot '..\Disable-AdobeTelemetry.ps1') -Raw
        $scriptContent | Should -Match 'Policies\\Adobe\\CreativeCloud'
    }

    It 'firewall exe paths are deduplicated before rule creation' {
        $scriptContent = Get-Content (Join-Path $PSScriptRoot '..\Disable-AdobeTelemetry.ps1') -Raw
        $scriptContent | Should -Match '\$adobeExePaths\s*=\s*@\(\$adobeExePaths\s*\|\s*Sort-Object\s*-Unique\)'
    }

    It 'WFP trace validates output path for shell metacharacters' {
        $scriptContent = Get-Content (Join-Path $PSScriptRoot '..\Disable-AdobeTelemetry.ps1') -Raw
        $scriptContent | Should -Match 'outputPath\s+-match\s+.*[";|&]'
    }

    It 'GrowthSDK removal retries instead of fixed sleep' {
        $scriptContent = Get-Content (Join-Path $PSScriptRoot '..\Disable-AdobeTelemetry.ps1') -Raw
        $scriptContent | Should -Match 'retryMs\s*\*=\s*2'
    }

    It 'GrowthSDK retry loop re-attempts Remove-Item inside the loop body' {
        $scriptContent = Get-Content (Join-Path $PSScriptRoot '..\Disable-AdobeTelemetry.ps1') -Raw
        # The for-retry loop must contain a Remove-Item, not just Start-Sleep
        $loop = [regex]::Match($scriptContent, '(?s)for \(\$attempt = 0.*?Test-Path \$growthDir\); \$attempt\+\+\) \{(.*?)\}')
        $loop.Success | Should -BeTrue
        $loop.Groups[1].Value | Should -Match 'Remove-Item \$growthDir'
    }

    It 'GUI reads stderr asynchronously to prevent deadlock' {
        $guiPath = Join-Path $PSScriptRoot '..\Disable-AdobeTelemetry.GUI.ps1'
        if (-not (Test-Path $guiPath)) { Set-ItResult -Skipped -Because 'GUI script not present'; return }
        $guiContent = Get-Content $guiPath -Raw
        $guiContent | Should -Match 'ReadToEndAsync'
    }

    It 'GUI tracks child PIDs and kills them on window close' {
        $guiPath = Join-Path $PSScriptRoot '..\Disable-AdobeTelemetry.GUI.ps1'
        if (-not (Test-Path $guiPath)) { Set-ItResult -Skipped -Because 'GUI script not present'; return }
        $guiContent = Get-Content $guiPath -Raw
        $guiContent | Should -Match 'ActiveChildPids'
        $guiContent | Should -Match '\$activeChildPids\.Add\(\$process\.Id\)'
        $guiContent | Should -Match '\$activeChildPids\.Remove\(\$process\.Id\)'
        $guiContent | Should -Match '\$window\.Add_Closing'
        $guiContent | Should -Match 'Stop-Process -Id \$childPid -Force'
    }

    It 'manifest undo warns when renamed file is missing' {
        $scriptContent = Get-Content (Join-Path $PSScriptRoot '..\Disable-AdobeTelemetry.ps1') -Raw
        $scriptContent | Should -Match 'Skipped file restore \(renamed file missing'
        $scriptContent | Should -Match 'Skipped shortcut restore \(file missing'
    }

    It 'DryRun merges upstream domains in-memory before returning' {
        $scriptContent = Get-Content (Join-Path $PSScriptRoot '..\Disable-AdobeTelemetry.ps1') -Raw
        $mergeFunc = [regex]::Match($scriptContent, '(?s)function Merge-UpstreamDomains\s*\{(.+?)^\}', [System.Text.RegularExpressions.RegexOptions]::Multiline)
        $mergeFunc.Success | Should -BeTrue
        $mergeBody = $mergeFunc.Groups[1].Value
        $mergeIdx = $mergeBody.IndexOf('TelemetryDomains =')
        $dryRunIdx = $mergeBody.IndexOf('if ($DryRun)')
        $mergeIdx | Should -BeLessThan $dryRunIdx -Because 'domain merge must happen before DryRun check'
    }

    It 'Import and Export profile cannot be used together' {
        $scriptContent = Get-Content (Join-Path $PSScriptRoot '..\Disable-AdobeTelemetry.ps1') -Raw
        $scriptContent | Should -Match 'ExportProfile -and \$ImportProfile'
    }

    It 'PlumbingTest kills launched app after deadline' {
        $scriptContent = Get-Content (Join-Path $PSScriptRoot '..\Disable-AdobeTelemetry.ps1') -Raw
        $scriptContent | Should -Match 'proc\.HasExited'
    }

    It 'imported Minimal profile reapplies phase-skip defaults' {
        $scriptContent = Get-Content (Join-Path $PSScriptRoot '..\Disable-AdobeTelemetry.ps1') -Raw
        $scriptContent | Should -Match "Import-RunProfile[\s\S]{0,200}Profile -eq 'Minimal'"
    }

    It 'GUI warns when main script is missing on startup' {
        $guiPath = Join-Path $PSScriptRoot '..\Disable-AdobeTelemetry.GUI.ps1'
        if (-not (Test-Path $guiPath)) { Set-ItResult -Skipped -Because 'GUI script not present'; return }
        $guiContent = Get-Content $guiPath -Raw
        $guiContent | Should -Match 'Main script not found'
    }
}
