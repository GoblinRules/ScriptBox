#Requires -Version 5.1
<#
.SYNOPSIS
    Hides and blocks access to Shutdown, Restart, Sleep, and Hibernate options.

.DESCRIPTION
    Applies the user policy to all existing non-special Windows profiles and
    the Default profile. This is the documented NoClose user policy; the
    script does not modify Windows PolicyManager defaults or notification-area
    policy.

    The script is safe to run repeatedly. A user may need to sign out and back
    in before every interface reflects the change.
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

function Set-NoClosePolicyInHive {
    param(
        [Parameter(Mandatory = $true)]
        [string]$HiveRoot,

        [Parameter(Mandatory = $true)]
        [string]$ProfileLabel
    )

    $policyPath = "$HiveRoot\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer"
    if (-not (Test-Path -LiteralPath $policyPath)) {
        New-Item -Path $policyPath -Force | Out-Null
    }

    New-ItemProperty -Path $policyPath -Name 'NoClose' -PropertyType DWord -Value 1 -Force | Out-Null
    Write-Log INFO "Shutdown commands hidden for profile: $ProfileLabel"
}

function Set-NoClosePolicyInOfflineHive {
    param(
        [Parameter(Mandatory = $true)]
        [string]$NtUserDat,

        [Parameter(Mandatory = $true)]
        [string]$MountName,

        [Parameter(Mandatory = $true)]
        [string]$ProfileLabel
    )

    if (-not (Test-Path -LiteralPath $NtUserDat)) {
        Write-Log WARNING "NTUSER.DAT was not found for profile: $ProfileLabel"
        return
    }

    $loaded = $false
    try {
        $loadOutput = & reg.exe load "HKU\$MountName" "$NtUserDat" 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw (($loadOutput | Out-String).Trim())
        }

        $loaded = $true
        Set-NoClosePolicyInHive -HiveRoot "Registry::HKEY_USERS\$MountName" -ProfileLabel $ProfileLabel
    }
    finally {
        if ($loaded) {
            [GC]::Collect()
            [GC]::WaitForPendingFinalizers()
            $unloadOutput = & reg.exe unload "HKU\$MountName" 2>&1
            if ($LASTEXITCODE -ne 0) {
                Write-Log WARNING "Could not unload the temporary registry hive for '$ProfileLabel': $(($unloadOutput | Out-String).Trim())"
            }
        }
    }
}

try {
    Assert-Administrator

    # Apply the traditional NoClose user policy to every real local profile.
    $profiles = Get-CimInstance -ClassName Win32_UserProfile | Where-Object {
        -not $_.Special -and
        -not [string]::IsNullOrWhiteSpace($_.SID) -and
        -not [string]::IsNullOrWhiteSpace($_.LocalPath)
    }

    $index = 0
    foreach ($profile in $profiles) {
        $index++
        $loadedHive = "Registry::HKEY_USERS\$($profile.SID)"

        if (Test-Path -LiteralPath $loadedHive) {
            Set-NoClosePolicyInHive -HiveRoot $loadedHive -ProfileLabel $profile.LocalPath
            continue
        }

        $mountName = "ScriptBox_User_$index"
        try {
            Set-NoClosePolicyInOfflineHive `
                -NtUserDat (Join-Path $profile.LocalPath 'NTUSER.DAT') `
                -MountName $mountName `
                -ProfileLabel $profile.LocalPath
        }
        catch {
            Write-Log WARNING "Could not update profile '$($profile.LocalPath)': $($_.Exception.Message)"
        }
    }

    # Apply to users created after this script is run.
    $defaultNtUser = 'C:\Users\Default\NTUSER.DAT'
    try {
        Set-NoClosePolicyInOfflineHive -NtUserDat $defaultNtUser -MountName 'ScriptBox_DefaultUser' -ProfileLabel 'Default User'
    }
    catch {
        Write-Log WARNING "Could not update the Default User profile: $($_.Exception.Message)"
    }

    Write-Log SUCCESS 'Shutdown, Restart, Sleep, and Hibernate commands have been hidden for existing and future users.'
    Write-Log WARNING 'Users who are currently signed in may need to sign out and back in before the change appears everywhere.'
    return
}
catch {
    Write-Log ERROR $_.Exception.Message
    throw
}
