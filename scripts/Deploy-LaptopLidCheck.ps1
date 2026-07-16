#Requires -Version 5.1
<#
.SYNOPSIS
    Deploys the Laptop Lid Check popup and a desktop shortcut named "Folder".

.DESCRIPTION
    Creates:
      C:\ProgramData\LaptopLidCheck\Check-LaptopLid-Popup.ps1
      C:\ProgramData\LaptopLidCheck\Run-LidCheck.bat
      C:\Users\Public\Desktop\Folder.lnk

    The public desktop is used because ScriptBox and Action1 commonly execute as
    SYSTEM. Every user can therefore see and run the shortcut.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

function Write-Log {
    param(
        [ValidateSet('INFO', 'SUCCESS', 'WARNING', 'ERROR')]
        [string]$Level,
        [string]$Message
    )

    Write-Host "[$Level] $Message"
}

function Assert-Administrator {
    $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)

    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'This deployment script must be run with administrator rights or as SYSTEM.'
    }
}

try {
    Assert-Administrator

    $installFolder = 'C:\ProgramData\LaptopLidCheck'
    $checkerPath   = Join-Path $installFolder 'Check-LaptopLid-Popup.ps1'
    $launcherPath  = Join-Path $installFolder 'Run-LidCheck.bat'
    $shortcutPath  = 'C:\Users\Public\Desktop\Folder.lnk'

    New-Item -Path $installFolder -ItemType Directory -Force | Out-Null

    $checkerScript = @'
#Requires -Version 5.1
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml

function Get-LaptopLidState {
    $lidDeviceFound = $false
    try {
        $lidDevices = @(Get-CimInstance -ClassName Win32_PnPEntity -ErrorAction Stop | Where-Object {
            $_.PNPDeviceID -like 'ACPI\PNP0C0D*' -or $_.Name -match '(^|\s)Lid($|\s)'
        })
        $lidDeviceFound = $lidDevices.Count -gt 0
    } catch { }

    try {
        foreach ($item in @(Get-CimInstance -Namespace 'root\wmi' -ClassName 'MS_SystemInformation' -ErrorAction Stop)) {
            if ($item.PSObject.Properties.Name -contains 'SystemLidState' -and $null -ne $item.SystemLidState) {
                if ([bool]$item.SystemLidState) {
                    return [pscustomobject]@{ State = 'OPEN'; Detail = 'The laptop lid appears to be open.' }
                }
                return [pscustomobject]@{ State = 'CLOSED'; Detail = 'The laptop lid appears to be closed.' }
            }
        }
    } catch { }

    try {
        foreach ($item in @(Get-CimInstance -Namespace 'root\wmi' -ClassName 'MSAcpi_Lid' -ErrorAction Stop)) {
            foreach ($propertyName in @('LidOpen', 'SystemLidState', 'LidState')) {
                if ($item.PSObject.Properties.Name -contains $propertyName -and $null -ne $item.$propertyName) {
                    if ([bool]$item.$propertyName) {
                        return [pscustomobject]@{ State = 'OPEN'; Detail = 'The laptop lid appears to be open.' }
                    }
                    return [pscustomobject]@{ State = 'CLOSED'; Detail = 'The laptop lid appears to be closed.' }
                }
            }
        }
    } catch { }

    if (-not $lidDeviceFound) {
        return [pscustomobject]@{ State = 'NO LID'; Detail = 'Windows did not detect a laptop lid device on this computer.' }
    }
    return [pscustomobject]@{ State = 'UNKNOWN'; Detail = 'Windows can see a lid device, but did not return the current state.' }
}

$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Laptop Lid Check" Width="580" Height="390" WindowStartupLocation="CenterScreen"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent" Foreground="#F8FAFC"
        FontFamily="Segoe UI" ResizeMode="NoResize" Topmost="True">
    <Border Background="#0B1020" BorderBrush="#22D3EE" BorderThickness="1" CornerRadius="16">
        <Border.Effect><DropShadowEffect Color="#000000" BlurRadius="28" ShadowDepth="8" Opacity="0.65"/></Border.Effect>
        <Grid>
            <Grid.RowDefinitions><RowDefinition Height="52"/><RowDefinition Height="*"/><RowDefinition Height="70"/></Grid.RowDefinitions>
            <Border x:Name="DragRegion" CornerRadius="15,15,0,0" BorderBrush="#2D3760" BorderThickness="0,0,0,1">
                <Border.Background>
                    <LinearGradientBrush StartPoint="0,0" EndPoint="1,0">
                        <GradientStop Color="#171F3A" Offset="0"/><GradientStop Color="#102B3D" Offset="1"/>
                    </LinearGradientBrush>
                </Border.Background>
                <Grid Margin="18,0,10,0">
                    <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                        <Ellipse Width="8" Height="8" Fill="#22D3EE" Margin="0,0,10,0"/>
                        <TextBlock Text="SCRIPTBOX • LAPTOP LID CHECK" FontSize="11" FontWeight="Bold" Foreground="#E2E8F0"/>
                    </StackPanel>
                    <Button x:Name="CloseX" Content="×" Width="34" Height="30" Padding="0" HorizontalAlignment="Right"
                            Background="Transparent" BorderThickness="0" Foreground="#94A3B8" FontSize="20"/>
                </Grid>
            </Border>
            <StackPanel Grid.Row="1" Margin="34,28,34,24">
                <TextBlock Text="Current laptop lid state" HorizontalAlignment="Center" FontSize="14" Foreground="#94A3B8"/>
                <Border x:Name="StatePanel" Margin="0,18,0,0" Height="92" CornerRadius="14" Background="#11182D" BorderBrush="#314164" BorderThickness="1">
                    <TextBlock x:Name="StateText" HorizontalAlignment="Center" VerticalAlignment="Center" FontSize="32" FontWeight="Bold"/>
                </Border>
                <TextBlock x:Name="DetailText" Margin="0,18,0,0" TextAlignment="Center" TextWrapping="Wrap"
                           FontSize="13" LineHeight="20" Foreground="#CBD5E1"/>
            </StackPanel>
            <Border Grid.Row="2" Background="#090D1A" CornerRadius="0,0,15,15" BorderBrush="#202A48" BorderThickness="0,1,0,0">
                <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center" Margin="20,0">
                    <Button x:Name="RefreshButton" Content="CHECK AGAIN" Height="36" Padding="16,7" Margin="0,0,10,0"
                            Background="#151D35" BorderBrush="#334263" Foreground="#CBD5E1"/>
                    <Button x:Name="CloseButton" Content="DONE" Height="36" Padding="22,7"
                            Background="#7C3AED" BorderBrush="#A855F7" Foreground="White"/>
                </StackPanel>
            </Border>
        </Grid>
    </Border>
</Window>
"@

[xml]$xml = $xaml
$reader = New-Object System.Xml.XmlNodeReader($xml)
$window = [Windows.Markup.XamlReader]::Load($reader)

function Update-LidDisplay {
    $result = Get-LaptopLidState
    $window.FindName('StateText').Text = $result.State
    $window.FindName('DetailText').Text = $result.Detail
    $colour = switch ($result.State) {
        'OPEN' { '#34D399' }
        'CLOSED' { '#F472B6' }
        'UNKNOWN' { '#F59E0B' }
        default { '#94A3B8' }
    }
    $window.FindName('StateText').Foreground = $colour
    $window.FindName('StatePanel').BorderBrush = $colour
}

$window.FindName('RefreshButton').Add_Click({ Update-LidDisplay })
$window.FindName('CloseButton').Add_Click({ $window.Close() })
$window.FindName('CloseX').Add_Click({ $window.Close() })
$window.FindName('DragRegion').Add_MouseLeftButtonDown({
    param($sender, $eventArgs)
    if ($eventArgs.LeftButton -eq [Windows.Input.MouseButtonState]::Pressed) { $window.DragMove() }
})
$window.Add_ContentRendered({ Update-LidDisplay })
[void]$window.ShowDialog()
'@

    $launcherScript = @'
@echo off
set "Ps1Path=C:\ProgramData\LaptopLidCheck\Check-LaptopLid-Popup.ps1"
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "%Ps1Path%"
exit /b %errorlevel%
'@

    Set-Content -Path $checkerPath -Value $checkerScript -Encoding ASCII -Force
    Set-Content -Path $launcherPath -Value $launcherScript -Encoding ASCII -Force
    Write-Log INFO "Lid checker written to $checkerPath"
    Write-Log INFO "Hidden launcher written to $launcherPath"

    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = $launcherPath
    $shortcut.WorkingDirectory = $installFolder
    $shortcut.Description = 'Check whether the laptop lid is open or closed'
    $shortcut.IconLocation = "$env:SystemRoot\System32\shell32.dll,3"
    $shortcut.WindowStyle = 7
    $shortcut.Save()

    if (-not (Test-Path -LiteralPath $shortcutPath)) {
        throw 'The Folder desktop shortcut could not be verified.'
    }

    Write-Log SUCCESS 'The Folder shortcut was installed on the Public Desktop.'
    Write-Log INFO 'Double-click Folder to open the Laptop Lid Check popup.'
    return
}
catch {
    Write-Log ERROR $_.Exception.Message
    throw
}
