#Requires -Version 5.1
<#
.SYNOPSIS
    Shows the USB Plug and Play devices that Windows currently reports present.

.DESCRIPTION
    Queries present PnP devices whose instance ID begins with USB\, retrieves
    their location information and location paths, and displays the results in
    a sortable, wrapped table. The popup can copy the complete table to the
    clipboard and makes no system changes.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml

function ConvertTo-DisplayText {
    param(
        [AllowNull()]
        [object]$Value
    )

    $parts = @($Value | ForEach-Object { [string]$_ } | Where-Object {
        -not [string]::IsNullOrWhiteSpace($_)
    })
    if ($parts.Count -eq 0) {
        return 'Not reported by Windows'
    }

    return ($parts -join '; ')
}

try {
    if (-not (Get-Command -Name 'Get-PnpDevice' -ErrorAction SilentlyContinue) -or
        -not (Get-Command -Name 'Get-PnpDeviceProperty' -ErrorAction SilentlyContinue)) {
        throw 'The Windows PnpDevice PowerShell module is not available on this computer.'
    }

    $devices = @(Get-PnpDevice -PresentOnly -ErrorAction Stop |
        Where-Object InstanceId -Like 'USB\*' |
        ForEach-Object {
            $location = (Get-PnpDeviceProperty `
                -InstanceId $_.InstanceId `
                -KeyName 'DEVPKEY_Device_LocationInfo' `
                -ErrorAction SilentlyContinue).Data
            $paths = (Get-PnpDeviceProperty `
                -InstanceId $_.InstanceId `
                -KeyName 'DEVPKEY_Device_LocationPaths' `
                -ErrorAction SilentlyContinue).Data

            $deviceName = if (-not [string]::IsNullOrWhiteSpace($_.FriendlyName)) {
                $_.FriendlyName
            }
            else {
                $_.InstanceId
            }

            [PSCustomObject]@{
                Device   = $deviceName
                Location = ConvertTo-DisplayText -Value $location
                USBPath  = ConvertTo-DisplayText -Value $paths
            }
        } |
        Sort-Object Device, Location, USBPath)

    $xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Connected USB Devices" Width="1120" Height="680"
        MinWidth="760" MinHeight="480" WindowStartupLocation="CenterScreen"
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
        <Style x:Key="WrappedCell" TargetType="TextBlock">
            <Setter Property="TextWrapping" Value="Wrap"/>
            <Setter Property="VerticalAlignment" Value="Center"/>
            <Setter Property="Padding" Value="4,8"/>
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
    <Border Background="#0B1020" BorderBrush="#22D3EE" BorderThickness="1" CornerRadius="15">
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
                        <GradientStop Color="#103044" Offset="1"/>
                    </LinearGradientBrush>
                </Border.Background>
                <Grid Margin="18,0,10,0">
                    <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                        <Ellipse Width="8" Height="8" Fill="#22D3EE" Margin="0,0,10,0"/>
                        <TextBlock Text="SCRIPTBOX • USB INVENTORY" FontSize="11"
                                   FontWeight="Bold" Foreground="#E2E8F0"/>
                    </StackPanel>
                    <Button x:Name="CloseX" Content="×" Width="36" Height="32"
                            HorizontalAlignment="Right" Padding="0" FontSize="20"
                            Background="Transparent" BorderThickness="0" Foreground="#94A3B8"
                            Cursor="Hand"/>
                </Grid>
            </Border>

            <Grid Grid.Row="1" Margin="24,20,24,16">
                <StackPanel>
                    <TextBlock Text="Connected USB devices" FontSize="24"
                               FontWeight="Bold" Foreground="#F8FAFC"/>
                    <TextBlock x:Name="SummaryText" Margin="0,6,0,0" FontSize="12"
                               Foreground="#94A3B8" TextWrapping="Wrap"/>
                </StackPanel>
                <Border HorizontalAlignment="Right" VerticalAlignment="Center"
                        Background="#102B3D" BorderBrush="#22D3EE"
                        BorderThickness="1" CornerRadius="12" Padding="16,8">
                    <StackPanel Orientation="Horizontal">
                        <TextBlock x:Name="DeviceCount" FontSize="18" FontWeight="Bold"
                                   Foreground="#67E8F9"/>
                        <TextBlock Text=" PRESENT" Margin="6,4,0,0" FontSize="10"
                                   FontWeight="Bold" Foreground="#94A3B8"/>
                    </StackPanel>
                </Border>
            </Grid>

            <Grid Grid.Row="2" Margin="24,0,24,18">
                <Border Background="#0F1629" BorderBrush="#2D3760"
                        BorderThickness="1" CornerRadius="10">
                    <DataGrid x:Name="DeviceGrid" Margin="1" Background="#0F1629"
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
                            <DataGridTextColumn Header="DEVICE" Binding="{Binding Device}"
                                                Width="2.2*" MinWidth="210"
                                                ElementStyle="{StaticResource WrappedCell}"/>
                            <DataGridTextColumn Header="LOCATION" Binding="{Binding Location}"
                                                Width="1.35*" MinWidth="180"
                                                ElementStyle="{StaticResource WrappedCell}"/>
                            <DataGridTextColumn Header="USB PATH" Binding="{Binding USBPath}"
                                                Width="2.45*" MinWidth="280"
                                                ElementStyle="{StaticResource WrappedCell}"/>
                        </DataGrid.Columns>
                    </DataGrid>
                </Border>
                <StackPanel x:Name="EmptyState" Visibility="Collapsed"
                            HorizontalAlignment="Center" VerticalAlignment="Center">
                    <TextBlock Text="No present USB devices were found"
                               FontSize="18" FontWeight="SemiBold"
                               Foreground="#CBD5E1" TextAlignment="Center"/>
                    <TextBlock Margin="0,8,0,0"
                               Text="Windows returned no present Plug and Play entries beginning with USB\."
                               FontSize="12" Foreground="#64748B" TextAlignment="Center"/>
                </StackPanel>
            </Grid>

            <Border Grid.Row="3" Background="#090D1A" CornerRadius="0,0,14,14"
                    BorderBrush="#202A48" BorderThickness="0,1,0,0">
                <Grid Margin="24,0">
                    <TextBlock x:Name="CopyStatus" Text="Read-only device inventory"
                               VerticalAlignment="Center" Foreground="#64748B" FontSize="11"/>
                    <StackPanel Orientation="Horizontal" HorizontalAlignment="Right"
                                VerticalAlignment="Center">
                        <Button x:Name="CopyButton" Content="COPY TABLE"
                                Style="{StaticResource ActionButton}" Margin="0,0,10,0"/>
                        <Button x:Name="CloseButton" Content="DONE"
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

    $grid = $window.FindName('DeviceGrid')
    $emptyState = $window.FindName('EmptyState')
    $summaryText = $window.FindName('SummaryText')
    $deviceCount = $window.FindName('DeviceCount')
    $copyButton = $window.FindName('CopyButton')
    $copyStatus = $window.FindName('CopyStatus')

    $grid.ItemsSource = $devices
    $deviceCount.Text = [string]$devices.Count
    $summaryText.Text = 'Windows currently reports these Plug and Play entries under USB\. Long locations and paths wrap automatically.'
    if ($devices.Count -eq 0) {
        $grid.Visibility = 'Collapsed'
        $emptyState.Visibility = 'Visible'
        $copyButton.IsEnabled = $false
        $copyButton.Opacity = 0.45
    }

    $copyButton.Add_Click({
        try {
            $lines = New-Object System.Collections.Generic.List[string]
            $lines.Add("Device`tLocation`tUSB Path")
            foreach ($device in $devices) {
                $lines.Add(("{0}`t{1}`t{2}" -f $device.Device, $device.Location, $device.USBPath))
            }
            [Windows.Clipboard]::SetText(($lines -join [Environment]::NewLine))
            $copyStatus.Text = "Copied $($devices.Count) device row(s) to the clipboard."
            $copyStatus.Foreground = '#34D399'
        }
        catch {
            $copyStatus.Text = 'Windows could not copy the table to the clipboard.'
            $copyStatus.Foreground = '#F59E0B'
        }
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
    $window.Width = [Math]::Min(1120, [Math]::Max(760, $workArea.Width - 40))
    $window.Height = [Math]::Min(680, [Math]::Max(480, $workArea.Height - 40))
    $window.Add_ContentRendered({ $window.Activate() })
    [void]$window.ShowDialog()

    Write-Host "[SUCCESS] Displayed $($devices.Count) present USB device entries."
}
catch {
    try {
        [Windows.MessageBox]::Show(
            $_.Exception.Message,
            'Connected USB Devices',
            [Windows.MessageBoxButton]::OK,
            [Windows.MessageBoxImage]::Error
        ) | Out-Null
    }
    catch { }

    Write-Host "[ERROR] $($_.Exception.Message)"
    throw
}
