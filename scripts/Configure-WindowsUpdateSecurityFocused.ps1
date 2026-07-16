#Requires -Version 5.1
<#
.SYNOPSIS
    Applies a security-focused Windows Update configuration.

.DESCRIPTION
    Windows 10 and Windows 11 quality updates are cumulative, so Windows does
    not provide a supported policy that installs only the security portions of
    a monthly quality update.

    This script applies the closest supported configuration:
      - Install quality/security updates without a deferral
      - Do not automatically receive optional preview updates
      - Exclude driver updates from normal Windows quality updates
      - Disable Windows Insider preview builds
      - Defer feature upgrades for 365 days
      - Keep safeguard holds enabled
      - Automatically download and schedule approved updates
      - Prevent automatic restart while a user is signed in
#>

[CmdletBinding()]
param(
    [ValidateRange(0, 365)]
    [int]$FeatureUpdateDeferralDays = 365,

    [ValidateRange(0, 30)]
    [int]$QualityUpdateDeferralDays = 0
)

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

function Set-PolicyDWord {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [int]$Value
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -Path $Path -Force | Out-Null
    }

    New-ItemProperty -Path $Path -Name $Name -PropertyType DWord -Value $Value -Force | Out-Null
    Write-Log INFO "$Name = $Value"
}

try {
    Assert-Administrator

    $windowsUpdatePath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
    $automaticUpdatePath = Join-Path $windowsUpdatePath 'AU'

    # Feature upgrades are delayed while monthly quality/security updates are
    # offered immediately by default.
    Set-PolicyDWord -Path $windowsUpdatePath -Name 'DeferFeatureUpdates' -Value 1
    Set-PolicyDWord -Path $windowsUpdatePath -Name 'DeferFeatureUpdatesPeriodInDays' -Value $FeatureUpdateDeferralDays
    Set-PolicyDWord -Path $windowsUpdatePath -Name 'DeferQualityUpdates' -Value 1
    Set-PolicyDWord -Path $windowsUpdatePath -Name 'DeferQualityUpdatesPeriodInDays' -Value $QualityUpdateDeferralDays

    # Do not automatically receive optional cumulative previews or controlled
    # feature rollouts. Supported Windows builds interpret 0 as disabled.
    Set-PolicyDWord -Path $windowsUpdatePath -Name 'SetAllowOptionalContent' -Value 0

    # Keep firmware/driver changes out of standard Windows quality updates.
    Set-PolicyDWord -Path $windowsUpdatePath -Name 'ExcludeWUDriversInQualityUpdate' -Value 1

    # Disable Insider Preview builds and retain Microsoft's compatibility holds.
    Set-PolicyDWord -Path $windowsUpdatePath -Name 'ManagePreviewBuilds' -Value 0
    Set-PolicyDWord -Path $windowsUpdatePath -Name 'DisableWUfBSafeguards' -Value 0

    # Enable automatic update detection/download and scheduled installation.
    Set-PolicyDWord -Path $automaticUpdatePath -Name 'NoAutoUpdate' -Value 0
    Set-PolicyDWord -Path $automaticUpdatePath -Name 'AUOptions' -Value 4
    Set-PolicyDWord -Path $automaticUpdatePath -Name 'ScheduledInstallDay' -Value 0
    Set-PolicyDWord -Path $automaticUpdatePath -Name 'ScheduledInstallTime' -Value 3
    Set-PolicyDWord -Path $automaticUpdatePath -Name 'NoAutoRebootWithLoggedOnUsers' -Value 1

    # Remove stale pause dates so security/quality updates are not accidentally
    # held back by a previous manual or policy pause.
    foreach ($name in @(
        'PauseFeatureUpdatesStartTime',
        'PauseQualityUpdatesStartTime',
        'PauseFeatureUpdates',
        'PauseQualityUpdates'
    )) {
        Remove-ItemProperty -Path $windowsUpdatePath -Name $name -ErrorAction SilentlyContinue
    }

    Set-Service -Name 'wuauserv' -StartupType Manual -ErrorAction SilentlyContinue
    Start-Service -Name 'wuauserv' -ErrorAction SilentlyContinue

    # Ask Windows Update to rescan. These commands vary by Windows build, so a
    # failure is informational rather than fatal.
    $usoClient = Join-Path $env:SystemRoot 'System32\UsoClient.exe'
    if (Test-Path -LiteralPath $usoClient) {
        Start-Process -FilePath $usoClient -ArgumentList 'RefreshSettings' -WindowStyle Hidden -ErrorAction SilentlyContinue
        Start-Process -FilePath $usoClient -ArgumentList 'StartScan' -WindowStyle Hidden -ErrorAction SilentlyContinue
    }

    Write-Log SUCCESS 'Security-focused Windows Update policies were applied.'
    Write-Log INFO "Quality/security update deferral: $QualityUpdateDeferralDays day(s)."
    Write-Log INFO "Feature update deferral: $FeatureUpdateDeferralDays day(s)."
    Write-Log INFO 'Optional previews are disabled and driver updates are excluded.'
    Write-Log WARNING 'Monthly Windows quality updates are cumulative; security fixes cannot be separated from the rest of the same cumulative package.'
    return
}
catch {
    Write-Log ERROR $_.Exception.Message
    throw
}
