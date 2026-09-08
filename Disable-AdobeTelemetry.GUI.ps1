<#
.SYNOPSIS
    Disable-AdobeTelemetry.GUI.ps1 - WPF companion GUI for Disable-AdobeTelemetry.
.DESCRIPTION
    Branded dark GUI wrapper that invokes Disable-AdobeTelemetry.ps1 with
    streaming log output. Operations run asynchronously to keep the interface responsive.
.NOTES
    Author  : SysAdminDoc
    Version : 2.5.3
    Date    : 2026-09-08
#>

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

$marketingCapture = $env:DISABLE_ADOBE_MARKETING_CAPTURE -eq '1'
if ($marketingCapture) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class DisableAdobeDpi {
    [DllImport("user32.dll")]
    public static extern bool SetProcessDPIAware();
}
'@
    [void][DisableAdobeDpi]::SetProcessDPIAware()
}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)
if (-not $isAdmin -and -not $marketingCapture) {
    Start-Process powershell.exe -Verb RunAs -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`""
    )
    exit 0
}

# Brand palette
$colors = @{
    Base     = '#07101F'
    Mantle   = '#0D1728'
    Crust    = '#050A13'
    Surface0 = '#14213A'
    Surface1 = '#203252'
    Surface2 = '#365071'
    Text     = '#EEF4FF'
    Subtext0 = '#91A4C3'
    Subtext1 = '#B6C4DA'
    Green    = '#55D6A7'
    Red      = '#FF6B5E'
    Yellow   = '#F3C969'
    Blue     = '#20D7F2'
    Mauve    = '#B8A5FF'
    Teal     = '#63E6D1'
    Peach    = '#FF9E64'
    Lavender = '#9DB8FF'
}

$scriptDir = Split-Path -Parent $PSCommandPath
$mainScript = Join-Path $scriptDir 'Disable-AdobeTelemetry.ps1'
$logoSource = Join-Path $scriptDir 'branding\logo.png'
if (-not (Test-Path -LiteralPath $logoSource)) { $logoSource = '' }
$iconSource = Join-Path $scriptDir 'branding\logo.ico'

[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Disable Adobe Telemetry v2.5.3"
        Width="1280" Height="800"
        MinWidth="1080" MinHeight="720"
        Background="$($colors.Base)"
        FontFamily="Segoe UI"
        UseLayoutRounding="True"
        SnapsToDevicePixels="True"
        WindowStartupLocation="CenterScreen">
    <Window.Resources>
        <Style TargetType="Button">
            <Setter Property="Background" Value="$($colors.Surface0)"/>
            <Setter Property="Foreground" Value="$($colors.Text)"/>
            <Setter Property="BorderBrush" Value="$($colors.Surface1)"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding" Value="14,8"/>
            <Setter Property="FontSize" Value="13"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="MinHeight" Value="38"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="border" Background="{TemplateBinding Background}"
                                BorderBrush="{TemplateBinding BorderBrush}"
                                BorderThickness="{TemplateBinding BorderThickness}"
                                CornerRadius="8" Padding="{TemplateBinding Padding}">
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
        <Style x:Key="PrimaryButton" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
            <Setter Property="Background" Value="$($colors.Blue)"/>
            <Setter Property="Foreground" Value="#03131A"/>
            <Setter Property="BorderBrush" Value="$($colors.Blue)"/>
            <Setter Property="MinHeight" Value="44"/>
            <Setter Property="FontSize" Value="14"/>
        </Style>
        <Style x:Key="DangerButton" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
            <Setter Property="Foreground" Value="$($colors.Red)"/>
            <Setter Property="BorderBrush" Value="#6B3540"/>
        </Style>
        <Style x:Key="QuietButton" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
            <Setter Property="Foreground" Value="$($colors.Subtext1)"/>
            <Setter Property="Background" Value="Transparent"/>
        </Style>
        <Style x:Key="CompactButton" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
            <Setter Property="MinHeight" Value="32"/>
            <Setter Property="FontSize" Value="11.5"/>
            <Setter Property="Padding" Value="8,6"/>
        </Style>
        <Style TargetType="ComboBox">
            <Setter Property="Background" Value="$($colors.Surface0)"/>
            <Setter Property="Foreground" Value="$($colors.Text)"/>
            <Setter Property="BorderBrush" Value="$($colors.Surface1)"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="FontSize" Value="13"/>
            <Setter Property="MinHeight" Value="42"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ComboBox">
                        <Grid>
                            <ToggleButton x:Name="DropDownToggle" Focusable="False" ClickMode="Press"
                                          Background="{TemplateBinding Background}"
                                          BorderBrush="{TemplateBinding BorderBrush}"
                                          BorderThickness="{TemplateBinding BorderThickness}"
                                          IsChecked="{Binding IsDropDownOpen, RelativeSource={RelativeSource TemplatedParent}, Mode=TwoWay}">
                                <ToggleButton.Template>
                                    <ControlTemplate TargetType="ToggleButton">
                                        <Border x:Name="comboBorder" Background="{TemplateBinding Background}"
                                                BorderBrush="{TemplateBinding BorderBrush}"
                                                BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="8">
                                            <Path Data="M 0 0 L 5 5 L 10 0 Z" Fill="$($colors.Subtext1)"
                                                  Width="10" Height="5" HorizontalAlignment="Right"
                                                  VerticalAlignment="Center" Margin="0,0,14,0"/>
                                        </Border>
                                    </ControlTemplate>
                                </ToggleButton.Template>
                            </ToggleButton>
                            <ContentPresenter Margin="14,0,38,0" VerticalAlignment="Center"
                                              HorizontalAlignment="Left" IsHitTestVisible="False"
                                              Content="{TemplateBinding SelectionBoxItem}"/>
                            <Popup x:Name="PART_Popup" Placement="Bottom" AllowsTransparency="True"
                                   Focusable="False" IsOpen="{TemplateBinding IsDropDownOpen}" PopupAnimation="Fade">
                                <Border Background="$($colors.Mantle)" BorderBrush="$($colors.Surface1)"
                                        BorderThickness="1" CornerRadius="8" Margin="0,4,0,0"
                                        MinWidth="{TemplateBinding ActualWidth}">
                                    <ScrollViewer MaxHeight="240">
                                        <StackPanel IsItemsHost="True"/>
                                    </ScrollViewer>
                                </Border>
                            </Popup>
                        </Grid>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style TargetType="ComboBoxItem">
            <Setter Property="Foreground" Value="$($colors.Text)"/>
            <Setter Property="Background" Value="$($colors.Mantle)"/>
            <Setter Property="Padding" Value="14,9"/>
            <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
            <Style.Triggers>
                <Trigger Property="IsHighlighted" Value="True">
                    <Setter Property="Background" Value="$($colors.Surface1)"/>
                </Trigger>
                <Trigger Property="IsSelected" Value="True">
                    <Setter Property="Foreground" Value="$($colors.Blue)"/>
                </Trigger>
            </Style.Triggers>
        </Style>
        <Style TargetType="CheckBox">
            <Setter Property="Foreground" Value="$($colors.Text)"/>
            <Setter Property="FontSize" Value="13"/>
            <Setter Property="Margin" Value="0,3"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="CheckBox">
                        <Grid>
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="22"/>
                                <ColumnDefinition Width="*"/>
                            </Grid.ColumnDefinitions>
                            <Border x:Name="checkBox" Width="17" Height="17" CornerRadius="4"
                                    Background="$($colors.Surface0)" BorderBrush="$($colors.Surface2)"
                                    BorderThickness="1" VerticalAlignment="Center">
                                <Path x:Name="checkMark" Data="M 2 8 L 6 12 L 14 3" Stroke="#03131A"
                                      StrokeThickness="2.2" Visibility="Collapsed"/>
                            </Border>
                            <ContentPresenter Grid.Column="1" Margin="8,0,0,0" VerticalAlignment="Center"/>
                        </Grid>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsChecked" Value="True">
                                <Setter TargetName="checkBox" Property="Background" Value="$($colors.Blue)"/>
                                <Setter TargetName="checkBox" Property="BorderBrush" Value="$($colors.Blue)"/>
                                <Setter TargetName="checkMark" Property="Visibility" Value="Visible"/>
                            </Trigger>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="checkBox" Property="BorderBrush" Value="$($colors.Blue)"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style TargetType="TextBox">
            <Setter Property="Background" Value="$($colors.Surface0)"/>
            <Setter Property="Foreground" Value="$($colors.Text)"/>
            <Setter Property="BorderBrush" Value="$($colors.Surface1)"/>
            <Setter Property="CaretBrush" Value="$($colors.Text)"/>
            <Setter Property="FontSize" Value="13"/>
            <Setter Property="Padding" Value="9,6"/>
            <Setter Property="VerticalContentAlignment" Value="Center"/>
        </Style>
    </Window.Resources>
    <Grid x:Name="CaptureRoot" Background="$($colors.Base)">
    <Grid x:Name="AppSurface" Margin="22">
        <Grid.RowDefinitions>
            <RowDefinition Height="108"/>
            <RowDefinition Height="14"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="12"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <Border Grid.Row="0" Background="$($colors.Mantle)" CornerRadius="16"
                BorderBrush="$($colors.Surface0)" BorderThickness="1" Padding="18,14">
            <Grid>
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="80"/>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="390"/>
            </Grid.ColumnDefinitions>
            <Image Grid.Column="0" Source="$logoSource" Width="68" Height="68" Stretch="Uniform"/>
            <StackPanel Grid.Column="1" VerticalAlignment="Center" Margin="12,0,20,0">
                <TextBlock Text="Disable Adobe Telemetry" FontSize="28" FontWeight="SemiBold"
                           Foreground="$($colors.Text)"/>
                <TextBlock Text="Keep the tools. Cut the tracking." FontSize="15"
                           Foreground="$($colors.Subtext1)" Margin="0,5,0,0"/>
            </StackPanel>
            <UniformGrid Grid.Column="2" Rows="1" Columns="4" Margin="6,3,0,3">
                <Border Background="$($colors.Surface0)" CornerRadius="8" Margin="4" Padding="10,9">
                    <StackPanel VerticalAlignment="Center"><TextBlock Text="60" FontSize="18" FontWeight="Bold" Foreground="$($colors.Blue)"/><TextBlock Text="DOMAINS" FontSize="9" Foreground="$($colors.Subtext0)"/></StackPanel>
                </Border>
                <Border Background="$($colors.Surface0)" CornerRadius="8" Margin="4" Padding="10,9">
                    <StackPanel VerticalAlignment="Center"><TextBlock Text="11" FontSize="18" FontWeight="Bold" Foreground="$($colors.Blue)"/><TextBlock Text="PHASES" FontSize="9" Foreground="$($colors.Subtext0)"/></StackPanel>
                </Border>
                <Border Background="$($colors.Surface0)" CornerRadius="8" Margin="4" Padding="10,9">
                    <StackPanel VerticalAlignment="Center"><TextBlock Text="UNDO" FontSize="15" FontWeight="Bold" Foreground="$($colors.Green)"/><TextBlock Text="MANIFEST" FontSize="9" Foreground="$($colors.Subtext0)"/></StackPanel>
                </Border>
                <Border Background="$($colors.Surface0)" CornerRadius="8" Margin="4" Padding="10,9">
                    <StackPanel VerticalAlignment="Center"><TextBlock Text="LOCAL" FontSize="15" FontWeight="Bold" Foreground="$($colors.Green)"/><TextBlock Text="NO ACCOUNT" FontSize="9" Foreground="$($colors.Subtext0)"/></StackPanel>
                </Border>
            </UniformGrid>
            </Grid>
        </Border>

        <Grid Grid.Row="2">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="408"/>
                <ColumnDefinition Width="14"/>
                <ColumnDefinition Width="*"/>
            </Grid.ColumnDefinitions>

            <Grid Grid.Column="0">
                <Grid.RowDefinitions>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="12"/>
                    <RowDefinition Height="*"/>
                </Grid.RowDefinitions>
                <Border Grid.Row="0" Background="$($colors.Mantle)" CornerRadius="14"
                        BorderBrush="$($colors.Surface0)" BorderThickness="1" Padding="18">
                    <StackPanel>
                        <TextBlock Text="Protection setup" FontSize="17" FontWeight="SemiBold" Foreground="$($colors.Text)"/>
                        <TextBlock Text="Choose how far the controls should reach." FontSize="12"
                                   Foreground="$($colors.Subtext0)" Margin="0,3,0,14"/>
                        <TextBlock Text="PROFILE" FontSize="10" FontWeight="Bold" Foreground="$($colors.Subtext0)" Margin="0,0,0,6"/>
                        <ComboBox x:Name="ProfileCombo">
                            <ComboBoxItem Content="Minimal"/>
                            <ComboBoxItem Content="Standard" IsSelected="True"/>
                            <ComboBoxItem Content="Aggressive"/>
                        </ComboBox>
                        <TextBlock Text="Standard targets 60 domains. Connected Adobe features can be affected."
                                   TextWrapping="Wrap" FontSize="11" Foreground="$($colors.Subtext0)" Margin="0,7,0,9"/>
                        <CheckBox x:Name="DryRunCheck" Content="Preview changes only"/>
                        <CheckBox x:Name="VerboseCheck" Content="Show the reason for each action"/>
                        <CheckBox x:Name="LockHostsCheck" Content="Protect the hosts file from SYSTEM writes"/>
                        <CheckBox x:Name="AllUsersCheck" Content="Apply registry policy to every user profile"/>
                        <Button x:Name="RunButton" Content="Apply protections" Style="{StaticResource PrimaryButton}" Margin="0,12,0,0"/>
                        <Grid Margin="0,8,0,0">
                            <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="8"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                            <Button x:Name="StatusButton" Grid.Column="0" Content="Status check" MinHeight="34"/>
                            <Button x:Name="UndoButton" Grid.Column="2" Content="Undo changes" Style="{StaticResource DangerButton}" MinHeight="34"/>
                        </Grid>
                    </StackPanel>
                </Border>

                <Border Grid.Row="2" Background="$($colors.Mantle)" CornerRadius="14"
                        BorderBrush="$($colors.Surface0)" BorderThickness="1" Padding="14">
                    <StackPanel>
                        <TextBlock Text="Operations" FontSize="17" FontWeight="SemiBold" Foreground="$($colors.Text)"/>
                        <TextBlock Text="Reports, recovery, and fleet-ready exports." FontSize="12"
                                   Foreground="$($colors.Subtext0)" Margin="0,3,0,8"/>
                        <Grid>
                            <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="8"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                            <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="6"/><RowDefinition Height="Auto"/><RowDefinition Height="6"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                            <Button x:Name="ConnectionButton" Grid.Row="0" Grid.Column="0" Content="Connection report" Style="{StaticResource CompactButton}" Foreground="$($colors.Teal)"/>
                            <Button x:Name="SaveJsonButton" Grid.Row="0" Grid.Column="2" Content="Save status JSON" Style="{StaticResource CompactButton}" Foreground="$($colors.Yellow)"/>
                            <Button x:Name="WatchdogInstallButton" Grid.Row="2" Grid.Column="0" Content="Install watchdog" Style="{StaticResource CompactButton}" Foreground="$($colors.Lavender)"/>
                            <Button x:Name="WatchdogRemoveButton" Grid.Row="2" Grid.Column="2" Content="Remove watchdog" Style="{StaticResource CompactButton}" Foreground="$($colors.Lavender)"/>
                            <Button x:Name="ImportProfileButton" Grid.Row="4" Grid.Column="0" Content="Import profile" Style="{StaticResource CompactButton}" Foreground="$($colors.Mauve)"/>
                            <Button x:Name="ExportProfileButton" Grid.Row="4" Grid.Column="2" Content="Export profile" Style="{StaticResource CompactButton}" Foreground="$($colors.Mauve)"/>
                        </Grid>
                    </StackPanel>
                </Border>
            </Grid>

            <Grid Grid.Column="2">
                <Grid.RowDefinitions><RowDefinition Height="*"/><RowDefinition Height="12"/><RowDefinition Height="176"/></Grid.RowDefinitions>
                <Border Grid.Row="0" Background="$($colors.Mantle)" CornerRadius="14"
                        BorderBrush="$($colors.Surface0)" BorderThickness="1" Padding="16">
                    <Grid>
                        <Grid.RowDefinitions><RowDefinition Height="42"/><RowDefinition Height="*"/></Grid.RowDefinitions>
                        <Grid Grid.Row="0">
                            <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                            <StackPanel>
                                <TextBlock Text="Activity" FontSize="17" FontWeight="SemiBold" Foreground="$($colors.Text)"/>
                                <TextBlock Text="Live output and verification details" FontSize="11" Foreground="$($colors.Subtext0)"/>
                            </StackPanel>
                            <Button x:Name="ClearButton" Grid.Column="1" Content="Clear log" Style="{StaticResource QuietButton}" MinHeight="30" Padding="11,5"/>
                        </Grid>
                        <Border Grid.Row="1" Background="$($colors.Crust)" CornerRadius="9"
                                BorderBrush="$($colors.Surface0)" BorderThickness="1">
                            <RichTextBox x:Name="LogBox" IsReadOnly="True" VerticalScrollBarVisibility="Auto"
                                         Background="Transparent" Foreground="$($colors.Text)"
                                         FontFamily="Cascadia Mono,Consolas,Courier New" FontSize="12"
                                         BorderThickness="0" Padding="12">
                                <RichTextBox.Resources>
                                    <Style TargetType="Paragraph"><Setter Property="Margin" Value="0,2"/></Style>
                                </RichTextBox.Resources>
                            </RichTextBox>
                        </Border>
                    </Grid>
                </Border>

                <Border Grid.Row="2" Background="$($colors.Mantle)" CornerRadius="14"
                        BorderBrush="$($colors.Surface0)" BorderThickness="1" Padding="16,13">
                    <Grid>
                        <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="10"/><RowDefinition Height="*"/></Grid.RowDefinitions>
                        <StackPanel Grid.Row="0">
                            <TextBlock Text="Network diagnostics" FontSize="16" FontWeight="SemiBold" Foreground="$($colors.Text)"/>
                            <TextBlock Text="Capture blocked traffic or test one Adobe application." FontSize="11" Foreground="$($colors.Subtext0)"/>
                        </StackPanel>
                        <Grid Grid.Row="2">
                            <Grid.RowDefinitions><RowDefinition Height="42"/><RowDefinition Height="8"/><RowDefinition Height="42"/></Grid.RowDefinitions>
                            <Grid.ColumnDefinitions><ColumnDefinition Width="92"/><ColumnDefinition Width="74"/><ColumnDefinition Width="*"/><ColumnDefinition Width="44"/><ColumnDefinition Width="110"/></Grid.ColumnDefinitions>
                            <TextBlock Grid.Row="0" Grid.Column="0" Text="WFP trace" Foreground="$($colors.Peach)" FontWeight="SemiBold" VerticalAlignment="Center"/>
                            <TextBox x:Name="TraceMinutesBox" Grid.Row="0" Grid.Column="1" Text="10" ToolTip="Minutes" Margin="0,0,8,0"/>
                            <TextBox x:Name="TraceOutputBox" Grid.Row="0" Grid.Column="2" ToolTip="Optional output file"/>
                            <Button x:Name="TraceBrowseButton" Grid.Row="0" Grid.Column="3" Content="..." Margin="6,0,0,0" Padding="5"/>
                            <Button x:Name="TraceStartButton" Grid.Row="0" Grid.Column="4" Content="Start trace" Foreground="$($colors.Peach)" Margin="8,0,0,0"/>
                            <TextBlock Grid.Row="2" Grid.Column="0" Text="App test" Foreground="$($colors.Peach)" FontWeight="SemiBold" VerticalAlignment="Center"/>
                            <TextBox x:Name="PlumbingMinutesBox" Grid.Row="2" Grid.Column="1" Text="10" ToolTip="Minutes" Margin="0,0,8,0"/>
                            <TextBox x:Name="PlumbingAppBox" Grid.Row="2" Grid.Column="2" Text="Premiere" ToolTip="Adobe application name"/>
                            <Button x:Name="PlumbingStartButton" Grid.Row="2" Grid.Column="4" Content="Start test" Foreground="$($colors.Peach)" Margin="8,0,0,0"/>
                        </Grid>
                    </Grid>
                </Border>
            </Grid>
        </Grid>

        <Border Grid.Row="4" Background="$($colors.Mantle)" CornerRadius="9" Padding="12,8"
                BorderBrush="$($colors.Surface0)" BorderThickness="1">
            <StackPanel>
                <ProgressBar x:Name="BusyBar" Height="3" IsIndeterminate="True" Visibility="Collapsed"
                             Margin="0,0,0,6" Background="Transparent" Foreground="$($colors.Blue)" BorderThickness="0"/>
                <Grid>
                    <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                    <TextBlock x:Name="StatusText" Grid.Column="0" Text="Ready" Foreground="$($colors.Green)" FontSize="12" VerticalAlignment="Center"/>
                    <TextBlock x:Name="UpdateText" Grid.Column="1" Text="" Margin="0,0,14,0" Foreground="$($colors.Yellow)" FontSize="11" VerticalAlignment="Center"/>
                    <TextBlock x:Name="VersionText" Grid.Column="2" Text="v2.5.3" Foreground="$($colors.Subtext0)" FontSize="11" VerticalAlignment="Center"/>
                </Grid>
            </StackPanel>
        </Border>
    </Grid>
    </Grid>
</Window>
"@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)
if (Test-Path -LiteralPath $iconSource) {
    $window.Icon = [System.Windows.Media.Imaging.BitmapFrame]::Create([uri]$iconSource)
}

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
$lockHostsCheck = $window.FindName('LockHostsCheck')
$allUsersCheck = $window.FindName('AllUsersCheck')
$busyBar = $window.FindName('BusyBar')
$updateText = $window.FindName('UpdateText')
$versionText = $window.FindName('VersionText')
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
        # Indeterminate progress bar is visible only while an operation runs
        $busyBar.Visibility = if ($isEnabled) { 'Collapsed' } else { 'Visible' }
    })
}

function Set-StatusText {
    param([string]$Text)
    $message = $Text
    $window.Dispatcher.Invoke([Action]{
        $statusText.Text = $message
    })
}

# Thread-safe list of child powershell.exe PIDs so the window Closing handler can
# terminate any operation still running when the user closes the GUI.
$script:ActiveChildPids = [System.Collections.ArrayList]::Synchronized([System.Collections.ArrayList]::new())

function Invoke-ScriptAsync {
    param([string[]]$Arguments, [string]$StatusMsg, [string]$OutputFile)

    if ($marketingCapture) { throw 'Protection commands are disabled in sample capture mode.' }
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
    if ($lockHostsCheck.IsChecked) { $cmdArgs += '-LockHostsFile' }
    if ($allUsersCheck.IsChecked) { $cmdArgs += '-AllUsers' }
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
    Invoke-ScriptAsync -Arguments @('-Undo') -StatusMsg 'Undoing recorded changes...'
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

Write-LogLine "  Disable Adobe Telemetry GUI v2.5.3"
Write-LogLine "  [OK] Ready to protect this PC."
Write-LogLine "  [..] Standard covers 60 telemetry endpoints across 11 protection phases."
Write-LogLine "  [..] Run Status check first, or enable Preview changes only before applying."
if (-not (Test-Path $mainScript)) {
    Write-LogLine "  [!!] Main script not found. Place this GUI alongside Disable-AdobeTelemetry.ps1."
}

# Surface an "update available" label from the CLI's update-check cache (best-effort)
try {
    $updCache = Join-Path $env:APPDATA 'Disable-AdobeTelemetry\update-check.json'
    if (-not $marketingCapture -and (Test-Path $updCache)) {
        $u = Get-Content $updCache -Raw | ConvertFrom-Json
        if ($u.LatestTag) {
            $latest = ($u.LatestTag -replace '^v', '')
            $cur = ($versionText.Text -replace '^v', '')
            if ([version]$latest -gt [version]$cur) {
                $updateText.Text = "Update available: $($u.LatestTag)"
            }
        }
    }
} catch { }

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

function Set-MarketingCaptureState {
    param([string]$View)

    $logBox.Document.Blocks.Clear()
    $profileCombo.SelectedIndex = 1
    $dryRunCheck.IsChecked = $false
    $verboseCheck.IsChecked = $false
    $lockHostsCheck.IsChecked = $false
    $allUsersCheck.IsChecked = $false

    switch ($View.ToLowerInvariant()) {
        'status' {
            $statusText.Text = 'Sample status. No system inspection.'
            Write-LogLine '  === Sample protection status'
            Write-LogLine '  [OK] Hosts block: all 60 Standard endpoints are present'
            Write-LogLine '  [OK] Firewall: Adobe telemetry rules are active'
            Write-LogLine '  [OK] Registry: usage data policies are applied'
            Write-LogLine '  [OK] GrowthSDK blocker is in place'
            Write-LogLine '  [--] Weekly watchdog is not installed'
            Write-LogLine '  [..] Illustrative results. No system scan or changes.'
        }
        'dry-run' {
            $dryRunCheck.IsChecked = $true
            $verboseCheck.IsChecked = $true
            $statusText.Text = 'Sample preview. No system changes.'
            Write-LogLine '  === Sample Standard profile preview'
            Write-LogLine '  [..] Would stop Adobe background telemetry processes'
            Write-LogLine '  [..] Would neutralize GrowthSDK and persistent launch points'
            Write-LogLine '  [..] Would apply 60 firewall and hosts protections'
            Write-LogLine '  [..] Would set usage-data registry policies'
            Write-LogLine '  [OK] Preview finished. No system changes were made.'
        }
        default {
            $statusText.Text = 'Ready (sample view)'
            Write-LogLine '  Disable Adobe Telemetry GUI v2.5.3'
            Write-LogLine '  [OK] Ready to protect this PC.'
            Write-LogLine '  [..] Standard covers 60 telemetry endpoints across 11 protection phases.'
            Write-LogLine '  [..] Run Status check first, or enable Preview changes only before applying.'
            Write-LogLine '  [..] Sample view. No system scan or changes.'
        }
    }
}

function Export-MarketingCapture {
    param([Parameter(Mandatory)][string]$OutputPath)

    $targetDirectory = Split-Path -Parent $OutputPath
    if (-not (Test-Path -LiteralPath $targetDirectory)) {
        New-Item -ItemType Directory -Path $targetDirectory -Force | Out-Null
    }

    $captureRoot = $window.FindName('CaptureRoot')
    $captureSize = [System.Windows.Size]::new(1280, 800)
    $captureRoot.Measure($captureSize)
    $captureRoot.Arrange([System.Windows.Rect]::new(0, 0, 1280, 800))
    $captureRoot.UpdateLayout()

    $bitmap = [System.Windows.Media.Imaging.RenderTargetBitmap]::new(
        1600, 1000, 120, 120, [System.Windows.Media.PixelFormats]::Pbgra32
    )
    $bitmap.Render($captureRoot)
    $encoder = [System.Windows.Media.Imaging.PngBitmapEncoder]::new()
    $encoder.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
    $stream = [System.IO.File]::Open($OutputPath, [System.IO.FileMode]::Create)
    try { $encoder.Save($stream) } finally { $stream.Dispose() }
}

if ($marketingCapture) {
    $captureView = if ($env:DISABLE_ADOBE_MARKETING_VIEW) { $env:DISABLE_ADOBE_MARKETING_VIEW } else { 'overview' }
    $captureOutput = $env:DISABLE_ADOBE_MARKETING_OUTPUT
    if (-not $captureOutput) { throw 'DISABLE_ADOBE_MARKETING_OUTPUT is required in capture mode.' }
    Set-MarketingCaptureState -View $captureView
    Export-MarketingCapture -OutputPath $captureOutput
    return
}

$window.ShowDialog() | Out-Null
