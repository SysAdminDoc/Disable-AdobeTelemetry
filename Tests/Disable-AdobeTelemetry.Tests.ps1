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

    It 'detects WAM markers' {
        $scriptContent = Get-Content (Join-Path $PSScriptRoot '..\Disable-AdobeTelemetry.ps1') -Raw
        $scriptContent | Should -Match 'Adobe Creative Cloud WAM - Start'
        $scriptContent | Should -Match 'Adobe Creative Cloud WAM - End'
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
            $Verbose = $false
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
        $scriptContent | Should -Match 'DomainSafelist\s+-notcontains'
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
}
