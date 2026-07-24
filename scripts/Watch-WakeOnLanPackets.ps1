#Requires -Version 5.1
<#
.SYNOPSIS
    Watches for Wake-on-LAN traffic on UDP ports 7 and 9.

.DESCRIPTION
    Stops any existing Pktmon capture, replaces the current Pktmon filters with
    UDP port 7 and 9 filters, and starts a NIC-only real-time capture. A popup
    polls the redirected Pktmon stream and adds each received UDP packet summary
    to a live table.

    Closing the popup stops Pktmon and removes its packet filters. Because
    Pktmon filters and capture sessions are machine-wide, this script requires
    administrator rights and replaces any existing Pktmon session and filters.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml

Add-Type -TypeDefinition @'
using System;
using System.Collections.Concurrent;
using System.Diagnostics;

public sealed class ScriptBoxLineCapture : IDisposable
{
    private readonly ConcurrentQueue<string> lines = new ConcurrentQueue<string>();
    private Process process;

    public void Start(string fileName, string arguments)
    {
        if (process != null)
        {
            throw new InvalidOperationException("The capture process has already been started.");
        }

        process = new Process();
        process.StartInfo = new ProcessStartInfo
        {
            FileName = fileName,
            Arguments = arguments,
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true,
            WindowStyle = ProcessWindowStyle.Hidden
        };
        process.OutputDataReceived += delegate(object sender, DataReceivedEventArgs args)
        {
            if (!String.IsNullOrWhiteSpace(args.Data))
            {
                lines.Enqueue(args.Data);
            }
        };
        process.ErrorDataReceived += delegate(object sender, DataReceivedEventArgs args)
        {
            if (!String.IsNullOrWhiteSpace(args.Data))
            {
                lines.Enqueue("ERROR: " + args.Data);
            }
        };

        if (!process.Start())
        {
            throw new InvalidOperationException("Pktmon did not start.");
        }
        process.BeginOutputReadLine();
        process.BeginErrorReadLine();
    }

    public bool IsRunning
    {
        get
        {
            return process != null && !process.HasExited;
        }
    }

    public int ExitCode
    {
        get
        {
            return process == null || !process.HasExited ? -1 : process.ExitCode;
        }
    }

    public bool TryDequeue(out string line)
    {
        return lines.TryDequeue(out line);
    }

    public bool WaitForExit(int milliseconds)
    {
        return process == null || process.HasExited || process.WaitForExit(milliseconds);
    }

    public void Kill()
    {
        if (process != null && !process.HasExited)
        {
            process.Kill();
        }
    }

    public void Dispose()
    {
        if (process != null)
        {
            process.Dispose();
            process = null;
        }
    }
}
'@

function Assert-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)

    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'The Wake-on-LAN packet watcher must be run with administrator rights.'
    }
}

function Invoke-PktmonCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PktmonPath,

        [Parameter(Mandatory = $true)]
        [string]$Arguments,

        [switch]$IgnoreExitCode
    )

    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = $PktmonPath
    $startInfo.Arguments = $Arguments
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true
    $startInfo.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden

    $process = New-Object Diagnostics.Process
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) {
            throw "Pktmon did not start for: $Arguments"
        }
        $standardOutput = $process.StandardOutput.ReadToEnd()
        $standardError = $process.StandardError.ReadToEnd()
        $process.WaitForExit()
        $combinedOutput = @($standardOutput, $standardError) -join [Environment]::NewLine

        if ($process.ExitCode -ne 0 -and -not $IgnoreExitCode) {
            $detail = $combinedOutput.Trim()
            if ([string]::IsNullOrWhiteSpace($detail)) {
                $detail = "exit code $($process.ExitCode)"
            }
            throw "Pktmon command '$Arguments' failed: $detail"
        }

        return $combinedOutput.Trim()
    }
    finally {
        $process.Dispose()
    }
}

function Get-WolPortFromLine {
    param([string]$Line)

    $portMatch = [regex]::Match($Line, '(?:[.:])(?<port>7|9)(?=[:\s>])')
    if ($portMatch.Success) {
        return $portMatch.Groups['port'].Value
    }

    return '7 or 9'
}

function Test-WolPacketLine {
    param([string]$Line)

    if ($Line -notmatch '(?i)\bUDP\b') {
        return $false
    }

    return $Line -match '(?i)\b(?:Packet|Drop):' -or
        $Line -match '(?:[.:])(?:7|9)(?=[:\s>])'
}

$capture = $null
$timer = $null
$filtersReplaced = $false
$completed = $false

try {
    Assert-Administrator

    $pktmonCommand = Get-Command -Name 'pktmon.exe' -ErrorAction SilentlyContinue
    if ($null -eq $pktmonCommand) {
        throw 'Pktmon is not available on this version of Windows.'
    }
    $pktmonPath = $pktmonCommand.Source

    $null = Invoke-PktmonCommand -PktmonPath $pktmonPath -Arguments 'stop' -IgnoreExitCode
    $null = Invoke-PktmonCommand -PktmonPath $pktmonPath -Arguments 'filter remove'
    $filtersReplaced = $true
    $null = Invoke-PktmonCommand -PktmonPath $pktmonPath -Arguments 'filter add WOL-Port-7 -t UDP -p 7'
    $null = Invoke-PktmonCommand -PktmonPath $pktmonPath -Arguments 'filter add WOL-Port-9 -t UDP -p 9'

    $capture = New-Object ScriptBoxLineCapture
    $capture.Start(
        $pktmonPath,
        'start --capture --comp nics --pkt-size 0 --log-mode real-time'
    )

    Start-Sleep -Milliseconds 250
    if (-not $capture.IsRunning) {
        $startupLines = New-Object System.Collections.Generic.List[string]
        $startupLine = $null
        while ($capture.TryDequeue([ref]$startupLine)) {
            $startupLines.Add($startupLine)
            $startupLine = $null
        }
        $startupDetail = ($startupLines -join [Environment]::NewLine).Trim()
        if ([string]::IsNullOrWhiteSpace($startupDetail)) {
            $startupDetail = "Pktmon exited with code $($capture.ExitCode)."
        }
        throw "The real-time Pktmon capture did not remain running: $startupDetail"
    }

    $xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Wake-on-LAN Packet Watcher" Width="1080" Height="670"
        MinWidth="760" MinHeight="500" WindowStartupLocation="CenterScreen"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        Foreground="#F8FAFC" FontFamily="Segoe UI" ResizeMode="CanResizeWithGrip"
        Topmost="True" UseLayoutRounding="True">
    <Window.Resources>
        <Style x:Key="ActionButton" TargetType="Button">
            <Setter Property="Height" Value="38"/>
            <Setter Property="Padding" Value="18,7"/>
            <Setter Property="Foreground" Value="#F8FAFC"/>
            <Setter Property="Background" Value="#151D35"/>
            <Setter Property="BorderBrush" Value="#334263"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="Cursor" Value="Hand"/>
        </Style>
        <Style x:Key="PacketCell" TargetType="TextBlock">
            <Setter Property="TextWrapping" Value="Wrap"/>
            <Setter Property="VerticalAlignment" Value="Center"/>
            <Setter Property="Padding" Value="5,8"/>
            <Setter Property="Foreground" Value="#E2E8F0"/>
            <Setter Property="LineHeight" Value="18"/>
        </Style>
        <Style TargetType="DataGridColumnHeader">
            <Setter Property="Background" Value="#171F3A"/>
            <Setter Property="Foreground" Value="#94A3B8"/>
            <Setter Property="BorderBrush" Value="#2D3760"/>
            <Setter Property="BorderThickness" Value="0,0,1,1"/>
            <Setter Property="Padding" Value="12,10"/>
            <Setter Property="FontSize" Value="10"/>
            <Setter Property="FontWeight" Value="Bold"/>
        </Style>
        <Style TargetType="DataGridRow">
            <Setter Property="Background" Value="#0F1629"/>
            <Setter Property="BorderBrush" Value="#202A48"/>
            <Setter Property="BorderThickness" Value="0,0,0,1"/>
            <Style.Triggers>
                <Trigger Property="AlternationIndex" Value="1">
                    <Setter Property="Background" Value="#111A30"/>
                </Trigger>
                <Trigger Property="IsSelected" Value="True">
                    <Setter Property="Background" Value="#25305A"/>
                </Trigger>
            </Style.Triggers>
        </Style>
        <Style TargetType="DataGridCell">
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
        </Style>
    </Window.Resources>
    <Border Background="#0B1020" BorderBrush="#34D399" BorderThickness="1" CornerRadius="15">
        <Border.Effect>
            <DropShadowEffect Color="#000000" BlurRadius="28" ShadowDepth="8" Opacity="0.65"/>
        </Border.Effect>
        <Grid>
            <Grid.RowDefinitions>
                <RowDefinition Height="54"/>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="*"/>
                <RowDefinition Height="68"/>
            </Grid.RowDefinitions>

            <Border x:Name="DragRegion" CornerRadius="14,14,0,0"
                    BorderBrush="#2D3760" BorderThickness="0,0,0,1">
                <Border.Background>
                    <LinearGradientBrush StartPoint="0,0" EndPoint="1,0">
                        <GradientStop Color="#171F3A" Offset="0"/>
                        <GradientStop Color="#12352F" Offset="1"/>
                    </LinearGradientBrush>
                </Border.Background>
                <Grid Margin="18,0,10,0">
                    <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                        <Ellipse x:Name="LiveDot" Width="8" Height="8"
                                 Fill="#34D399" Margin="0,0,10,0"/>
                        <TextBlock Text="SCRIPTBOX • WAKE-ON-LAN WATCHER"
                                   FontSize="11" FontWeight="Bold" Foreground="#E2E8F0"/>
                    </StackPanel>
                    <Button x:Name="CloseX" Content="×" Width="36" Height="32"
                            HorizontalAlignment="Right" Padding="0" FontSize="20"
                            Background="Transparent" BorderThickness="0" Foreground="#94A3B8"
                            Cursor="Hand"/>
                </Grid>
            </Border>

            <Grid Grid.Row="1" Margin="24,20,24,16">
                <StackPanel>
                    <TextBlock Text="Listening for WOL packets" FontSize="24"
                               FontWeight="Bold" Foreground="#F8FAFC"/>
                    <TextBlock Text="Live Pktmon capture on network adapters • UDP ports 7 and 9"
                               Margin="0,6,0,0" FontSize="12" Foreground="#94A3B8"/>
                    <TextBlock x:Name="LastActivity" Text="Waiting for the first matching packet…"
                               Margin="0,8,170,0" FontSize="11" Foreground="#64748B"
                               TextTrimming="CharacterEllipsis"/>
                </StackPanel>
                <Border HorizontalAlignment="Right" VerticalAlignment="Center"
                        Background="#102B2D" BorderBrush="#34D399"
                        BorderThickness="1" CornerRadius="12" Padding="16,8">
                    <StackPanel Orientation="Horizontal">
                        <TextBlock x:Name="PacketCount" Text="0" FontSize="18"
                                   FontWeight="Bold" Foreground="#6EE7B7"/>
                        <TextBlock Text=" DETECTED" Margin="6,4,0,0" FontSize="10"
                                   FontWeight="Bold" Foreground="#94A3B8"/>
                    </StackPanel>
                </Border>
            </Grid>

            <Grid Grid.Row="2" Margin="24,0,24,18">
                <Border Background="#0F1629" BorderBrush="#2D3760"
                        BorderThickness="1" CornerRadius="10">
                    <DataGrid x:Name="PacketGrid" Margin="1" Background="#0F1629"
                              Foreground="#E2E8F0" BorderThickness="0"
                              AutoGenerateColumns="False" IsReadOnly="True"
                              CanUserAddRows="False" CanUserDeleteRows="False"
                              CanUserReorderColumns="True" CanUserResizeColumns="True"
                              CanUserSortColumns="True" HeadersVisibility="Column"
                              GridLinesVisibility="None" RowHeaderWidth="0"
                              AlternationCount="2" SelectionMode="Single"
                              SelectionUnit="FullRow"
                              HorizontalScrollBarVisibility="Auto"
                              VerticalScrollBarVisibility="Auto">
                        <DataGrid.Columns>
                            <DataGridTextColumn Header="RECEIVED" Binding="{Binding Received}"
                                                Width="145" MinWidth="125"
                                                ElementStyle="{StaticResource PacketCell}"/>
                            <DataGridTextColumn Header="PORT" Binding="{Binding Port}"
                                                Width="95" MinWidth="80"
                                                ElementStyle="{StaticResource PacketCell}"/>
                            <DataGridTextColumn Header="PKTMON PACKET SUMMARY" Binding="{Binding Summary}"
                                                Width="*" MinWidth="430"
                                                ElementStyle="{StaticResource PacketCell}"/>
                        </DataGrid.Columns>
                    </DataGrid>
                </Border>
                <StackPanel x:Name="EmptyState" HorizontalAlignment="Center"
                            VerticalAlignment="Center">
                    <TextBlock Text="Watcher is active" FontSize="18"
                               FontWeight="SemiBold" Foreground="#CBD5E1"
                               TextAlignment="Center"/>
                    <TextBlock Margin="0,8,0,0"
                               Text="Matching UDP packet summaries will appear here as they arrive."
                               FontSize="12" Foreground="#64748B" TextAlignment="Center"/>
                </StackPanel>
            </Grid>

            <Border Grid.Row="3" Background="#090D1A" CornerRadius="0,0,14,14"
                    BorderBrush="#202A48" BorderThickness="0,1,0,0">
                <Grid Margin="24,0">
                    <StackPanel VerticalAlignment="Center">
                        <TextBlock x:Name="CaptureStatus" Text="● CAPTURE RUNNING"
                                   Foreground="#34D399" FontSize="11" FontWeight="Bold"/>
                        <TextBlock Text="Closing this window stops Pktmon and removes its filters."
                                   Margin="0,3,0,0" Foreground="#64748B" FontSize="10"/>
                    </StackPanel>
                    <StackPanel Orientation="Horizontal" HorizontalAlignment="Right"
                                VerticalAlignment="Center">
                        <Button x:Name="ClearButton" Content="CLEAR LIST"
                                Style="{StaticResource ActionButton}" Margin="0,0,10,0"/>
                        <Button x:Name="CloseButton" Content="STOP &amp; CLOSE"
                                Style="{StaticResource ActionButton}"
                                Background="#7C3AED" BorderBrush="#A855F7"/>
                    </StackPanel>
                </Grid>
            </Border>
        </Grid>
    </Border>
</Window>
'@

    [xml]$xml = $xaml
    $reader = New-Object System.Xml.XmlNodeReader($xml)
    $window = [Windows.Markup.XamlReader]::Load($reader)

    $packetRows = New-Object 'System.Collections.ObjectModel.ObservableCollection[object]'
    $packetGrid = $window.FindName('PacketGrid')
    $emptyState = $window.FindName('EmptyState')
    $packetCountText = $window.FindName('PacketCount')
    $lastActivity = $window.FindName('LastActivity')
    $captureStatus = $window.FindName('CaptureStatus')
    $liveDot = $window.FindName('LiveDot')
    $packetGrid.ItemsSource = $packetRows
    $watchState = [PSCustomObject]@{
        PacketCount = 0
        CaptureEnded = $false
    }

    $timer = New-Object Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(300)
    $timer.Add_Tick({
        $line = $null
        while ($capture.TryDequeue([ref]$line)) {
            if (-not [string]::IsNullOrWhiteSpace($line)) {
                $lastActivity.Text = $line.Trim()
                if (Test-WolPacketLine -Line $line) {
                    $watchState.PacketCount++
                    $packetRows.Insert(0, [PSCustomObject]@{
                        Received = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
                        Port     = Get-WolPortFromLine -Line $line
                        Summary  = $line.Trim()
                    })
                    while ($packetRows.Count -gt 500) {
                        $packetRows.RemoveAt($packetRows.Count - 1)
                    }
                    $packetCountText.Text = [string]$watchState.PacketCount
                    $emptyState.Visibility = 'Collapsed'
                }
            }
            $line = $null
        }

        if (-not $capture.IsRunning -and -not $watchState.CaptureEnded) {
            $watchState.CaptureEnded = $true
            $captureStatus.Text = "● CAPTURE STOPPED (EXIT $($capture.ExitCode))"
            $captureStatus.Foreground = '#F59E0B'
            $liveDot.Fill = '#F59E0B'
        }
    })

    $window.FindName('ClearButton').Add_Click({
        $packetRows.Clear()
        $watchState.PacketCount = 0
        $packetCountText.Text = '0'
        $emptyState.Visibility = 'Visible'
        $lastActivity.Text = 'Detection list cleared; capture is still running.'
    })
    $window.FindName('CloseButton').Add_Click({ $window.Close() })
    $window.FindName('CloseX').Add_Click({ $window.Close() })
    $window.FindName('DragRegion').Add_MouseLeftButtonDown({
        param($sender, $eventArgs)
        if ($eventArgs.LeftButton -eq [Windows.Input.MouseButtonState]::Pressed) {
            $window.DragMove()
        }
    })
    $window.Add_KeyDown({
        param($sender, $eventArgs)
        if ($eventArgs.Key -eq [Windows.Input.Key]::Escape) {
            $window.Close()
        }
    })

    $workArea = [Windows.SystemParameters]::WorkArea
    $window.Width = [Math]::Min(1080, [Math]::Max(760, $workArea.Width - 40))
    $window.Height = [Math]::Min(670, [Math]::Max(500, $workArea.Height - 40))
    $window.Add_ContentRendered({
        $timer.Start()
        $window.Activate()
    })
    [void]$window.ShowDialog()
    $completed = $true
}
catch {
    try {
        [Windows.MessageBox]::Show(
            $_.Exception.Message,
            'Wake-on-LAN Packet Watcher',
            [Windows.MessageBoxButton]::OK,
            [Windows.MessageBoxImage]::Error
        ) | Out-Null
    }
    catch { }

    Write-Host "[ERROR] $($_.Exception.Message)"
    throw
}
finally {
    if ($null -ne $timer) {
        $timer.Stop()
    }

    if ($filtersReplaced) {
        try {
            $null = Invoke-PktmonCommand -PktmonPath $pktmonPath -Arguments 'stop' -IgnoreExitCode
        }
        catch { }
    }

    if ($null -ne $capture) {
        try {
            if (-not $capture.WaitForExit(1500)) {
                $capture.Kill()
                $null = $capture.WaitForExit(1000)
            }
        }
        catch { }
        finally {
            $capture.Dispose()
        }
    }

    if ($filtersReplaced) {
        try {
            $null = Invoke-PktmonCommand -PktmonPath $pktmonPath -Arguments 'filter remove' -IgnoreExitCode
        }
        catch { }
    }
}

if ($completed) {
    Write-Host '[SUCCESS] Wake-on-LAN packet watching finished and Pktmon was cleaned up.'
}
