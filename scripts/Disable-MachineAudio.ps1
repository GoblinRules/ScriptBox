#Requires -Version 5.1
<#
.SYNOPSIS
    Disables physical and Remote Desktop audio for the machine.

.DESCRIPTION
    Blocks Remote Desktop audio/video playback redirection by local machine
    policy and disables every present, enabled MEDIA-class (audio) device.
    Windows Audio and Windows Audio Endpoint Builder are both left Automatic
    and running, because the Windows 11 taskbar, volume flyout, and Quick
    Settings hang when the Windows Audio service is stopped. With every audio
    device disabled there is still no playback or microphone capture. Run
    Fixes > Repair System Tray and Audio to reverse it.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$terminalServicesPolicyPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services'
$audioServiceNames = @('AudioEndpointBuilder', 'Audiosrv')

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

    # Earlier ScriptBox releases disabled the Windows Audio service, which
    # hangs the Windows 11 taskbar and Quick Settings even when Endpoint
    # Builder keeps running. Both services stay Automatic and running;
    # silence comes from disabling the audio devices instead.
    foreach ($serviceName in $audioServiceNames) {
        Set-Service -Name $serviceName -StartupType Automatic -ErrorAction Stop
    }
    foreach ($serviceName in $audioServiceNames) {
        Start-Service -Name $serviceName -ErrorAction Stop
    }
    Write-Host '[INFO] Windows Audio and Audio Endpoint Builder remain Automatic and running for the Windows 11 system tray.'

    $audioDevices = @(Get-PnpDevice -Class MEDIA -PresentOnly -ErrorAction SilentlyContinue |
        Where-Object Status -eq 'OK')
    if ($audioDevices.Count -eq 0) {
        Write-Host '[INFO] No enabled audio devices were found; there is no device to disable.'
    }

    $failedDeviceNames = New-Object System.Collections.Generic.List[string]
    foreach ($device in $audioDevices) {
        try {
            Disable-PnpDevice -InstanceId $device.InstanceId -Confirm:$false -ErrorAction Stop
            Write-Host "[INFO] Audio device disabled: $($device.FriendlyName)"
        }
        catch {
            $failedDeviceNames.Add([string]$device.FriendlyName)
            Write-Host "[ERROR] Could not disable audio device '$($device.FriendlyName)': $($_.Exception.Message)"
        }
    }
    Start-Sleep -Milliseconds 750

    $stillEnabledDevices = @(Get-PnpDevice -Class MEDIA -PresentOnly -ErrorAction SilentlyContinue |
        Where-Object Status -eq 'OK')
    $unsafeAudioServices = @($audioServiceNames | Where-Object {
        $service = Get-CimInstance -ClassName Win32_Service -Filter "Name='$_'"
        -not $service -or $service.StartMode -ne 'Auto' -or $service.State -ne 'Running'
    })
    $rdpPlaybackBlocked = (Get-ItemPropertyValue -LiteralPath $terminalServicesPolicyPath -Name 'fDisableCam') -eq 1

    if ($failedDeviceNames.Count -gt 0 -or $stillEnabledDevices.Count -gt 0 -or
        $unsafeAudioServices.Count -gt 0 -or -not $rdpPlaybackBlocked) {
        throw 'The final audio-disable check failed. Every audio device must be disabled, both audio services must stay Automatic/Running, and the RDP playback policy must be enabled.'
    }

    Write-Host '[SUCCESS] Physical and Remote Desktop machine audio are disabled.'
    Write-Host '[SUCCESS] All audio devices are disabled while the audio services keep the Windows 11 system tray responsive.'
    Write-Host '[WARNING] Microphone and other audio input are also unavailable while the audio devices are disabled.'
    Write-Host '[WARNING] Audio devices connected later (for example a USB headset) will still work until this action is run again.'
    Write-Host '[WARNING] Use Fixes -> Repair System Tray and Audio to restore sound.'
}
catch {
    Write-Host "[ERROR] Failed to disable machine audio: $($_.Exception.Message)"
    throw
}
