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
            Where-Object { $_ -and $_ -notmatch '^\s*#' -and $_ -ne '' }
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

    It 'version strings are consistent' {
        $scriptContent = Get-Content (Join-Path $PSScriptRoot '..\Disable-AdobeTelemetry.ps1') -Raw
        $versions = [regex]::Matches($scriptContent, 'v(\d+\.\d+\.\d+)') | ForEach-Object { $_.Groups[1].Value }
        $versions | Sort-Object -Unique | Should -HaveCount 1
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
