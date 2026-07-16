#Requires -Version 5.1
<#
.SYNOPSIS
    Configures Windows Update for completely manual download and installation.

.DESCRIPTION
    Disables Automatic Updates through the supported policy registry location while
    keeping the Windows Update service available for a user or administrator to open
    Settings and manually select Check for updates.

    This script also removes conflicting scheduling and deferral values previously
    applied by the security-focused update script.
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

function Remove-PolicyValue {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if (Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue) {
        Remove-ItemProperty -Path $Path -Name $Name -Force -ErrorAction SilentlyContinue
        Write-Log INFO "Removed conflicting policy value: $Name"
    }
}

try {
    Assert-Administrator

    $windowsUpdatePath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
    $automaticUpdatePath = Join-Path $windowsUpdatePath 'AU'

    if (-not (Test-Path -LiteralPath $windowsUpdatePath)) {
        New-Item -Path $windowsUpdatePath -Force | Out-Null
    }
    if (-not (Test-Path -LiteralPath $automaticUpdatePath)) {
        New-Item -Path $automaticUpdatePath -Force | Out-Null
    }

    # Remove policies from the previous security-focused configuration so this
    # script has one clear purpose: no automatic download or installation.
    $windowsUpdateValuesToRemove = @(
        'DeferFeatureUpdates',
        'DeferFeatureUpdatesPeriodInDays',
        'DeferQualityUpdates',
        'DeferQualityUpdatesPeriodInDays',
        'ExcludeWUDriversInQualityUpdate',
        'ManagePreviewBuilds',
        'ManagePreviewBuildsPolicyValue',
        'AllowOptionalContent',
        'DisableWUfBSafeguards'
    )

    foreach ($name in $windowsUpdateValuesToRemove) {
        Remove-PolicyValue -Path $windowsUpdatePath -Name $name
    }

    $automaticValuesToRemove = @(
        'ScheduledInstallDay',
        'ScheduledInstallTime',
        'ScheduledInstallEveryWeek',
        'RescheduleWaitTime',
        'AlwaysAutoRebootAtScheduledTime',
        'AutomaticMaintenanceEnabled'
    )

    foreach ($name in $automaticValuesToRemove) {
        Remove-PolicyValue -Path $automaticUpdatePath -Name $name
    }

    # NoAutoUpdate=1 disables automatic downloading and installation.
    New-ItemProperty -Path $automaticUpdatePath `
                     -Name 'NoAutoUpdate' `
                     -PropertyType DWord `
                     -Value 1 `
                     -Force | Out-Null

    # AUOptions=2 remains as a safe fallback: notify before download/install.
    New-ItemProperty -Path $automaticUpdatePath `
                     -Name 'AUOptions' `
                     -PropertyType DWord `
                     -Value 2 `
                     -Force | Out-Null

    New-ItemProperty -Path $automaticUpdatePath `
                     -Name 'NoAutoRebootWithLoggedOnUsers' `
                     -PropertyType DWord `
                     -Value 1 `
                     -Force | Out-Null

    Write-Log INFO 'Automatic Windows Update download and installation disabled.'

    # Do not disable these services: manual Check for updates requires them.
    foreach ($serviceName in @('wuauserv', 'BITS')) {
        try {
            Set-Service -Name $serviceName -StartupType Manual -ErrorAction Stop
            Write-Log INFO "$serviceName startup type set to Manual."
        }
        catch {
            Write-Log WARNING "$serviceName startup type could not be changed. $($_.Exception.Message)"
        }
    }

    $gpOutput = & gpupdate.exe /target:computer /force 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Log INFO 'Computer policy refresh completed.'
    }
    else {
        Write-Log WARNING "Policy refresh returned exit code $LASTEXITCODE. $($gpOutput -join ' ')"
    }

    $verification = Get-ItemProperty -Path $automaticUpdatePath
    if ([int]$verification.NoAutoUpdate -ne 1) {
        throw 'NoAutoUpdate could not be verified as enabled.'
    }

    Write-Log SUCCESS 'Windows Update is now manual only.'
    Write-Log INFO 'Updates can still be installed manually from Settings > Windows Update > Check for updates.'
    Write-Log WARNING 'Manual-only updates increase security risk if nobody regularly checks and installs security fixes.'
    return
}
catch {
    Write-Log ERROR $_.Exception.Message
    throw
}
