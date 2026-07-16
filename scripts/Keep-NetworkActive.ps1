#Requires -Version 5.1
<#
.SYNOPSIS
    Prevents physical Wi-Fi and Ethernet adapters from entering power-saving states.

.DESCRIPTION
    Configures the active Windows power plan and supported physical network-adapter
    options so networking remains available while the computer is locked.

    Changes include:
      - Wi-Fi power saving set to Maximum Performance
      - PCI Express Link State Power Management disabled
      - USB selective suspend disabled for USB network adapters
      - Modern Standby network connectivity enabled where supported
      - Adapter selective suspend and device sleep disabled where supported
      - "Allow the computer to turn off this device" disabled where supported

    A log is written to C:\Tools\Logs\keep-online-power-settings.log.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$logPath = 'C:\Tools\Logs\keep-online-power-settings.log'

function Initialize-Log {
    $folder = Split-Path -Path $logPath -Parent
    if (-not (Test-Path -LiteralPath $folder)) {
        New-Item -Path $folder -ItemType Directory -Force | Out-Null
    }

    Add-Content -Path $logPath -Value "`r`n===== $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ====="
}

function Write-Log {
    param(
        [ValidateSet('INFO', 'SUCCESS', 'WARNING', 'ERROR')]
        [string]$Level,
        [string]$Message
    )

    $line = "[$Level] $Message"
    Write-Host $line
    Add-Content -Path $logPath -Value $line -ErrorAction SilentlyContinue
}

function Assert-Administrator {
    $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)

    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'This script must be run with administrator rights or as SYSTEM.'
    }
}

function Invoke-PowerCfg {
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$Description,
        [switch]$AllowUnsupported
    )

    $output = & powercfg.exe @Arguments 2>&1
    $exitCode = $LASTEXITCODE

    if ($exitCode -ne 0) {
        $detail = ($output | Out-String).Trim()
        if ($AllowUnsupported) {
            Write-Log WARNING "$Description was not supported on this device. $detail"
            return $false
        }

        throw "$Description failed with exit code $exitCode. $detail"
    }

    Write-Log INFO $Description
    return $true
}

function Set-AdapterPowerSetting {
    param(
        [Parameter(Mandatory = $true)][string]$AdapterName,
        [Parameter(Mandatory = $true)][string]$PropertyName,
        [Parameter(Mandatory = $true)][ValidateSet('Enabled', 'Disabled')][string]$Value,
        [Parameter(Mandatory = $true)][System.Management.Automation.CommandInfo]$CommandInfo
    )

    if (-not $CommandInfo.Parameters.ContainsKey($PropertyName)) {
        Write-Log WARNING "$PropertyName is unavailable on this Windows version for adapter '$AdapterName'."
        return
    }

    $parameters = @{
        Name        = $AdapterName
        ErrorAction = 'Stop'
    }

    if ($CommandInfo.Parameters.ContainsKey('NoRestart')) {
        $parameters['NoRestart'] = $true
    }

    $parameters[$PropertyName] = $Value

    try {
        Set-NetAdapterPowerManagement @parameters | Out-Null
        Write-Log INFO "${AdapterName}: $PropertyName set to $Value."
    }
    catch {
        Write-Log WARNING "${AdapterName}: $PropertyName could not be changed. $($_.Exception.Message)"
    }
}

try {
    Assert-Administrator
    Initialize-Log

    # Power setting GUIDs are used because aliases are not exposed on every PC.
    $wirelessSubgroup       = '19cbb8fa-5279-450e-9fac-8a3d5fedd0c1'
    $wirelessPowerSetting   = '12bbebe6-58d6-4636-95bb-3217ef867c1a'
    $pciExpressSubgroup     = '501a4d13-42af-4429-9fd1-a8218c268e20'
    $linkStateSetting       = 'ee12f906-d277-404b-b6da-e5fa1a576df5'
    $usbSubgroup            = '2a737441-1930-4402-8d77-b2bebba308a3'
    $usbSelectiveSuspend    = '48e6b7a6-50f5-4782-a5d4-53bb8f07e226'
    $sleepSubgroup          = '238c9fa8-0aad-41ed-83f4-97be242c8f20'
    $networkInStandby       = 'f15576e8-98b7-4186-b944-eafa664402d9'

    # 0 = Maximum Performance for Wi-Fi power saving.
    Invoke-PowerCfg -Arguments @('/setacvalueindex', 'SCHEME_CURRENT', $wirelessSubgroup, $wirelessPowerSetting, '0') -Description 'Wi-Fi power saving on AC set to Maximum Performance.' -AllowUnsupported | Out-Null
    Invoke-PowerCfg -Arguments @('/setdcvalueindex', 'SCHEME_CURRENT', $wirelessSubgroup, $wirelessPowerSetting, '0') -Description 'Wi-Fi power saving on battery set to Maximum Performance.' -AllowUnsupported | Out-Null

    # 0 = Off for PCIe Link State Power Management.
    Invoke-PowerCfg -Arguments @('/setacvalueindex', 'SCHEME_CURRENT', $pciExpressSubgroup, $linkStateSetting, '0') -Description 'PCI Express Link State Power Management on AC disabled.' -AllowUnsupported | Out-Null
    Invoke-PowerCfg -Arguments @('/setdcvalueindex', 'SCHEME_CURRENT', $pciExpressSubgroup, $linkStateSetting, '0') -Description 'PCI Express Link State Power Management on battery disabled.' -AllowUnsupported | Out-Null

    # 0 = Disabled for USB selective suspend.
    Invoke-PowerCfg -Arguments @('/setacvalueindex', 'SCHEME_CURRENT', $usbSubgroup, $usbSelectiveSuspend, '0') -Description 'USB selective suspend on AC disabled.' -AllowUnsupported | Out-Null
    Invoke-PowerCfg -Arguments @('/setdcvalueindex', 'SCHEME_CURRENT', $usbSubgroup, $usbSelectiveSuspend, '0') -Description 'USB selective suspend on battery disabled.' -AllowUnsupported | Out-Null

    # 1 = Enable network connectivity during Modern Standby where the setting exists.
    Invoke-PowerCfg -Arguments @('/setacvalueindex', 'SCHEME_CURRENT', $sleepSubgroup, $networkInStandby, '1') -Description 'Network connectivity during standby on AC enabled.' -AllowUnsupported | Out-Null
    Invoke-PowerCfg -Arguments @('/setdcvalueindex', 'SCHEME_CURRENT', $sleepSubgroup, $networkInStandby, '1') -Description 'Network connectivity during standby on battery enabled.' -AllowUnsupported | Out-Null

    Invoke-PowerCfg -Arguments @('/setactive', 'SCHEME_CURRENT') -Description 'Updated active power plan applied.' | Out-Null

    $setPowerCommand = Get-Command -Name 'Set-NetAdapterPowerManagement' -ErrorAction SilentlyContinue
    $getAdapterCommand = Get-Command -Name 'Get-NetAdapter' -ErrorAction SilentlyContinue

    if ($null -eq $setPowerCommand -or $null -eq $getAdapterCommand) {
        Write-Log WARNING 'The NetAdapter PowerShell module is unavailable. Power-plan settings were still applied.'
    }
    else {
        $physicalAdapters = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue)

        if ($physicalAdapters.Count -eq 0) {
            Write-Log WARNING 'No physical network adapters were returned by Get-NetAdapter.'
        }
        else {
            foreach ($adapter in $physicalAdapters) {
                Write-Log INFO "Configuring physical adapter: $($adapter.Name) [$($adapter.InterfaceDescription)]"
                Set-AdapterPowerSetting -AdapterName $adapter.Name -PropertyName 'AllowComputerToTurnOffDevice' -Value Disabled -CommandInfo $setPowerCommand
                Set-AdapterPowerSetting -AdapterName $adapter.Name -PropertyName 'DeviceSleepOnDisconnect'       -Value Disabled -CommandInfo $setPowerCommand
                Set-AdapterPowerSetting -AdapterName $adapter.Name -PropertyName 'SelectiveSuspend'              -Value Disabled -CommandInfo $setPowerCommand
                Set-AdapterPowerSetting -AdapterName $adapter.Name -PropertyName 'D0PacketCoalescing'             -Value Disabled -CommandInfo $setPowerCommand
            }
        }
    }

    Write-Log SUCCESS 'Network power-saving restrictions were applied successfully.'
    Write-Log WARNING 'These settings apply whenever this power plan is active, not only while Windows is locked.'
    Write-Log WARNING 'Battery usage may increase on laptops.'
    Write-Log INFO "Log saved to $logPath"
    return
}
catch {
    if (-not (Test-Path -LiteralPath (Split-Path -Path $logPath -Parent))) {
        New-Item -Path (Split-Path -Path $logPath -Parent) -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
    }
    Write-Log ERROR $_.Exception.Message
    throw
}
