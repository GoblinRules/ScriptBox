#Requires -Version 5.1
<#
.SYNOPSIS
    Disables physical and Remote Desktop audio for the machine.

.DESCRIPTION
    Disables and stops Windows Audio, then blocks Remote Desktop audio/video
    playback redirection by local machine policy. Windows Audio Endpoint
    Builder remains Automatic and running so the Windows 11 system tray and
    Quick Settings shell can continue to enumerate audio endpoints. Playback
    and microphone/input audio remain unavailable until the repair action is
    run.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$terminalServicesPolicyPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services'
$disabledAudioServiceName = 'Audiosrv'
$endpointServiceName = 'AudioEndpointBuilder'

function Assert-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'This script must be run with administrator rights.'
    }
}

try {
    Assert-Administrator

    New-Item -Path $terminalServicesPolicyPath -Force | Out-Null
    New-ItemProperty -Path $terminalServicesPolicyPath -Name 'fDisableCam' `
        -PropertyType DWord -Value 1 -Force | Out-Null
    Write-Host '[INFO] Remote Desktop audio/video playback redirection is blocked by machine policy.'

    # Keep Endpoint Builder available because Windows 11's volume and Quick
    # Settings shell surfaces rely on endpoint enumeration even when sound is
    # intentionally disabled.
    Set-Service -Name $endpointServiceName -StartupType Automatic -ErrorAction Stop
    Start-Service -Name $endpointServiceName -ErrorAction Stop

    Set-Service -Name $disabledAudioServiceName -StartupType Disabled -ErrorAction Stop
    Stop-Service -Name $disabledAudioServiceName -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 750

    $windowsAudio = Get-CimInstance `
        -ClassName Win32_Service `
        -Filter "Name='$disabledAudioServiceName'"
    $endpointBuilder = Get-CimInstance `
        -ClassName Win32_Service `
        -Filter "Name='$endpointServiceName'"
    $rdpPlaybackBlocked = (Get-ItemPropertyValue -LiteralPath $terminalServicesPolicyPath -Name 'fDisableCam') -eq 1

    $windowsAudioDisabled = (
        $windowsAudio -and
        $windowsAudio.StartMode -eq 'Disabled' -and
        $windowsAudio.State -eq 'Stopped'
    )
    $endpointBuilderSafe = (
        $endpointBuilder -and
        $endpointBuilder.StartMode -eq 'Auto' -and
        $endpointBuilder.State -eq 'Running'
    )
    if (-not $windowsAudioDisabled -or -not $endpointBuilderSafe -or -not $rdpPlaybackBlocked) {
        throw 'The final audio-disable check failed. Windows Audio must be Disabled/Stopped, Endpoint Builder must be Automatic/Running, and the RDP playback policy must be enabled.'
    }

    Write-Host '[SUCCESS] Physical and Remote Desktop machine audio are disabled.'
    Write-Host '[SUCCESS] Windows Audio is disabled; Audio Endpoint Builder remains Automatic and running for the Windows 11 system tray.'
    Write-Host '[WARNING] Microphone and other audio input are also unavailable while Windows Audio is disabled.'
    Write-Host '[WARNING] Use Fixes -> Repair System Tray and Audio to restore sound.'
}
catch {
    Write-Host "[ERROR] Failed to disable machine audio: $($_.Exception.Message)"
    throw
}
