<#
.SYNOPSIS
    Disable-AdobeTelemetry.GUI.ps1 - WPF companion GUI for Disable-AdobeTelemetry.
.DESCRIPTION
    Catppuccin Mocha themed GUI wrapper that invokes Disable-AdobeTelemetry.ps1
    with streaming log output. All operations run asynchronously to keep the UI responsive.
.NOTES
    Author  : Matt (Maven Imaging)
    Version : 2.4.1
    Date    : 2026-07-01
#>

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)
if (-not $isAdmin) {
    Start-Process powershell.exe -Verb RunAs -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`""
    )
    exit 0
}

# Catppuccin Mocha palette
$colors = @{
    Base     = '#1e1e2e'
    Mantle   = '#181825'
    Crust    = '#11111b'
    Surface0 = '#313244'
    Surface1 = '#45475a'
    Surface2 = '#585b70'
    Text     = '#cdd6f4'
    Subtext0 = '#a6adc8'
    Subtext1 = '#bac2de'
    Green    = '#a6e3a1'
    Red      = '#f38ba8'
    Yellow   = '#f9e2af'
    Blue     = '#89b4fa'
    Mauve    = '#cba6f7'
    Teal     = '#94e2d5'
    Peach    = '#fab387'
    Lavender = '#b4befe'
}

[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Disable-AdobeTelemetry v2.4.1"
        Width="800" Height="720"
        MinWidth="640" MinHeight="520"
        Background="$($colors.Base)"
        WindowStartupLocation="CenterScreen">
    <Window.Resources>
        <Style TargetType="Button">
            <Setter Property="Background" Value="$($colors.Surface0)"/>
            <Setter Property="Foreground" Value="$($colors.Text)"/>
            <Setter Property="BorderBrush" Value="$($colors.Surface1)"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding" Value="16,8"/>
            <Setter Property="FontSize" Value="13"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="border" Background="{TemplateBinding Background}"
                                BorderBrush="{TemplateBinding BorderBrush}"
                                BorderThickness="{TemplateBinding BorderThickness}"
                                CornerRadius="6" Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="border" Property="Background" Value="$($colors.Surface1)"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter TargetName="border" Property="Opacity" Value="0.5"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style TargetType="ComboBox">
            <Setter Property="Background" Value="$($colors.Surface0)"/>
            <Setter Property="Foreground" Value="$($colors.Text)"/>
            <Setter Property="BorderBrush" Value="$($colors.Surface1)"/>
            <Setter Property="FontSize" Value="13"/>
            <Setter Property="Padding" Value="8,4"/>
        </Style>
        <Style TargetType="CheckBox">
            <Setter Property="Foreground" Value="$($colors.Text)"/>
            <Setter Property="FontSize" Value="13"/>
            <Setter Property="Margin" Value="0,2"/>
        </Style>
        <Style TargetType="Label">
            <Setter Property="Foreground" Value="$($colors.Subtext1)"/>
            <Setter Property="FontSize" Value="13"/>
        </Style>
        <Style TargetType="TextBox">
            <Setter Property="Background" Value="$($colors.Surface0)"/>
            <Setter Property="Foreground" Value="$($colors.Text)"/>
            <Setter Property="BorderBrush" Value="$($colors.Surface1)"/>
            <Setter Property="CaretBrush" Value="$($colors.Text)"/>
            <Setter Property="FontSize" Value="13"/>
            <Setter Property="Padding" Value="6,4"/>
            <Setter Property="VerticalContentAlignment" Value="Center"/>
        </Style>
    </Window.Resources>
    <Grid Margin="16">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <!-- Header -->
        <StackPanel Grid.Row="0" Margin="0,0,0,12">
            <TextBlock Text="Disable-AdobeTelemetry" FontSize="22" FontWeight="Bold"
                       Foreground="$($colors.Blue)" Margin="0,0,0,2"/>
            <TextBlock Text="Comprehensive Adobe telemetry and GrowthSDK suppression"
                       FontSize="12" Foreground="$($colors.Subtext0)"/>
        </StackPanel>

        <!-- Controls row -->
        <Grid Grid.Row="1" Margin="0,0,0,10">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="Auto"/>
                <ColumnDefinition Width="Auto"/>
                <ColumnDefinition Width="*"/>
            </Grid.ColumnDefinitions>

            <StackPanel Grid.Column="0" Orientation="Horizontal" Margin="0,0,16,0">
                <Label Content="Profile:" VerticalAlignment="Center"/>
                <ComboBox x:Name="ProfileCombo" Width="120" VerticalAlignment="Center">
                    <ComboBoxItem Content="Minimal"/>
                    <ComboBoxItem Content="Standard" IsSelected="True"/>
                    <ComboBoxItem Content="Aggressive"/>
                </ComboBox>
            </StackPanel>

            <StackPanel Grid.Column="1" Margin="0,0,16,0">
                <CheckBox x:Name="DryRunCheck" Content="Dry Run"/>
                <CheckBox x:Name="VerboseCheck" Content="Show Rationale"/>
            </StackPanel>
        </Grid>

        <!-- Primary action buttons -->
        <WrapPanel Grid.Row="2" Margin="0,0,0,8">
            <Button x:Name="RunButton" Content="Apply Protections" Margin="0,0,8,0"
                    Background="$($colors.Surface0)" Foreground="$($colors.Green)"/>
            <Button x:Name="StatusButton" Content="Status Check" Margin="0,0,8,0"/>
            <Button x:Name="UndoButton" Content="Undo All" Margin="0,0,8,0"
                    Foreground="$($colors.Red)"/>
            <Button x:Name="ConnectionButton" Content="Connection Report" Margin="0,0,8,0"
                    Foreground="$($colors.Teal)"/>
            <Button x:Name="ClearButton" Content="Clear Log" Margin="0,0,0,0"
                    Foreground="$($colors.Subtext0)"/>
        </WrapPanel>

        <!-- Tool buttons -->
        <WrapPanel Grid.Row="3" Margin="0,0,0,8">
            <Button x:Name="WatchdogInstallButton" Content="Install Watchdog" Margin="0,0,8,0"
                    Foreground="$($colors.Lavender)"/>
            <Button x:Name="WatchdogRemoveButton" Content="Remove Watchdog" Margin="0,0,8,0"
                    Foreground="$($colors.Lavender)"/>
            <Button x:Name="ImportProfileButton" Content="Import Profile" Margin="0,0,8,0"
                    Foreground="$($colors.Mauve)"/>
            <Button x:Name="ExportProfileButton" Content="Export Profile" Margin="0,0,8,0"
                    Foreground="$($colors.Mauve)"/>
            <Button x:Name="SaveJsonButton" Content="Save JSON Status" Margin="0,0,0,0"
                    Foreground="$($colors.Yellow)"/>
        </WrapPanel>

        <!-- Diagnostics -->
        <Border Grid.Row="4" Background="$($colors.Mantle)" CornerRadius="6"
                BorderBrush="$($colors.Surface0)" BorderThickness="1" Padding="10,8" Margin="0,0,0,10">
            <StackPanel>
                <StackPanel Orientation="Horizontal" Margin="0,0,0,6">
                    <TextBlock Text="WFP Trace" Foreground="$($colors.Peach)" FontSize="12"
                               FontWeight="SemiBold" VerticalAlignment="Center" Width="80"/>
                    <TextBlock Text="Mins:" Foreground="$($colors.Subtext0)" FontSize="12"
                               VerticalAlignment="Center" Margin="0,0,4,0"/>
                    <TextBox x:Name="TraceMinutesBox" Width="48" Text="10"/>
                    <TextBlock Text="Output:" Foreground="$($colors.Subtext0)" FontSize="12"
                               VerticalAlignment="Center" Margin="10,0,4,0"/>
                    <TextBox x:Name="TraceOutputBox" Width="200"/>
                    <Button x:Name="TraceBrowseButton" Content="..." Padding="8,4" Margin="4,0,0,0"/>
                    <Button x:Name="TraceStartButton" Content="Start Trace" Margin="8,0,0,0"
                            Foreground="$($colors.Peach)" Padding="12,4"/>
                </StackPanel>
                <StackPanel Orientation="Horizontal">
                    <TextBlock Text="Plumbing" Foreground="$($colors.Peach)" FontSize="12"
                               FontWeight="SemiBold" VerticalAlignment="Center" Width="80"/>
                    <TextBlock Text="App:" Foreground="$($colors.Subtext0)" FontSize="12"
                               VerticalAlignment="Center" Margin="0,0,4,0"/>
                    <TextBox x:Name="PlumbingAppBox" Width="100" Text="Premiere"/>
                    <TextBlock Text="Mins:" Foreground="$($colors.Subtext0)" FontSize="12"
                               VerticalAlignment="Center" Margin="10,0,4,0"/>
                    <TextBox x:Name="PlumbingMinutesBox" Width="48" Text="10"/>
                    <Button x:Name="PlumbingStartButton" Content="Start Test" Margin="8,0,0,0"
                            Foreground="$($colors.Peach)" Padding="12,4"/>
                </StackPanel>
            </StackPanel>
        </Border>

        <!-- Log output -->
        <Border Grid.Row="5" Background="$($colors.Crust)" CornerRadius="6"
                BorderBrush="$($colors.Surface0)" BorderThickness="1">
            <RichTextBox x:Name="LogBox" IsReadOnly="True" VerticalScrollBarVisibility="Auto"
                         Background="Transparent" Foreground="$($colors.Text)"
                         FontFamily="Cascadia Mono,Consolas,Courier New" FontSize="12"
                         BorderThickness="0" Padding="8">
                <RichTextBox.Resources>
                    <Style TargetType="Paragraph">
                        <Setter Property="Margin" Value="0,1"/>
                    </Style>
                </RichTextBox.Resources>
            </RichTextBox>
        </Border>

        <!-- Status bar -->
        <Border Grid.Row="6" Background="$($colors.Mantle)" CornerRadius="4" Margin="0,8,0,0" Padding="10,6">
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <TextBlock x:Name="StatusText" Grid.Column="0" Text="Ready"
                           Foreground="$($colors.Subtext0)" FontSize="12" VerticalAlignment="Center"/>
                <TextBlock x:Name="VersionText" Grid.Column="1" Text="v2.4.1"
                           Foreground="$($colors.Surface2)" FontSize="11" VerticalAlignment="Center"/>
            </Grid>
        </Border>
    </Grid>
</Window>
"@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)

$logBox = $window.FindName('LogBox')
$statusText = $window.FindName('StatusText')
$runButton = $window.FindName('RunButton')
$statusButton = $window.FindName('StatusButton')
$undoButton = $window.FindName('UndoButton')
$connectionButton = $window.FindName('ConnectionButton')
$clearButton = $window.FindName('ClearButton')
$profileCombo = $window.FindName('ProfileCombo')
$dryRunCheck = $window.FindName('DryRunCheck')
$verboseCheck = $window.FindName('VerboseCheck')
$watchdogInstallButton = $window.FindName('WatchdogInstallButton')
$watchdogRemoveButton = $window.FindName('WatchdogRemoveButton')
$importProfileButton = $window.FindName('ImportProfileButton')
$exportProfileButton = $window.FindName('ExportProfileButton')
$saveJsonButton = $window.FindName('SaveJsonButton')
$traceMinutesBox = $window.FindName('TraceMinutesBox')
$traceOutputBox = $window.FindName('TraceOutputBox')
$traceBrowseButton = $window.FindName('TraceBrowseButton')
$traceStartButton = $window.FindName('TraceStartButton')
$plumbingAppBox = $window.FindName('PlumbingAppBox')
$plumbingMinutesBox = $window.FindName('PlumbingMinutesBox')
$plumbingStartButton = $window.FindName('PlumbingStartButton')

$colorMap = @{
    '[OK]'   = $colors.Green
    '[--]'   = $colors.Yellow
    '[!!'    = $colors.Red
    '[..]'   = $colors.Subtext0
    '[>>'    = $colors.Mauve
    '==='    = $colors.Blue
}

function Write-LogLine {
    param([string]$Text)
    $message = $Text
    $window.Dispatcher.Invoke([Action]{
        $doc = $logBox.Document
        $para = New-Object System.Windows.Documents.Paragraph
        $para.Margin = [System.Windows.Thickness]::new(0, 1, 0, 1)

        $fg = $colors.Text
        foreach ($key in $colorMap.Keys) {
            if ($message -match [regex]::Escape($key)) {
                $fg = $colorMap[$key]
                break
            }
        }

        $run = New-Object System.Windows.Documents.Run $message
        $run.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($fg)
        $para.Inlines.Add($run)
        $doc.Blocks.Add($para)
        $logBox.ScrollToEnd()
    })
}

function Set-UIEnabled {
    param([bool]$Enabled)
    $isEnabled = $Enabled
    $window.Dispatcher.Invoke([Action]{
        $runButton.IsEnabled = $isEnabled
        $statusButton.IsEnabled = $isEnabled
        $undoButton.IsEnabled = $isEnabled
        $connectionButton.IsEnabled = $isEnabled
        $watchdogInstallButton.IsEnabled = $isEnabled
        $watchdogRemoveButton.IsEnabled = $isEnabled
        $importProfileButton.IsEnabled = $isEnabled
        $exportProfileButton.IsEnabled = $isEnabled
        $saveJsonButton.IsEnabled = $isEnabled
        $traceStartButton.IsEnabled = $isEnabled
        $plumbingStartButton.IsEnabled = $isEnabled
    })
}

function Set-StatusText {
    param([string]$Text)
    $message = $Text
    $window.Dispatcher.Invoke([Action]{
        $statusText.Text = $message
    })
}

$scriptDir = Split-Path -Parent $PSCommandPath
$mainScript = Join-Path $scriptDir 'Disable-AdobeTelemetry.ps1'

# Thread-safe list of child powershell.exe PIDs so the window Closing handler can
# terminate any operation still running when the user closes the GUI.
$script:ActiveChildPids = [System.Collections.ArrayList]::Synchronized([System.Collections.ArrayList]::new())

function Invoke-ScriptAsync {
    param([string[]]$Arguments, [string]$StatusMsg, [string]$OutputFile)

    if (-not (Test-Path $mainScript)) {
        Write-LogLine "  [!!] Disable-AdobeTelemetry.ps1 not found in $scriptDir"
        return
    }

    Set-UIEnabled $false
    Set-StatusText $StatusMsg

    $runspace = [runspacefactory]::CreateRunspace()
    $runspace.ApartmentState = 'STA'
    $runspace.Open()
    $runspace.SessionStateProxy.SetVariable('mainScript', $mainScript)
    $runspace.SessionStateProxy.SetVariable('arguments', $Arguments)
    $runspace.SessionStateProxy.SetVariable('outputFile', $OutputFile)
    $runspace.SessionStateProxy.SetVariable('writeLogLine', ${function:Write-LogLine})
    $runspace.SessionStateProxy.SetVariable('setUIEnabled', ${function:Set-UIEnabled})
    $runspace.SessionStateProxy.SetVariable('setStatusText', ${function:Set-StatusText})
    $runspace.SessionStateProxy.SetVariable('activeChildPids', $script:ActiveChildPids)

    $ps = [powershell]::Create()
    $ps.Runspace = $runspace
    $ps.AddScript({
        try {
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = 'powershell.exe'
            $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$mainScript`" $($arguments -join ' ')"
            $psi.UseShellExecute = $false
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            $psi.CreateNoWindow = $true

            $process = [System.Diagnostics.Process]::Start($psi)
            [void]$activeChildPids.Add($process.Id)
            $capturedLines = [System.Collections.ArrayList]::new()
            $stderrTask = $process.StandardError.ReadToEndAsync()
            while (-not $process.StandardOutput.EndOfStream) {
                $line = $process.StandardOutput.ReadLine()
                if ($line) {
                    & $writeLogLine $line
                    [void]$capturedLines.Add($line)
                }
            }
            $process.WaitForExit()
            $errOut = $stderrTask.GetAwaiter().GetResult()
            if ($errOut) {
                foreach ($errLine in ($errOut -split "`n")) {
                    if ($errLine.Trim()) { & $writeLogLine "  [!!] $($errLine.Trim())" }
                }
            }

            if ($outputFile -and $capturedLines.Count -gt 0) {
                try {
                    ($capturedLines -join "`n") | Set-Content -Path $outputFile -Encoding UTF8 -Force
                    & $writeLogLine "  [OK] Output saved to $outputFile"
                } catch {
                    & $writeLogLine "  [!!] Failed to save output: $($_.Exception.Message)"
                }
            }

            & $setStatusText "Completed (exit code $($process.ExitCode))"
        } catch {
            & $writeLogLine "  [!!] Error: $($_.Exception.Message)"
            & $setStatusText 'Error'
        } finally {
            if ($process) { [void]$activeChildPids.Remove($process.Id) }
            & $setUIEnabled $true
        }
    }) | Out-Null

    [void]$ps.BeginInvoke()
    Register-ObjectEvent -InputObject $ps -EventName InvocationStateChanged -Action {
        if ($Sender.InvocationStateInfo.State -in 'Completed','Failed','Stopped') {
            $Sender.Dispose()
            $Sender.Runspace.Dispose()
        }
    } | Out-Null
}

function Get-SelectedProfile {
    $item = $profileCombo.SelectedItem
    if ($item) { return $item.Content } else { return 'Standard' }
}

function New-CommonArgs {
    $cmdArgs = @()
    $selectedProfile = Get-SelectedProfile
    if ($selectedProfile -ne 'Standard') { $cmdArgs += '-Profile'; $cmdArgs += $selectedProfile }
    if ($dryRunCheck.IsChecked) { $cmdArgs += '-DryRun' }
    if ($verboseCheck.IsChecked) { $cmdArgs += '-ShowRationale' }
    return $cmdArgs
}

# Primary actions
$runButton.Add_Click({
    $cmdArgs = New-CommonArgs
    Invoke-ScriptAsync -Arguments $cmdArgs -StatusMsg 'Applying protections...'
})

$statusButton.Add_Click({
    Invoke-ScriptAsync -Arguments @('-StatusOnly') -StatusMsg 'Checking status...'
})

$undoButton.Add_Click({
    Invoke-ScriptAsync -Arguments @('-Undo') -StatusMsg 'Undoing all changes...'
})

$connectionButton.Add_Click({
    Invoke-ScriptAsync -Arguments @('-ConnectionReport') -StatusMsg 'Scanning connections...'
})

$clearButton.Add_Click({
    $logBox.Document.Blocks.Clear()
    $statusText.Text = 'Ready'
})

# Watchdog
$watchdogInstallButton.Add_Click({
    Invoke-ScriptAsync -Arguments @('-InstallWatchdog') -StatusMsg 'Installing watchdog task...'
})

$watchdogRemoveButton.Add_Click({
    Invoke-ScriptAsync -Arguments @('-RemoveWatchdog') -StatusMsg 'Removing watchdog task...'
})

# Profile import/export
$importProfileButton.Add_Click({
    $dlg = New-Object Microsoft.Win32.OpenFileDialog
    $dlg.Title = 'Import Profile'
    $dlg.Filter = 'JSON files (*.json)|*.json|All files (*.*)|*.*'
    $dlg.DefaultExt = '.json'
    if ($dlg.ShowDialog($window)) {
        $cmdArgs = @('-ImportProfile', "`"$($dlg.FileName)`"")
        if ($dryRunCheck.IsChecked) { $cmdArgs += '-DryRun' }
        if ($verboseCheck.IsChecked) { $cmdArgs += '-ShowRationale' }
        Invoke-ScriptAsync -Arguments $cmdArgs -StatusMsg 'Importing profile...'
    }
})

$exportProfileButton.Add_Click({
    $dlg = New-Object Microsoft.Win32.SaveFileDialog
    $dlg.Title = 'Export Profile'
    $dlg.Filter = 'JSON files (*.json)|*.json|All files (*.*)|*.*'
    $dlg.DefaultExt = '.json'
    $dlg.FileName = "adobe-telemetry-$(Get-SelectedProfile).json"
    if ($dlg.ShowDialog($window)) {
        $cmdArgs = New-CommonArgs
        $cmdArgs += @('-ExportProfile', "`"$($dlg.FileName)`"")
        Invoke-ScriptAsync -Arguments $cmdArgs -StatusMsg 'Exporting profile...'
    }
})

# JSON status save
$saveJsonButton.Add_Click({
    $dlg = New-Object Microsoft.Win32.SaveFileDialog
    $dlg.Title = 'Save JSON Status'
    $dlg.Filter = 'JSON files (*.json)|*.json|All files (*.*)|*.*'
    $dlg.DefaultExt = '.json'
    $dlg.FileName = 'adobe-telemetry-status.json'
    if ($dlg.ShowDialog($window)) {
        Invoke-ScriptAsync -Arguments @('-StatusOnly', '-OutputFormat', 'JSON') `
                           -StatusMsg 'Saving JSON status...' `
                           -OutputFile $dlg.FileName
    }
})

# WFP Trace
$traceBrowseButton.Add_Click({
    $dlg = New-Object Microsoft.Win32.SaveFileDialog
    $dlg.Title = 'WFP Trace Output'
    $dlg.Filter = 'ETL files (*.etl)|*.etl|All files (*.*)|*.*'
    $dlg.DefaultExt = '.etl'
    $dlg.FileName = 'adobe-wfp-trace.etl'
    if ($dlg.ShowDialog($window)) {
        $traceOutputBox.Text = $dlg.FileName
    }
})

$traceStartButton.Add_Click({
    $minutes = $traceMinutesBox.Text
    if (-not ($minutes -match '^\d+$') -or [int]$minutes -lt 1 -or [int]$minutes -gt 1440) {
        Write-LogLine '  [!!] Trace minutes must be 1-1440'
        return
    }
    $cmdArgs = @('-WfpTrace', '-TraceMinutes', $minutes)
    $output = $traceOutputBox.Text.Trim()
    if ($output) { $cmdArgs += @('-TraceOutput', "`"$output`"") }
    Invoke-ScriptAsync -Arguments $cmdArgs -StatusMsg "Running WFP trace ($minutes min)..."
})

# Plumbing Test
$plumbingStartButton.Add_Click({
    $app = $plumbingAppBox.Text.Trim()
    $minutes = $plumbingMinutesBox.Text
    if (-not $app) {
        Write-LogLine '  [!!] Plumbing app name required'
        return
    }
    if (-not ($minutes -match '^\d+$') -or [int]$minutes -lt 1 -or [int]$minutes -gt 1440) {
        Write-LogLine '  [!!] Plumbing minutes must be 1-1440'
        return
    }
    Invoke-ScriptAsync -Arguments @('-PlumbingTest', '-PlumbingApp', "`"$app`"", '-PlumbingMinutes', $minutes) `
                       -StatusMsg "Running plumbing test ($app, $minutes min)..."
})

Write-LogLine "  Disable-AdobeTelemetry GUI v2.4.1"
Write-LogLine "  Script: $mainScript"
if (-not (Test-Path $mainScript)) {
    Write-LogLine "  [!!] Main script not found. Place this GUI alongside Disable-AdobeTelemetry.ps1."
}
Write-LogLine ""

# Kill any still-running child operation when the window closes, so an elevated
# powershell.exe is never orphaned after the GUI exits.
$window.Add_Closing({
    $pids = @($script:ActiveChildPids.ToArray())
    foreach ($childPid in $pids) {
        try {
            $proc = Get-Process -Id $childPid -ErrorAction SilentlyContinue
            if ($proc) { Stop-Process -Id $childPid -Force -ErrorAction SilentlyContinue }
        } catch { }
    }
})

$window.ShowDialog() | Out-Null
