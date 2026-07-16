#Requires -Version 5.1
<#
.SYNOPSIS
    Locks Windows after 10 minutes with no keyboard or mouse activity.

.DESCRIPTION
    Configures the computer-wide Interactive logon: Machine inactivity limit to
    600 seconds. It also applies secure screen-saver policies to currently loaded
    user profiles and the Default user profile used for future accounts.

    This contains no application exclusions: an idle signed-in session is locked
    after 10 minutes regardless of which applications are open.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$timeoutSeconds = 600

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

function Set-RegistryString {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Value
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -Path $Path -Force | Out-Null
    }

    New-ItemProperty -Path $Path -Name $Name -PropertyType String -Value $Value -Force | Out-Null
}

function Set-UserLockPolicy {
    param(
        [Parameter(Mandatory = $true)][string]$HiveRoot,
        [Parameter(Mandatory = $true)][string]$ProfileName
    )

    $policyPath = Join-Path $HiveRoot 'Software\Policies\Microsoft\Windows\Control Panel\Desktop'
    Set-RegistryString -Path $policyPath -Name 'ScreenSaveActive'   -Value '1'
    Set-RegistryString -Path $policyPath -Name 'ScreenSaverIsSecure' -Value '1'
    Set-RegistryString -Path $policyPath -Name 'ScreenSaveTimeOut' -Value ([string]$timeoutSeconds)
    Write-Log INFO "Secure 10-minute screen lock policy applied to $ProfileName."
}

try {
    Assert-Administrator

    $systemPolicyPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
    if (-not (Test-Path -LiteralPath $systemPolicyPath)) {
        New-Item -Path $systemPolicyPath -Force | Out-Null
    }

    New-ItemProperty -Path $systemPolicyPath `
                     -Name 'InactivityTimeoutSecs' `
                     -PropertyType DWord `
                     -Value $timeoutSeconds `
                     -Force | Out-Null
    Write-Log INFO 'Computer inactivity limit set to 600 seconds.'

    $loadedUserSids = Get-ChildItem -Path 'Registry::HKEY_USERS' -ErrorAction SilentlyContinue |
        Where-Object {
            $_.PSChildName -match '^S-1-5-21-.+' -and
            $_.PSChildName -notmatch '_Classes$'
        }

    foreach ($sidKey in $loadedUserSids) {
        Set-UserLockPolicy -HiveRoot $sidKey.PSPath -ProfileName $sidKey.PSChildName
    }

    $defaultHiveFile = 'C:\Users\Default\NTUSER.DAT'
    $temporaryHiveName = 'ScriptBoxDefaultUser'
    $temporaryHiveRoot = "Registry::HKEY_USERS\$temporaryHiveName"
    $hiveLoaded = $false

    if (Test-Path -LiteralPath $defaultHiveFile) {
        try {
            & reg.exe load "HKU\$temporaryHiveName" $defaultHiveFile | Out-Null
            if ($LASTEXITCODE -eq 0) {
                $hiveLoaded = $true
                Set-UserLockPolicy -HiveRoot $temporaryHiveRoot -ProfileName 'Default user profile'
            }
            else {
                Write-Log WARNING 'The Default user registry hive could not be loaded.'
            }
        }
        finally {
            if ($hiveLoaded) {
                [gc]::Collect()
                [gc]::WaitForPendingFinalizers()
                & reg.exe unload "HKU\$temporaryHiveName" | Out-Null
                if ($LASTEXITCODE -ne 0) {
                    Write-Log WARNING 'The temporary Default user registry hive could not be unloaded cleanly.'
                }
            }
        }
    }

    $gpOutput = & gpupdate.exe /target:computer /force 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Log INFO 'Computer policy refresh completed.'
    }
    else {
        Write-Log WARNING "Policy refresh returned exit code $LASTEXITCODE. $($gpOutput -join ' ')"
    }

    $verified = (Get-ItemProperty -Path $systemPolicyPath -Name 'InactivityTimeoutSecs').InactivityTimeoutSecs
    if ([int]$verified -ne $timeoutSeconds) {
        throw 'The inactivity timeout registry value could not be verified.'
    }

    Write-Log SUCCESS 'Windows is configured to lock after 10 minutes of inactivity.'
    Write-Log WARNING 'A restart or sign-out/sign-in is recommended before testing the new timeout.'
    return
}
catch {
    Write-Log ERROR $_.Exception.Message
    throw
}
