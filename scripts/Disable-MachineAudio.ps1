#Requires -Version 5.1
<#
.SYNOPSIS
    Disables physical and Remote Desktop audio for the machine.

.DESCRIPTION
    Disables and stops Windows Audio and Windows Audio Endpoint Builder, then
    blocks Remote Desktop audio/video playback redirection by local machine
    policy. Playback and microphone/input audio will be unavailable. The
    change persists across users and restarts until an administrator manually
    reverses it.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$terminalServicesPolicyPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services'
$audioServiceNames = @('Audiosrv', 'AudioEndpointBuilder')

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

    foreach ($serviceName in $audioServiceNames) {
        Set-Service -Name $serviceName -StartupType Disabled
    }

    # Stop Windows Audio before its endpoint dependency. -Force also stops any
    # audio-service dependants without changing unrelated service start modes.
    Stop-Service -Name 'Audiosrv' -Force -ErrorAction SilentlyContinue
    Stop-Service -Name 'AudioEndpointBuilder' -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 750

    $failedServices = @($audioServiceNames | Where-Object {
        $service = Get-CimInstance -ClassName Win32_Service -Filter "Name='$_'"
        -not $service -or $service.StartMode -ne 'Disabled' -or $service.State -ne 'Stopped'
    })
    $rdpPlaybackBlocked = (Get-ItemPropertyValue -LiteralPath $terminalServicesPolicyPath -Name 'fDisableCam') -eq 1

    if ($failedServices.Count -gt 0 -or -not $rdpPlaybackBlocked) {
        $details = if ($failedServices.Count -gt 0) { $failedServices -join ', ' } else { 'RDP playback policy' }
        throw "The final audio-disable check failed for: $details"
    }

    Write-Host '[SUCCESS] Physical and Remote Desktop machine audio are disabled.'
    Write-Host '[SUCCESS] The audio services are disabled and will remain off after restart.'
    Write-Host '[WARNING] Microphone and other audio input are also unavailable while the Windows audio services are disabled.'
    Write-Host '[WARNING] To restore sound, an administrator must remove the fDisableCam policy, set Windows Audio Endpoint Builder and Windows Audio to Automatic, then start both services.'
}
catch {
    Write-Host "[ERROR] Failed to disable machine audio: $($_.Exception.Message)"
    throw
}
