#Requires -Version 5.1
<#
.SYNOPSIS
    Configures a Windows PC to remain awake and available for remote access.

.DESCRIPTION
    Applies the settings to the currently active power plan for both AC and
    battery operation:
      - Never turn off the display
      - Never sleep
      - Never hibernate
      - Disable hybrid sleep
      - Power button does nothing
      - Closing a laptop lid does nothing
      - Disable the hidden unattended sleep timeout
      - Disable hibernation system-wide
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
        throw 'This script must be run with administrator rights.'
    }
}

function Invoke-PowerCfg {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,

        [Parameter(Mandatory = $true)]
        [string]$Description,

        [switch]$AllowUnsupported
    )

    $output = & powercfg.exe @Arguments 2>&1
    $exitCode = $LASTEXITCODE

    if ($exitCode -ne 0) {
        $detail = ($output | Out-String).Trim()
        if ($AllowUnsupported) {
            Write-Log WARNING "$Description was not applied on this hardware. $detail"
            return
        }

        throw "$Description failed with exit code $exitCode. $detail"
    }

    Write-Log INFO $Description
}

try {
    Assert-Administrator

    # Standard timeout controls.
    Invoke-PowerCfg -Arguments @('/change', 'monitor-timeout-ac', '0')   -Description 'Display timeout on AC set to Never.'
    Invoke-PowerCfg -Arguments @('/change', 'monitor-timeout-dc', '0')   -Description 'Display timeout on battery set to Never.'
    Invoke-PowerCfg -Arguments @('/change', 'standby-timeout-ac', '0')   -Description 'Sleep timeout on AC set to Never.'
    Invoke-PowerCfg -Arguments @('/change', 'standby-timeout-dc', '0')   -Description 'Sleep timeout on battery set to Never.'
    Invoke-PowerCfg -Arguments @('/change', 'hibernate-timeout-ac', '0') -Description 'Hibernate timeout on AC set to Never.'
    Invoke-PowerCfg -Arguments @('/change', 'hibernate-timeout-dc', '0') -Description 'Hibernate timeout on battery set to Never.'

    # Power button and lid actions: 0 = Do nothing.
    Invoke-PowerCfg -Arguments @('/setacvalueindex', 'SCHEME_CURRENT', 'SUB_BUTTONS', 'PBUTTONACTION', '0') -Description 'Power button action on AC set to Do nothing.'
    Invoke-PowerCfg -Arguments @('/setdcvalueindex', 'SCHEME_CURRENT', 'SUB_BUTTONS', 'PBUTTONACTION', '0') -Description 'Power button action on battery set to Do nothing.'
    Invoke-PowerCfg -Arguments @('/setacvalueindex', 'SCHEME_CURRENT', 'SUB_BUTTONS', 'LIDACTION', '0')     -Description 'Lid-close action on AC set to Do nothing.' -AllowUnsupported
    Invoke-PowerCfg -Arguments @('/setdcvalueindex', 'SCHEME_CURRENT', 'SUB_BUTTONS', 'LIDACTION', '0')     -Description 'Lid-close action on battery set to Do nothing.' -AllowUnsupported

    # Disable hybrid sleep. Some hardware/editions do not expose the setting.
    Invoke-PowerCfg -Arguments @('/setacvalueindex', 'SCHEME_CURRENT', 'SUB_SLEEP', 'HYBRIDSLEEP', '0') -Description 'Hybrid sleep on AC disabled.' -AllowUnsupported
    Invoke-PowerCfg -Arguments @('/setdcvalueindex', 'SCHEME_CURRENT', 'SUB_SLEEP', 'HYBRIDSLEEP', '0') -Description 'Hybrid sleep on battery disabled.' -AllowUnsupported

    # Hidden setting: System unattended sleep timeout = 0.
    $subSleepGuid          = '238c9fa8-0aad-41ed-83f4-97be242c8f20'
    $unattendedTimeoutGuid = '7bc4a2f9-d8fc-4469-b07b-33eb785aaca0'
    Invoke-PowerCfg -Arguments @('/setacvalueindex', 'SCHEME_CURRENT', $subSleepGuid, $unattendedTimeoutGuid, '0') -Description 'Unattended sleep timeout on AC disabled.' -AllowUnsupported
    Invoke-PowerCfg -Arguments @('/setdcvalueindex', 'SCHEME_CURRENT', $subSleepGuid, $unattendedTimeoutGuid, '0') -Description 'Unattended sleep timeout on battery disabled.' -AllowUnsupported

    Invoke-PowerCfg -Arguments @('/setactive', 'SCHEME_CURRENT') -Description 'Updated active power plan applied.'
    Invoke-PowerCfg -Arguments @('/hibernate', 'off')            -Description 'Hibernation disabled system-wide.'

    Write-Log SUCCESS 'Power management settings were applied successfully.'
    Write-Log WARNING 'The display will remain on and a laptop will continue running with its lid closed, including while on battery.'
    return
}
catch {
    Write-Log ERROR $_.Exception.Message
    throw
}
