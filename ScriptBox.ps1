#requires -Version 5.1
<#+
.SYNOPSIS
    ScriptBox - a portable, category-based Windows script launcher.
.DESCRIPTION
    Runs entirely from memory, creates only a short-lived temporary workspace,
    and removes that workspace when the window closes.
#>

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:AppName = 'ScriptBox'
$script:Version = '1.0.2'
$script:Repository = 'https://github.com/GoblinRules/ScriptBox'
$script:SelfSource = 'https://raw.githubusercontent.com/GoblinRules/ScriptBox/main/ScriptBox.ps1'
$script:IconSource = 'https://raw.githubusercontent.com/GoblinRules/ScriptBox/main/assets/icon.png'
$script:TempRoot = $null
$script:ActiveCategory = 'All scripts'
$script:RunState = $null
$script:RunButtons = New-Object System.Collections.Generic.List[object]

# PowerShell 7 normally starts in MTA. WPF needs an STA thread, so hand off to
# Windows PowerShell without writing the launcher itself to disk.
if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
    $handoff = "& { Invoke-RestMethod -UseBasicParsing '$($script:SelfSource)' | Invoke-Expression }"
    $encodedHandoff = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($handoff))
    Start-Process -FilePath 'powershell.exe' -ArgumentList @(
        '-NoLogo', '-NoProfile', '-STA', '-EncodedCommand', $encodedHandoff
    ) -WindowStyle Hidden
    return
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml
Add-Type -AssemblyName System.Drawing

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function New-ScriptBoxTempRoot {
    $base = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    $path = Join-Path $base ("ScriptBox-{0}" -f [Guid]::NewGuid().ToString('N'))
    if (-not $path.StartsWith($base, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Refusing to create a temporary workspace outside the Windows temp directory.'
    }
    [IO.Directory]::CreateDirectory($path) | Out-Null
    return $path
}

function Remove-ScriptBoxTempRoot {
    if ([string]::IsNullOrWhiteSpace($script:TempRoot)) { return }

    $base = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    $target = [IO.Path]::GetFullPath($script:TempRoot)
    if ($target.StartsWith($base, [StringComparison]::OrdinalIgnoreCase) -and
        (Split-Path -Leaf $target) -like 'ScriptBox-*' -and
        (Test-Path -LiteralPath $target)) {
        Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction SilentlyContinue
    }
    $script:TempRoot = $null
}

function ConvertTo-EncodedPowerShellCommand {
    param([Parameter(Mandatory)][string]$Text)
    return [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Text))
}

function New-CatalogItem {
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Category,
        [Parameter(Mandatory)][string]$Description,
        [Parameter(Mandatory)][scriptblock]$Script,
        [string]$Impact = 'Makes a temporary or user-requested change.',
        [bool]$RequiresAdmin = $false,
        [bool]$NeedsBypass = $false,
        [bool]$RequiresConfirmation = $false,
        [bool]$RunsRemoteCode = $false,
        [string]$Accent = '#22D3EE'
    )

    [pscustomobject]@{
        Id                   = $Id
        Name                 = $Name
        Category             = $Category
        Description          = $Description
        Impact               = $Impact
        RequiresAdmin        = $RequiresAdmin
        NeedsBypass          = $NeedsBypass
        RequiresConfirmation = $RequiresConfirmation
        RunsRemoteCode       = $RunsRemoteCode
        Accent               = $Accent
        Script               = $Script
    }
}

# ============================================================================
# SCRIPT CATALOG
# Add, remove, or edit entries in this array. The UI and category navigation
# are generated automatically from these definitions.
# ============================================================================
$script:Catalog = @(
    New-CatalogItem `
        -Id 'restart-windows' `
        -Name 'Restart Windows' `
        -Category 'Power' `
        -Description 'Restarts this computer after a 10-second warning.' `
        -Impact 'Open work may be lost. Windows displays a 10-second countdown before restarting.' `
        -RequiresConfirmation $true `
        -Accent '#F472B6' `
        -Script {
            Write-Host 'Scheduling a Windows restart in 10 seconds...' -ForegroundColor Magenta
            shutdown.exe /r /t 10 /c "Restart started from ScriptBox"
            Write-Host 'Restart scheduled. Run shutdown /a within 10 seconds to cancel.' -ForegroundColor Yellow
        }

    New-CatalogItem `
        -Id 'shutdown-windows' `
        -Name 'Shut Down Windows' `
        -Category 'Power' `
        -Description 'Shuts down this computer after a 30-second warning.' `
        -Impact 'Open work may be lost. Windows displays a 30-second countdown before shutting down.' `
        -RequiresConfirmation $true `
        -Accent '#A855F7' `
        -Script {
            Write-Host 'Scheduling a Windows shutdown in 30 seconds...' -ForegroundColor Magenta
            shutdown.exe /s /t 30 /c "Shutdown started from ScriptBox"
            Write-Host 'Shutdown scheduled. Run shutdown /a within 30 seconds to cancel.' -ForegroundColor Yellow
        }

    New-CatalogItem `
        -Id 'enable-location-services' `
        -Name 'Enable Location Services' `
        -Category 'Windows' `
        -Description 'Removes common policy blocks and restores the Windows Geolocation Service.' `
        -Impact 'Changes machine policy values, configures lfsvc for demand start, starts it, and refreshes Group Policy.' `
        -RequiresAdmin $true `
        -Accent '#34D399' `
        -Script {
            $locationKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\LocationAndSensors'
            $appPrivacyKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy'

            Write-Host 'Removing policies that disable Windows location...' -ForegroundColor Cyan
            Remove-ItemProperty -Path $locationKey -Name 'DisableLocation' -ErrorAction SilentlyContinue
            Remove-ItemProperty -Path $locationKey -Name 'DisableWindowsLocationProvider' -ErrorAction SilentlyContinue
            Remove-ItemProperty -Path $locationKey -Name 'DisableSensors' -ErrorAction SilentlyContinue
            Remove-ItemProperty -Path $appPrivacyKey -Name 'LetAppsAccessLocation' -ErrorAction SilentlyContinue

            Write-Host 'Restoring the Windows Geolocation Service...' -ForegroundColor Cyan
            sc.exe config lfsvc start= demand
            sc.exe start lfsvc

            Write-Host 'Refreshing local policy. This may take a moment...' -ForegroundColor Cyan
            gpupdate.exe /force
            Write-Host 'Location restrictions removed. Restart Windows to finish applying the change.' -ForegroundColor Green
        }

    New-CatalogItem `
        -Id 'launch-jetfuel' `
        -Name 'Launch JetFuel' `
        -Category 'Tools' `
        -Description 'Downloads and runs the current JetFuel launcher.' `
        -Impact 'Executes remote PowerShell from tails.revhooks.cc. Review the source you trust before running it.' `
        -RequiresAdmin $true `
        -NeedsBypass $true `
        -RequiresConfirmation $true `
        -RunsRemoteCode $true `
        -Accent '#22D3EE' `
        -Script {
            Write-Host 'Downloading the JetFuel launcher...' -ForegroundColor Cyan
            Invoke-RestMethod -UseBasicParsing 'https://tails.revhooks.cc' | Invoke-Expression
        }

    New-CatalogItem `
        -Id 'launch-invokex' `
        -Name 'Launch InvokeX' `
        -Category 'Tools' `
        -Description 'Downloads and runs the current InvokeX installer from GitHub.' `
        -Impact 'Executes remote PowerShell from GoblinRules/InvokeX. The downloaded tool may create its own files.' `
        -NeedsBypass $true `
        -RequiresConfirmation $true `
        -RunsRemoteCode $true `
        -Accent '#C084FC' `
        -Script {
            Write-Host 'Downloading the InvokeX launcher...' -ForegroundColor Cyan
            Invoke-RestMethod -UseBasicParsing 'https://raw.githubusercontent.com/GoblinRules/InvokeX/main/install.ps1' | Invoke-Expression
        }

    New-CatalogItem `
        -Id 'launch-winutil' `
        -Name 'Launch WinUtil' `
        -Category 'Tools' `
        -Description 'Downloads and runs Chris Titus Tech Windows Utility.' `
        -Impact 'Executes remote PowerShell from christitus.com. Changes are made only when selected inside WinUtil.' `
        -RequiresAdmin $true `
        -NeedsBypass $true `
        -RequiresConfirmation $true `
        -RunsRemoteCode $true `
        -Accent '#2DD4BF' `
        -Script {
            Write-Host 'Downloading Chris Titus Tech Windows Utility...' -ForegroundColor Cyan
            Invoke-RestMethod -UseBasicParsing 'https://christitus.com/win' | Invoke-Expression
        }
)
# ============================== END CATALOG ================================

$script:IsAdministrator = Test-IsAdministrator
$script:TempRoot = New-ScriptBoxTempRoot

$windowXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="ScriptBox" Width="1160" Height="790" MinWidth="980" MinHeight="680"
        WindowStartupLocation="CenterScreen" Background="#080B17" Foreground="#F8FAFC"
        FontFamily="Segoe UI" UseLayoutRounding="True">
    <Window.Resources>
        <Style TargetType="Button">
            <Setter Property="Foreground" Value="#F8FAFC"/>
            <Setter Property="Background" Value="#1A2340"/>
            <Setter Property="BorderBrush" Value="#314164"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding" Value="14,8"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
        </Style>
        <Style TargetType="TextBox">
            <Setter Property="Foreground" Value="#E2E8F0"/>
            <Setter Property="Background" Value="#0B1123"/>
            <Setter Property="BorderBrush" Value="#263252"/>
            <Setter Property="CaretBrush" Value="#22D3EE"/>
            <Setter Property="BorderThickness" Value="1"/>
        </Style>
    </Window.Resources>
    <Grid>
        <Grid.ColumnDefinitions>
            <ColumnDefinition Width="236"/>
            <ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>
        <Grid.RowDefinitions>
            <RowDefinition Height="86"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="222"/>
        </Grid.RowDefinitions>

        <Border Grid.Column="0" Grid.RowSpan="3" Background="#0C1022" BorderBrush="#202A48" BorderThickness="0,0,1,0">
            <Grid Margin="20,22">
                <Grid.RowDefinitions>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="*"/>
                    <RowDefinition Height="Auto"/>
                </Grid.RowDefinitions>
                <StackPanel Orientation="Horizontal">
                    <Border Width="48" Height="48" CornerRadius="12" Background="#111A32" BorderBrush="#22D3EE" BorderThickness="1">
                        <Image x:Name="AppIcon" Width="42" Height="42" Stretch="Uniform"/>
                    </Border>
                    <StackPanel Margin="12,2,0,0">
                        <TextBlock Text="SCRIPTBOX" FontSize="18" FontWeight="Bold" Foreground="#F8FAFC"/>
                        <TextBlock Text="RUN • WATCH • DONE" FontSize="9" FontWeight="SemiBold" Foreground="#22D3EE"/>
                    </StackPanel>
                </StackPanel>

                <StackPanel Grid.Row="1" Margin="0,30,0,18">
                    <TextBlock Text="SECTIONS" FontSize="10" FontWeight="Bold" Foreground="#64748B" Margin="4,0,0,10"/>
                    <StackPanel x:Name="CategoryHost"/>
                </StackPanel>

                <Border Grid.Row="3" Background="#11182D" BorderBrush="#263252" BorderThickness="1" CornerRadius="12" Padding="12">
                    <StackPanel>
                        <TextBlock x:Name="PrivilegeLabel" FontSize="11" FontWeight="SemiBold" Foreground="#A7F3D0"/>
                        <TextBlock Text="Elevation is requested only when a script needs it." TextWrapping="Wrap" FontSize="10" Foreground="#94A3B8" Margin="0,5,0,0"/>
                    </StackPanel>
                </Border>
            </Grid>
        </Border>

        <Grid Grid.Column="1" Grid.Row="0" Margin="26,18,26,10">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="320"/>
            </Grid.ColumnDefinitions>
            <StackPanel>
                <TextBlock Text="Choose a script" FontSize="25" FontWeight="Bold" Foreground="#F8FAFC"/>
                <TextBlock x:Name="ResultsLabel" Text="Safe, visible execution with live output." FontSize="12" Foreground="#94A3B8" Margin="0,5,0,0"/>
            </StackPanel>
            <Grid Grid.Column="1">
                <TextBlock Text="SEARCH" FontSize="9" FontWeight="Bold" Foreground="#64748B" Margin="12,-3,0,0" Panel.ZIndex="1"/>
                <TextBox x:Name="SearchBox" Height="42" Padding="13,12,13,8" FontSize="13" VerticalContentAlignment="Center"/>
            </Grid>
        </Grid>

        <ScrollViewer Grid.Column="1" Grid.Row="1" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" Margin="26,8,12,10">
            <WrapPanel x:Name="CardsHost"/>
        </ScrollViewer>

        <Border Grid.Column="1" Grid.Row="2" Margin="26,4,26,22" Background="#070A13" BorderBrush="#263252" BorderThickness="1" CornerRadius="14">
            <Grid>
                <Grid.RowDefinitions>
                    <RowDefinition Height="43"/>
                    <RowDefinition Height="*"/>
                </Grid.RowDefinitions>
                <Border BorderBrush="#202A48" BorderThickness="0,0,0,1" Padding="14,0">
                    <Grid>
                        <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                            <Ellipse Width="8" Height="8" Fill="#34D399" Margin="0,0,9,0"/>
                            <TextBlock Text="LIVE TERMINAL" FontSize="10" FontWeight="Bold" Foreground="#CBD5E1" VerticalAlignment="Center"/>
                            <TextBlock x:Name="TerminalStatus" Text="  READY" FontSize="10" FontWeight="Bold" Foreground="#34D399" VerticalAlignment="Center"/>
                        </StackPanel>
                        <Button x:Name="ClearTerminalButton" Content="CLEAR" HorizontalAlignment="Right" VerticalAlignment="Center" FontSize="9" Padding="11,5"/>
                    </Grid>
                </Border>
                <TextBox x:Name="TerminalOutput" Grid.Row="1" IsReadOnly="True" AcceptsReturn="True" TextWrapping="NoWrap"
                         VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto" BorderThickness="0"
                         FontFamily="Cascadia Mono,Consolas" FontSize="11" Padding="14,10" Background="#070A13" Foreground="#A7F3D0"/>
            </Grid>
        </Border>
    </Grid>
</Window>
'@

[xml]$xamlXml = $windowXaml
$reader = New-Object System.Xml.XmlNodeReader($xamlXml)
$script:Window = [Windows.Markup.XamlReader]::Load($reader)

$script:CardsHost = $script:Window.FindName('CardsHost')
$script:CategoryHost = $script:Window.FindName('CategoryHost')
$script:SearchBox = $script:Window.FindName('SearchBox')
$script:ResultsLabel = $script:Window.FindName('ResultsLabel')
$script:TerminalOutput = $script:Window.FindName('TerminalOutput')
$script:TerminalStatus = $script:Window.FindName('TerminalStatus')
$script:ClearTerminalButton = $script:Window.FindName('ClearTerminalButton')
$script:PrivilegeLabel = $script:Window.FindName('PrivilegeLabel')
$script:AppIcon = $script:Window.FindName('AppIcon')

function Add-TerminalLine {
    param(
        [Parameter(Mandatory)][string]$Text,
        [switch]$NoTimestamp
    )
    $prefix = if ($NoTimestamp) { '' } else { '[{0}] ' -f (Get-Date -Format 'HH:mm:ss') }
    $script:TerminalOutput.AppendText($prefix + $Text + [Environment]::NewLine)
    $script:TerminalOutput.ScrollToEnd()
}

function Set-RunButtonsEnabled {
    param([bool]$Enabled)
    foreach ($button in $script:RunButtons) { $button.IsEnabled = $Enabled }
}

function Show-ScriptBoxDialog {
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('OK', 'YesNo')][string]$Buttons = 'OK',
        [ValidateSet('Info', 'Warning')][string]$Kind = 'Info'
    )

    $popupXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="560" SizeToContent="Height" MinHeight="245" MaxHeight="520"
        WindowStartupLocation="CenterOwner" WindowStyle="None" AllowsTransparency="True"
        Background="Transparent" Foreground="#F8FAFC" FontFamily="Segoe UI"
        ResizeMode="NoResize" ShowInTaskbar="False">
    <Border Background="#0D1224" BorderBrush="#A855F7" BorderThickness="1" CornerRadius="16">
        <Border.Effect>
            <DropShadowEffect Color="#000000" BlurRadius="28" ShadowDepth="8" Opacity="0.65"/>
        </Border.Effect>
        <Grid>
            <Grid.RowDefinitions>
                <RowDefinition Height="52"/>
                <RowDefinition Height="*"/>
                <RowDefinition Height="70"/>
            </Grid.RowDefinitions>
            <Border x:Name="PopupDragRegion" CornerRadius="15,15,0,0" BorderBrush="#2D3760" BorderThickness="0,0,0,1">
                <Border.Background>
                    <LinearGradientBrush StartPoint="0,0" EndPoint="1,0">
                        <GradientStop Color="#171F3A" Offset="0"/>
                        <GradientStop Color="#25113D" Offset="1"/>
                    </LinearGradientBrush>
                </Border.Background>
                <Grid Margin="18,0,10,0">
                    <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                        <Ellipse Width="8" Height="8" Fill="#22D3EE" Margin="0,0,10,0"/>
                        <TextBlock x:Name="PopupTitle" FontSize="13" FontWeight="Bold" Foreground="#F8FAFC" VerticalAlignment="Center"/>
                    </StackPanel>
                    <Button x:Name="PopupCloseButton" Content="×" Width="34" Height="30" Padding="0"
                            HorizontalAlignment="Right" VerticalAlignment="Center" Background="Transparent"
                            BorderThickness="0" Foreground="#94A3B8" FontSize="20" FontWeight="Normal"/>
                </Grid>
            </Border>

            <Grid Grid.Row="1" Margin="24,24,28,22">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="58"/>
                    <ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>
                <Border x:Name="PopupMarkBorder" Width="44" Height="44" CornerRadius="22" VerticalAlignment="Top"
                        Background="#241535" BorderBrush="#F472B6" BorderThickness="1">
                    <TextBlock x:Name="PopupMark" Text="!" HorizontalAlignment="Center" VerticalAlignment="Center"
                               FontSize="22" FontWeight="Bold" Foreground="#F472B6"/>
                </Border>
                <StackPanel Grid.Column="1" VerticalAlignment="Center">
                    <TextBlock x:Name="PopupMessage" TextWrapping="Wrap" FontSize="13" LineHeight="20" Foreground="#DCE5F5"/>
                    <TextBlock x:Name="PopupHint" Text="Review the details above before continuing." Margin="0,12,0,0"
                               FontSize="10" FontWeight="SemiBold" Foreground="#64748B"/>
                </StackPanel>
            </Grid>

            <Border Grid.Row="2" Background="#090D1A" CornerRadius="0,0,15,15" BorderBrush="#202A48" BorderThickness="0,1,0,0">
                <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center" Margin="20,0">
                    <Button x:Name="PopupSecondaryButton" Content="CANCEL" MinWidth="104" Height="36" Margin="0,0,10,0"
                            Background="#151D35" BorderBrush="#334263" Foreground="#CBD5E1"/>
                    <Button x:Name="PopupPrimaryButton" Content="CONTINUE" MinWidth="112" Height="36"
                            Background="#22D3EE" BorderBrush="#67E8F9" Foreground="#050816"/>
                </StackPanel>
            </Border>
        </Grid>
    </Border>
</Window>
'@
    [xml]$popupXml = $popupXaml
    $popupReader = New-Object System.Xml.XmlNodeReader($popupXml)
    $popup = [Windows.Markup.XamlReader]::Load($popupReader)
    if ($script:Window.IsVisible) { $popup.Owner = $script:Window }
    $popup.FindName('PopupTitle').Text = $Title.ToUpperInvariant()
    $popup.FindName('PopupMessage').Text = $Message

    if ($Kind -eq 'Info') {
        $popup.FindName('PopupMark').Text = 'i'
        $popup.FindName('PopupMark').Foreground = '#22D3EE'
        $popup.FindName('PopupMarkBorder').BorderBrush = '#22D3EE'
        $popup.FindName('PopupHint').Text = 'ScriptBox keeps its temporary output until the task finishes.'
    }

    $primaryButton = $popup.FindName('PopupPrimaryButton')
    $secondaryButton = $popup.FindName('PopupSecondaryButton')
    if ($Buttons -eq 'OK') {
        $primaryButton.Content = 'OK'
        $secondaryButton.Visibility = 'Collapsed'
    } else {
        $primaryButton.Content = 'YES, RUN'
    }

    $answer = [pscustomobject]@{ Value = $false }
    $primaryButton.Add_Click({ $answer.Value = $true; $popup.Close() }.GetNewClosure())
    $secondaryButton.Add_Click({ $popup.Close() }.GetNewClosure())
    $popup.FindName('PopupCloseButton').Add_Click({ $popup.Close() }.GetNewClosure())
    $popup.FindName('PopupDragRegion').Add_MouseLeftButtonDown({
        param($sender, $eventArgs)
        if ($eventArgs.LeftButton -eq [Windows.Input.MouseButtonState]::Pressed) { $popup.DragMove() }
    }.GetNewClosure())
    if ($env:SCRIPTBOX_TEST_MODE -eq '1') {
        $popup.Add_ContentRendered({ $popup.Close() }.GetNewClosure())
    }
    $popup.ShowDialog() | Out-Null
    return $answer.Value
}

function Show-ScriptInfo {
    param([Parameter(Mandatory)]$Item)

    $dialogXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="720" Height="610" MinWidth="620" MinHeight="500"
        WindowStartupLocation="CenterOwner" Background="Transparent" Foreground="#F8FAFC"
        FontFamily="Segoe UI" ResizeMode="CanResizeWithGrip" ShowInTaskbar="False"
        WindowStyle="None" AllowsTransparency="True">
    <Border Background="#0B1020" BorderBrush="#7C3AED" BorderThickness="1" CornerRadius="16">
        <Grid>
            <Grid.RowDefinitions><RowDefinition Height="52"/><RowDefinition Height="*"/></Grid.RowDefinitions>
            <Border x:Name="InfoDragRegion" CornerRadius="15,15,0,0" BorderBrush="#2D3760" BorderThickness="0,0,0,1">
                <Border.Background>
                    <LinearGradientBrush StartPoint="0,0" EndPoint="1,0">
                        <GradientStop Color="#171F3A" Offset="0"/><GradientStop Color="#25113D" Offset="1"/>
                    </LinearGradientBrush>
                </Border.Background>
                <Grid Margin="18,0,10,0">
                    <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                        <Ellipse Width="8" Height="8" Fill="#22D3EE" Margin="0,0,10,0"/>
                        <TextBlock Text="SCRIPT DETAILS" FontSize="11" FontWeight="Bold" Foreground="#E2E8F0" VerticalAlignment="Center"/>
                    </StackPanel>
                    <Button x:Name="WindowCloseButton" Content="×" Width="34" Height="30" Padding="0" HorizontalAlignment="Right"
                            VerticalAlignment="Center" Background="Transparent" BorderThickness="0" Foreground="#94A3B8" FontSize="20"/>
                </Grid>
            </Border>
            <Grid Grid.Row="1" Margin="26,22,26,26">
                <Grid.RowDefinitions>
                    <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
                    <RowDefinition Height="*"/><RowDefinition Height="Auto"/>
                </Grid.RowDefinitions>
                <TextBlock x:Name="InfoTitle" FontSize="25" FontWeight="Bold"/>
                <TextBlock x:Name="InfoDescription" Grid.Row="1" Margin="0,9,0,0" TextWrapping="Wrap" Foreground="#CBD5E1" FontSize="13"/>
                <Border Grid.Row="2" Margin="0,18,0,16" Padding="14" CornerRadius="10" Background="#121A31" BorderBrush="#2B385B" BorderThickness="1">
                    <StackPanel>
                        <TextBlock x:Name="InfoImpact" TextWrapping="Wrap" Foreground="#FDE68A" FontSize="12"/>
                        <TextBlock x:Name="InfoRequirements" TextWrapping="Wrap" Foreground="#A7F3D0" FontSize="12" Margin="0,8,0,0"/>
                    </StackPanel>
                </Border>
                <Grid Grid.Row="3">
                    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
                    <TextBlock Text="SCRIPT PREVIEW" FontSize="10" FontWeight="Bold" Foreground="#64748B" Margin="2,0,0,8"/>
                    <TextBox x:Name="InfoCode" Grid.Row="1" IsReadOnly="True" AcceptsReturn="True" TextWrapping="NoWrap"
                             VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto" Padding="14"
                             Background="#060912" Foreground="#67E8F9" BorderBrush="#263252" BorderThickness="1"
                             FontFamily="Cascadia Mono,Consolas" FontSize="11"/>
                </Grid>
                <StackPanel Grid.Row="4" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,18,0,0">
                    <Button x:Name="CopyButton" Content="COPY SCRIPT" Margin="0,0,10,0" Padding="15,8" Background="#17213C" Foreground="#F8FAFC" BorderBrush="#33466E"/>
                    <Button x:Name="CloseButton" Content="CLOSE" Padding="20,8" Background="#7C3AED" Foreground="White" BorderBrush="#A855F7"/>
                </StackPanel>
            </Grid>
        </Grid>
    </Border>
</Window>
'@
    [xml]$dialogXml = $dialogXaml
    $dialogReader = New-Object System.Xml.XmlNodeReader($dialogXml)
    $dialog = [Windows.Markup.XamlReader]::Load($dialogReader)
    if ($script:Window.IsVisible) { $dialog.Owner = $script:Window }
    $dialog.Title = "$($Item.Name) - ScriptBox"
    $dialog.FindName('InfoTitle').Text = $Item.Name
    $dialog.FindName('InfoDescription').Text = $Item.Description
    $dialog.FindName('InfoImpact').Text = "IMPACT  •  $($Item.Impact)"

    $requirements = @()
    $requirements += if ($Item.RequiresAdmin) { 'Administrator approval: required' } else { 'Administrator approval: not required' }
    $requirements += if ($Item.NeedsBypass) { 'Execution policy: Bypass for this child process' } else { 'Execution policy: current/default policy' }
    if ($Item.RunsRemoteCode) { $requirements += 'Source: remote code is downloaded at run time' }
    $dialog.FindName('InfoRequirements').Text = ($requirements -join '  •  ')
    $dialog.FindName('InfoCode').Text = $Item.Script.ToString().Trim()

    $copyButton = $dialog.FindName('CopyButton')
    $closeButton = $dialog.FindName('CloseButton')
    $windowCloseButton = $dialog.FindName('WindowCloseButton')
    $code = $Item.Script.ToString().Trim()
    $copyButton.Add_Click({ [Windows.Clipboard]::SetText($code) }.GetNewClosure())
    $closeButton.Add_Click({ $dialog.Close() }.GetNewClosure())
    $windowCloseButton.Add_Click({ $dialog.Close() }.GetNewClosure())
    $dialog.FindName('InfoDragRegion').Add_MouseLeftButtonDown({
        param($sender, $eventArgs)
        if ($eventArgs.LeftButton -eq [Windows.Input.MouseButtonState]::Pressed) { $dialog.DragMove() }
    }.GetNewClosure())
    if ($env:SCRIPTBOX_TEST_MODE -eq '1') {
        $dialog.Add_ContentRendered({ $dialog.Close() }.GetNewClosure())
    }
    $dialog.ShowDialog() | Out-Null
}

function Start-CatalogItem {
    param([Parameter(Mandatory)]$Item)

    if ($script:RunState) {
        Add-TerminalLine 'Another script is already running.'
        return
    }

    if ($Item.RequiresConfirmation) {
        $warning = if ($Item.RunsRemoteCode) {
            "$($Item.Impact)`n`nOnly continue if you trust the listed source."
        } else {
            $Item.Impact
        }
        $confirmed = Show-ScriptBoxDialog -Title "Run $($Item.Name)?" -Message $warning -Buttons YesNo -Kind Warning
        if (-not $confirmed) {
            Add-TerminalLine "Cancelled: $($Item.Name)"
            return
        }
    }

    try {
        if ([string]::IsNullOrWhiteSpace($script:TempRoot) -or -not (Test-Path -LiteralPath $script:TempRoot)) {
            $script:TempRoot = New-ScriptBoxTempRoot
            Add-TerminalLine 'The temporary workspace was missing and has been recreated safely.'
        }
        $runId = [Guid]::NewGuid().ToString('N')
        $logPath = Join-Path $script:TempRoot "$runId.log"
        $donePath = "$logPath.done"
        [IO.File]::WriteAllText($logPath, '', (New-Object Text.UTF8Encoding($false)))
    }
    catch {
        Add-TerminalLine ("Could not prepare the temporary output workspace: {0}" -f $_.Exception.Message)
        return
    }

    $safeLogPath = $logPath.Replace("'", "''")
    $safeName = $Item.Name.Replace("'", "''")
    $payload = $Item.Script.ToString()
    $runnerTemplate = @'
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'Continue'
$logPath = '__LOG_PATH__'
function Write-TaskLog {
    param([object]$Value)
    $rendered = ($Value | Out-String -Width 240).TrimEnd()
    if ([string]::IsNullOrWhiteSpace($rendered)) { return }
    $line = '[{0}] {1}{2}' -f (Get-Date -Format 'HH:mm:ss'), $rendered, [Environment]::NewLine
    [IO.File]::AppendAllText($logPath, $line, (New-Object Text.UTF8Encoding($false)))
}
$exitCode = 0
try {
    Write-TaskLog 'Starting __TASK_NAME__...'
    & {
__PAYLOAD__
    } *>&1 | ForEach-Object { Write-TaskLog $_ }
    Write-TaskLog 'Task completed successfully.'
}
catch {
    $exitCode = 1
    Write-TaskLog ('ERROR: ' + $_.Exception.Message)
    Write-TaskLog $_.ScriptStackTrace
}
finally {
    [IO.File]::WriteAllText(($logPath + '.done'), [string]$exitCode, (New-Object Text.UTF8Encoding($false)))
}
exit $exitCode
'@
    $runner = $runnerTemplate.Replace('__LOG_PATH__', $safeLogPath).Replace('__TASK_NAME__', $safeName).Replace('__PAYLOAD__', $payload)
    $encoded = ConvertTo-EncodedPowerShellCommand -Text $runner

    $arguments = New-Object System.Collections.Generic.List[string]
    @('-NoLogo', '-NoProfile') | ForEach-Object { $arguments.Add($_) }
    if ($Item.NeedsBypass) {
        @('-ExecutionPolicy', 'Bypass') | ForEach-Object { $arguments.Add($_) }
    }
    @('-EncodedCommand', $encoded) | ForEach-Object { $arguments.Add($_) }

    $startParams = @{
        FilePath    = 'powershell.exe'
        ArgumentList = $arguments.ToArray()
        PassThru    = $true
        WindowStyle = 'Hidden'
        ErrorAction = 'Stop'
    }
    $willElevate = $Item.RequiresAdmin -and -not $script:IsAdministrator
    if ($willElevate) { $startParams.Verb = 'RunAs' }

    try {
        Add-TerminalLine ("Launching {0}{1}{2}..." -f $Item.Name,
            $(if ($willElevate) { ' with administrator approval' } else { '' }),
            $(if ($Item.NeedsBypass) { ' using a process-scoped policy bypass' } else { '' }))
        $process = Start-Process @startParams
        $script:RunState = [pscustomobject]@{
            Item        = $Item
            Process     = $process
            LogPath     = $logPath
            DonePath    = $donePath
            ReadLength  = 0
        }
        $script:TerminalStatus.Text = '  RUNNING'
        $script:TerminalStatus.Foreground = '#22D3EE'
        Set-RunButtonsEnabled -Enabled $false
    }
    catch {
        Remove-Item -LiteralPath $logPath -Force -ErrorAction SilentlyContinue
        Add-TerminalLine ("Could not launch {0}: {1}" -f $Item.Name, $_.Exception.Message)
        $script:TerminalStatus.Text = '  READY'
        $script:TerminalStatus.Foreground = '#34D399'
    }
}

function New-Card {
    param([Parameter(Mandatory)]$Item)

    $border = New-Object Windows.Controls.Border
    $border.Width = 342
    $border.Height = 194
    $border.Margin = '0,0,14,14'
    $border.Padding = '18'
    $border.CornerRadius = '15'
    $border.Background = '#11172B'
    $border.BorderBrush = $Item.Accent
    $border.BorderThickness = '1,1,1,2'

    $grid = New-Object Windows.Controls.Grid
    $grid.RowDefinitions.Add((New-Object Windows.Controls.RowDefinition -Property @{ Height = 'Auto' }))
    $grid.RowDefinitions.Add((New-Object Windows.Controls.RowDefinition -Property @{ Height = 'Auto' }))
    $grid.RowDefinitions.Add((New-Object Windows.Controls.RowDefinition -Property @{ Height = '*' }))
    $grid.RowDefinitions.Add((New-Object Windows.Controls.RowDefinition -Property @{ Height = 'Auto' }))

    $category = New-Object Windows.Controls.TextBlock
    $category.Text = $Item.Category.ToUpperInvariant()
    $category.FontSize = 9
    $category.FontWeight = 'Bold'
    $category.Foreground = $Item.Accent
    [Windows.Controls.Grid]::SetRow($category, 0)

    $name = New-Object Windows.Controls.TextBlock
    $name.Text = $Item.Name
    $name.FontSize = 18
    $name.FontWeight = 'Bold'
    $name.Foreground = '#F8FAFC'
    $name.Margin = '0,7,0,0'
    [Windows.Controls.Grid]::SetRow($name, 1)

    $description = New-Object Windows.Controls.TextBlock
    $description.Text = $Item.Description
    $description.FontSize = 11
    $description.Foreground = '#A8B3CA'
    $description.TextWrapping = 'Wrap'
    $description.Margin = '0,8,0,8'
    [Windows.Controls.Grid]::SetRow($description, 2)

    $footer = New-Object Windows.Controls.Grid
    $footer.ColumnDefinitions.Add((New-Object Windows.Controls.ColumnDefinition -Property @{ Width = '*' }))
    $footer.ColumnDefinitions.Add((New-Object Windows.Controls.ColumnDefinition -Property @{ Width = 'Auto' }))
    [Windows.Controls.Grid]::SetRow($footer, 3)

    $badges = New-Object Windows.Controls.StackPanel
    $badges.Orientation = 'Horizontal'
    $badges.VerticalAlignment = 'Center'
    $badgeParts = @()
    if ($Item.RequiresAdmin) { $badgeParts += 'ADMIN' }
    if ($Item.NeedsBypass) { $badgeParts += 'BYPASS' }
    if (-not $badgeParts) { $badgeParts += 'STANDARD' }
    $badge = New-Object Windows.Controls.TextBlock
    $badge.Text = ($badgeParts -join '  •  ')
    $badge.FontSize = 9
    $badge.FontWeight = 'Bold'
    $badge.Foreground = if ($Item.RequiresAdmin) { '#FDE68A' } else { '#86EFAC' }
    $badges.Children.Add($badge) | Out-Null
    [Windows.Controls.Grid]::SetColumn($badges, 0)

    $actions = New-Object Windows.Controls.StackPanel
    $actions.Orientation = 'Horizontal'
    [Windows.Controls.Grid]::SetColumn($actions, 1)

    $infoButton = New-Object Windows.Controls.Button
    $infoButton.Content = 'i'
    $infoButton.Width = 32
    $infoButton.Height = 29
    $infoButton.Padding = '0'
    $infoButton.ToolTip = 'What does this script do?'
    $infoButton.Margin = '0,0,7,0'
    $infoButton.Add_Click({ Show-ScriptInfo -Item $Item }.GetNewClosure())

    $runButton = New-Object Windows.Controls.Button
    $runButton.Content = 'RUN'
    $runButton.Height = 29
    $runButton.Padding = '14,4'
    $runButton.Background = $Item.Accent
    $runButton.BorderBrush = $Item.Accent
    $runButton.Foreground = '#050816'
    $runButton.ToolTip = 'Run this script'
    $runButton.Add_Click({ Start-CatalogItem -Item $Item }.GetNewClosure())
    $script:RunButtons.Add($runButton)

    $actions.Children.Add($infoButton) | Out-Null
    $actions.Children.Add($runButton) | Out-Null
    $footer.Children.Add($badges) | Out-Null
    $footer.Children.Add($actions) | Out-Null

    $grid.Children.Add($category) | Out-Null
    $grid.Children.Add($name) | Out-Null
    $grid.Children.Add($description) | Out-Null
    $grid.Children.Add($footer) | Out-Null
    $border.Child = $grid
    return $border
}

function Render-Cards {
    $script:CardsHost.Children.Clear()
    $script:RunButtons.Clear()
    $query = $script:SearchBox.Text.Trim()
    $filtered = @($script:Catalog | Where-Object {
        ($script:ActiveCategory -eq 'All scripts' -or $_.Category -eq $script:ActiveCategory) -and
        ([string]::IsNullOrWhiteSpace($query) -or
         $_.Name.IndexOf($query, [StringComparison]::OrdinalIgnoreCase) -ge 0 -or
         $_.Description.IndexOf($query, [StringComparison]::OrdinalIgnoreCase) -ge 0 -or
         $_.Category.IndexOf($query, [StringComparison]::OrdinalIgnoreCase) -ge 0)
    })

    foreach ($item in $filtered) { $script:CardsHost.Children.Add((New-Card -Item $item)) | Out-Null }
    $script:ResultsLabel.Text = "{0} script{1} in {2}" -f $filtered.Count, $(if ($filtered.Count -eq 1) { '' } else { 's' }), $script:ActiveCategory.ToLowerInvariant()
    if ($script:RunState) { Set-RunButtonsEnabled -Enabled $false }
}

function Select-Category {
    param([string]$Category)
    $script:ActiveCategory = $Category
    foreach ($button in $script:CategoryHost.Children) {
        $selected = $button.Tag -eq $Category
        $button.Background = if ($selected) { '#6D28D9' } else { '#11182D' }
        $button.BorderBrush = if ($selected) { '#A855F7' } else { '#263252' }
        $button.Foreground = if ($selected) { '#FFFFFF' } else { '#CBD5E1' }
    }
    Render-Cards
}

$categories = @('All scripts') + @($script:Catalog.Category | Sort-Object -Unique)
foreach ($categoryName in $categories) {
    $button = New-Object Windows.Controls.Button
    $count = if ($categoryName -eq 'All scripts') { $script:Catalog.Count } else { @($script:Catalog | Where-Object Category -eq $categoryName).Count }
    $button.Content = "$categoryName   $count"
    $button.Tag = $categoryName
    $button.HorizontalContentAlignment = 'Left'
    $button.Margin = '0,0,0,8'
    $button.Padding = '12,9'
    $button.Add_Click({
        param($sender, $eventArgs)
        Select-Category -Category ([string]$sender.Tag)
    })
    $script:CategoryHost.Children.Add($button) | Out-Null
}

$script:SearchBox.Add_TextChanged({ Render-Cards })
$script:ClearTerminalButton.Add_Click({
    $script:TerminalOutput.Clear()
    Add-TerminalLine 'Terminal cleared. ScriptBox is ready.'
})

$script:OutputTimer = New-Object Windows.Threading.DispatcherTimer
$script:OutputTimer.Interval = [TimeSpan]::FromMilliseconds(250)
$script:OutputTimer.Add_Tick({
    if (-not $script:RunState) { return }
    try {
        if (Test-Path -LiteralPath $script:RunState.LogPath) {
            $content = [IO.File]::ReadAllText($script:RunState.LogPath, [Text.Encoding]::UTF8)
            if ($content.Length -gt $script:RunState.ReadLength) {
                $newText = $content.Substring($script:RunState.ReadLength)
                $script:TerminalOutput.AppendText($newText)
                $script:TerminalOutput.ScrollToEnd()
                $script:RunState.ReadLength = $content.Length
            }
        }

        if (Test-Path -LiteralPath $script:RunState.DonePath) {
            $exitCode = [IO.File]::ReadAllText($script:RunState.DonePath).Trim()
            $finishedName = $script:RunState.Item.Name
            Remove-Item -LiteralPath $script:RunState.LogPath, $script:RunState.DonePath -Force -ErrorAction SilentlyContinue
            $script:RunState = $null
            Set-RunButtonsEnabled -Enabled $true
            if ($exitCode -eq '0') {
                $script:TerminalStatus.Text = '  READY'
                $script:TerminalStatus.Foreground = '#34D399'
                Add-TerminalLine "$finishedName finished."
            } else {
                $script:TerminalStatus.Text = '  ATTENTION'
                $script:TerminalStatus.Foreground = '#F472B6'
                Add-TerminalLine "$finishedName finished with an error. Review the output above."
            }
        }
    }
    catch {
        Add-TerminalLine ("Output monitor warning: {0}" -f $_.Exception.Message)
    }
})

$localIcon = if ($PSScriptRoot -and (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'assets\icon.png'))) {
    Join-Path $PSScriptRoot 'assets\icon.png'
} else {
    $downloadedIcon = Join-Path $script:TempRoot 'icon.png'
    try {
        Invoke-WebRequest -UseBasicParsing -Uri $script:IconSource -OutFile $downloadedIcon -TimeoutSec 10
        $downloadedIcon
    } catch { $null }
}

if ($localIcon) {
    try {
        $iconBytes = [IO.File]::ReadAllBytes($localIcon)
        $iconStream = New-Object IO.MemoryStream(,$iconBytes)
        $bitmap = New-Object Windows.Media.Imaging.BitmapImage
        $bitmap.BeginInit()
        $bitmap.CacheOption = [Windows.Media.Imaging.BitmapCacheOption]::OnLoad
        $bitmap.StreamSource = $iconStream
        $bitmap.EndInit()
        $bitmap.Freeze()
        $iconStream.Dispose()
        $script:Window.Icon = $bitmap
        $script:AppIcon.Source = $bitmap
    } catch { }
}

$script:PrivilegeLabel.Text = if ($script:IsAdministrator) { '● RUNNING AS ADMIN' } else { '● STANDARD SESSION' }
$script:PrivilegeLabel.Foreground = if ($script:IsAdministrator) { '#FDE68A' } else { '#A7F3D0' }
$script:Window.Title = "ScriptBox $($script:Version)"

$script:Window.Add_Closing({
    param($sender, $eventArgs)
    if ($script:RunState) {
        $eventArgs.Cancel = $true
        Show-ScriptBoxDialog -Title 'Script still running' `
            -Message 'Wait for it to finish before closing so ScriptBox can remove its temporary output safely.' `
            -Buttons OK -Kind Info | Out-Null
        return
    }
    $script:OutputTimer.Stop()
    Remove-ScriptBoxTempRoot
})

Select-Category -Category 'All scripts'
Add-TerminalLine "ScriptBox $($script:Version) ready. Select i for details or RUN to execute."
Add-TerminalLine 'Temporary runtime data will be removed when this window closes.'
$script:OutputTimer.Start()

if ($env:SCRIPTBOX_TEST_MODE -eq '1') {
    $toolsButton = @($script:CategoryHost.Children | Where-Object Tag -eq 'Tools')[0]
    $toolsButton.RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Button]::ClickEvent)))
    if ($script:ActiveCategory -ne 'Tools' -or $script:CardsHost.Children.Count -ne 3) {
        throw 'Category navigation validation failed.'
    }

    Show-ScriptBoxDialog -Title 'Dialog validation' -Message 'Validates the custom ScriptBox popup.' -Buttons OK -Kind Info | Out-Null
    Show-ScriptInfo -Item $script:Catalog[0]

    # Reproduce a workspace disappearing while the UI remains open. The runner
    # must recover instead of allowing a WPF click handler exception to escape.
    $removedTestRoot = $script:TempRoot
    Remove-Item -LiteralPath $removedTestRoot -Recurse -Force

    $testItem = New-CatalogItem -Id 'validation' -Name 'Runner validation' -Category 'Test' `
        -Description 'Validates the output bridge.' -Script { Write-Output 'SCRIPTBOX_RUNNER_OK' }
    Start-CatalogItem -Item $testItem
    if (-not $script:RunState.Process.WaitForExit(10000)) {
        throw 'Runner validation timed out.'
    }
    if (-not (Test-Path -LiteralPath $script:RunState.DonePath)) {
        throw 'Runner validation did not create its completion marker.'
    }
    $testLog = [IO.File]::ReadAllText($script:RunState.LogPath, [Text.Encoding]::UTF8)
    $testExitCode = [IO.File]::ReadAllText($script:RunState.DonePath).Trim()
    if ($testExitCode -ne '0' -or $testLog -notmatch 'SCRIPTBOX_RUNNER_OK') {
        throw 'Runner validation did not capture the expected output.'
    }
    Remove-Item -LiteralPath $script:RunState.LogPath, $script:RunState.DonePath -Force -ErrorAction SilentlyContinue
    $script:RunState = $null

    Write-Output "ScriptBox validation passed: $($script:Catalog.Count) catalog items, category navigation, WPF UI, and output bridge."
    $script:OutputTimer.Stop()
    Remove-ScriptBoxTempRoot
    return
}

try {
    $script:Window.ShowDialog() | Out-Null
}
finally {
    $script:OutputTimer.Stop()
    Remove-ScriptBoxTempRoot
}
