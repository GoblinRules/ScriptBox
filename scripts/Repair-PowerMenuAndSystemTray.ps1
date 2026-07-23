#Requires -Version 5.1
<#
.SYNOPSIS
    Repairs Windows shell policy after the legacy Hide Shutdown Options script.

.DESCRIPTION
    Restores the four Windows PolicyManager Start defaults changed by older
    ScriptBox releases and removes ScriptBox's NoClose policy from existing
    non-special user profiles and the Default user profile.

    ScriptBox never set the NoTrayItemsDisplay policy that directly hides the
    notification area, so this repair leaves unrelated organization-managed
    notification-area policy unchanged. A sign-out or restart reloads the
    affected Windows 11 shell surfaces.
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
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)

    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'This script must be run with administrator rights.'
    }
}

function Remove-NoClosePolicyInHive {
    param(
        [Parameter(Mandatory = $true)]
        [string]$HiveRoot,

        [Parameter(Mandatory = $true)]
        [string]$ProfileLabel
    )

    $policyPath = "$HiveRoot\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer"
    $policy = Get-ItemProperty -LiteralPath $policyPath -ErrorAction SilentlyContinue
    if ($null -eq $policy -or $null -eq $policy.PSObject.Properties['NoClose']) {
        Write-Log INFO "No ScriptBox power-menu policy was present for profile: $ProfileLabel"
        return
    }

    Remove-ItemProperty -LiteralPath $policyPath -Name 'NoClose' -Force
    Write-Log INFO "Power-menu policy removed for profile: $ProfileLabel"
}

function Remove-NoClosePolicyInOfflineHive {
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
        Remove-NoClosePolicyInHive `
            -HiveRoot "Registry::HKEY_USERS\$MountName" `
            -ProfileLabel $ProfileLabel
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

    # ScriptBox versions through 2.1.11 changed these OS policy defaults from
    # their documented value of 0 to 1. Restore only the exact legacy values.
    foreach ($option in @('HideShutDown', 'HideSleep', 'HideHibernate', 'HideRestart')) {
        $path = "HKLM:\SOFTWARE\Microsoft\PolicyManager\default\Start\$option"
        $policy = Get-ItemProperty -LiteralPath $path -ErrorAction SilentlyContinue
        if ($null -eq $policy -or $null -eq $policy.PSObject.Properties['value']) {
            Write-Log INFO "Windows policy default was not present: $option"
            continue
        }

        if ([int]$policy.value -eq 1) {
            Set-ItemProperty -LiteralPath $path -Name 'value' -Type DWord -Value 0
            Write-Log INFO "Windows policy default restored: $option"
        }
        else {
            Write-Log INFO "Windows policy default was already safe: $option"
        }
    }

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
            Remove-NoClosePolicyInHive -HiveRoot $loadedHive -ProfileLabel $profile.LocalPath
            continue
        }

        $mountName = "ScriptBox_RepairUser_$PID`_$index"
        try {
            Remove-NoClosePolicyInOfflineHive `
                -NtUserDat (Join-Path $profile.LocalPath 'NTUSER.DAT') `
                -MountName $mountName `
                -ProfileLabel $profile.LocalPath
        }
        catch {
            Write-Log WARNING "Could not repair profile '$($profile.LocalPath)': $($_.Exception.Message)"
        }
    }

    try {
        Remove-NoClosePolicyInOfflineHive `
            -NtUserDat 'C:\Users\Default\NTUSER.DAT' `
            -MountName "ScriptBox_RepairDefault_$PID" `
            -ProfileLabel 'Default User'
    }
    catch {
        Write-Log WARNING "Could not repair the Default User profile: $($_.Exception.Message)"
    }

    Write-Log SUCCESS 'Legacy ScriptBox power and shell policy changes were removed.'
    Write-Log WARNING 'Sign out or restart Windows to reload the Start menu, power menu, and notification area.'
    return
}
catch {
    Write-Log ERROR $_.Exception.Message
    throw
}
