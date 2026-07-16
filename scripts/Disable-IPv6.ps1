#Requires -Version 5.1
<#
.SYNOPSIS
    Disables IPv6 components on Windows by using Microsoft's DisabledComponents policy.

.DESCRIPTION
    Sets HKLM\SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters\DisabledComponents
    to 0xFF. A restart is required before the change is fully applied.

    Windows retains the IPv6 loopback interface internally. This script does not unbind
    IPv6 from each network adapter because Microsoft considers that configuration
    unsupported on modern Windows versions.
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
        throw 'This script must be run with administrator rights or as SYSTEM.'
    }
}

try {
    Assert-Administrator

    $registryPath = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters'
    $valueName    = 'DisabledComponents'
    $disabledValue = 0xFF

    if (-not (Test-Path -LiteralPath $registryPath)) {
        New-Item -Path $registryPath -Force | Out-Null
    }

    $existing = Get-ItemProperty -Path $registryPath -Name $valueName -ErrorAction SilentlyContinue
    if ($null -ne $existing -and [int64]$existing.$valueName -eq $disabledValue) {
        Write-Log INFO 'IPv6 is already configured as disabled.'
    }
    else {
        New-ItemProperty -Path $registryPath `
                         -Name $valueName `
                         -PropertyType DWord `
                         -Value $disabledValue `
                         -Force | Out-Null
        Write-Log INFO 'DisabledComponents was set to 0xFF.'
    }

    $verified = (Get-ItemProperty -Path $registryPath -Name $valueName).$valueName
    if ([int64]$verified -ne $disabledValue) {
        throw "Verification failed. DisabledComponents is $verified instead of 255."
    }

    Write-Log SUCCESS 'IPv6 components have been configured as disabled.'
    Write-Log WARNING 'Restart Windows before relying on this change.'
    Write-Log WARNING 'IPv6 loopback (::1) remains available internally by Windows design.'
    return
}
catch {
    Write-Log ERROR $_.Exception.Message
    throw
}
