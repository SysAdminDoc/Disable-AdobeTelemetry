<#
.SYNOPSIS
    Disable-AdobeTelemetry.GUI.ps1 - WPF companion GUI for Disable-AdobeTelemetry.
.DESCRIPTION
    Catppuccin Mocha themed GUI wrapper that invokes Disable-AdobeTelemetry.ps1
    with streaming log output. All operations run asynchronously to keep the UI responsive.
.NOTES
    Author  : Matt (Maven Imaging)
    Version : 2.3.5
    Date    : 2026-06-27
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
        Title="Disable-AdobeTelemetry v2.3.5"
        Width="780" Height="620"
        MinWidth="600" MinHeight="450"
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
    </Window.Resources>
    <Grid Margin="16">
        <Grid.RowDefinitions>
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

        <!-- Action buttons -->
        <WrapPanel Grid.Row="2" Margin="0,0,0,10">
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

        <!-- Log output -->
        <Border Grid.Row="3" Background="$($colors.Crust)" CornerRadius="6"
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
        <Border Grid.Row="4" Background="$($colors.Mantle)" CornerRadius="4" Margin="0,8,0,0" Padding="10,6">
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <TextBlock x:Name="StatusText" Grid.Column="0" Text="Ready"
                           Foreground="$($colors.Subtext0)" FontSize="12" VerticalAlignment="Center"/>
                <TextBlock x:Name="VersionText" Grid.Column="1" Text="v2.3.5"
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

function Invoke-ScriptAsync {
    param([string[]]$Arguments, [string]$StatusMsg)

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
    $runspace.SessionStateProxy.SetVariable('writeLogLine', ${function:Write-LogLine})
    $runspace.SessionStateProxy.SetVariable('setUIEnabled', ${function:Set-UIEnabled})
    $runspace.SessionStateProxy.SetVariable('setStatusText', ${function:Set-StatusText})

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
            while (-not $process.StandardOutput.EndOfStream) {
                $line = $process.StandardOutput.ReadLine()
                if ($line) { & $writeLogLine $line }
            }
            $errOut = $process.StandardError.ReadToEnd()
            if ($errOut) {
                foreach ($errLine in ($errOut -split "`n")) {
                    if ($errLine.Trim()) { & $writeLogLine "  [!!] $($errLine.Trim())" }
                }
            }
            $process.WaitForExit()
            & $setStatusText "Completed (exit code $($process.ExitCode))"
        } catch {
            & $writeLogLine "  [!!] Error: $($_.Exception.Message)"
            & $setStatusText 'Error'
        } finally {
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

Write-LogLine "  Disable-AdobeTelemetry GUI v2.3.5"
Write-LogLine "  Script: $mainScript"
Write-LogLine ""

$window.ShowDialog() | Out-Null
