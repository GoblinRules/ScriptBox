#Requires -Version 5.1
<#
.SYNOPSIS
    Allows password sign-in for Microsoft accounts without removing an
    existing Windows Hello PIN.

.DESCRIPTION
    Sets the machine-wide DevicePasswordLessBuildVersion value to 0 and
    verifies the saved value. Administrator rights are required.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$registryPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\PasswordLess\Device'
$valueName = 'DevicePasswordLessBuildVersion'

function Assert-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'This script must be run with administrator rights.'
    }
}

try {
    Assert-Administrator

    if (-not (Test-Path -LiteralPath $registryPath)) {
        New-Item -Path $registryPath -Force | Out-Null
    }

    New-ItemProperty -Path $registryPath -Name $valueName -PropertyType DWord -Value 0 -Force | Out-Null
    $currentValue = Get-ItemPropertyValue -LiteralPath $registryPath -Name $valueName

    if ($currentValue -ne 0) {
        throw 'The registry value was not changed successfully.'
    }

    Write-Host '[SUCCESS] Password sign-in is permitted.'
    Write-Host '[INFO] Existing Windows Hello PINs were not removed.'
}
catch {
    Write-Host "[ERROR] Failed to allow password sign-in: $($_.Exception.Message)"
    throw
}
