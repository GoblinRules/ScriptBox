#Requires -Version 5.1
<#
.SYNOPSIS
    Mutes machine audio output and keeps it muted with a scheduled task.

.DESCRIPTION
    Blocks Remote Desktop audio/video playback redirection by local machine
    policy, then silences the computer by muting every active audio output
    endpoint and setting its volume to zero through the documented Windows
    CoreAudio endpoint-volume API - the same API the Windows 11 tray volume
    slider uses. No service is stopped and no device is disabled, so the
    taskbar, volume flyout, and Quick Settings stay responsive. A hidden
    ScriptBox\EnforceAudioMute scheduled task re-asserts the mute every few
    seconds and silences audio devices connected later, such as USB headsets.
    Audio devices disabled by older ScriptBox releases are re-enabled first so
    their endpoints return and can be muted. Run Fixes > Repair System Tray
    and Audio to reverse everything.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$terminalServicesPolicyPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services'
$audioServiceNames = @('AudioEndpointBuilder', 'Audiosrv')
$enforcementDirectory = 'C:\ProgramData\ScriptBox'
$enforcementScriptPath = 'C:\ProgramData\ScriptBox\Enforce-AudioMute.ps1'
$enforcementTaskName = 'EnforceAudioMute'

# Windows CoreAudio endpoint-volume interop. The interface GUIDs and the
# vtable member order below are load-bearing: they must match mmdeviceapi.h
# and endpointvolume.h exactly or COM calls dispatch to the wrong native
# method. Only DEVICE_STATE_ACTIVE endpoints are enumerated because
# activating IAudioEndpointVolume on unplugged endpoints fails (0x80070002).
$interopSource = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace SbxAudio
{
    public enum EDataFlow
    {
        eRender = 0,
        eCapture = 1,
        eAll = 2
    }

    public enum ERole
    {
        eConsole = 0,
        eMultimedia = 1,
        eCommunications = 2
    }

    [ComImport]
    [Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
    public class MMDeviceEnumeratorComObject
    {
    }

    [ComImport]
    [Guid("A95664D2-9614-4F35-A746-DE8DB63617E6")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IMMDeviceEnumerator
    {
        int EnumAudioEndpoints(EDataFlow dataFlow, uint stateMask, out IMMDeviceCollection devices);
        int GetDefaultAudioEndpoint(EDataFlow dataFlow, ERole role, out IMMDevice endpoint);
        int GetDevice([MarshalAs(UnmanagedType.LPWStr)] string id, out IMMDevice device);
    }

    [ComImport]
    [Guid("0BD7A1BE-7A1A-44DB-8397-CC5392387B5E")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IMMDeviceCollection
    {
        int GetCount(out uint count);
        int Item(uint index, out IMMDevice device);
    }

    [ComImport]
    [Guid("D666063F-1587-4E43-81F1-B948E807363F")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IMMDevice
    {
        int Activate(ref Guid iid, uint clsCtx, IntPtr activationParams, [MarshalAs(UnmanagedType.IUnknown)] out object activated);
        int OpenPropertyStore(uint accessMode, out IPropertyStore properties);
        int GetId([MarshalAs(UnmanagedType.LPWStr)] out string id);
        int GetState(out uint state);
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct PropertyKey
    {
        public Guid FormatId;
        public int PropertyId;

        public PropertyKey(Guid formatId, int propertyId)
        {
            FormatId = formatId;
            PropertyId = propertyId;
        }
    }

    [StructLayout(LayoutKind.Explicit)]
    public struct PropVariant
    {
        [FieldOffset(0)]
        public ushort vt;

        [FieldOffset(8)]
        public IntPtr pointerValue;
    }

    [ComImport]
    [Guid("886d8eeb-8cf2-4446-8d02-cdba1dbdcf99")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IPropertyStore
    {
        int GetCount(out uint propertyCount);
        int GetAt(uint propertyIndex, out PropertyKey key);
        int GetValue(ref PropertyKey key, out PropVariant value);
        int SetValue(ref PropertyKey key, ref PropVariant value);
        int Commit();
    }

    [ComImport]
    [Guid("5CDF2C82-841E-4546-9722-0CF74078229A")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IAudioEndpointVolume
    {
        int RegisterControlChangeNotify(IntPtr client);
        int UnregisterControlChangeNotify(IntPtr client);
        int GetChannelCount(out uint channelCount);
        int SetMasterVolumeLevel(float levelDecibels, IntPtr eventContext);
        int SetMasterVolumeLevelScalar(float level, IntPtr eventContext);
        int GetMasterVolumeLevel(out float levelDecibels);
        int GetMasterVolumeLevelScalar(out float level);
        int SetChannelVolumeLevel(uint channelNumber, float levelDecibels, IntPtr eventContext);
        int SetChannelVolumeLevelScalar(uint channelNumber, float level, IntPtr eventContext);
        int GetChannelVolumeLevel(uint channelNumber, out float levelDecibels);
        int GetChannelVolumeLevelScalar(uint channelNumber, out float level);
        int SetMute([MarshalAs(UnmanagedType.Bool)] bool mute, IntPtr eventContext);
        int GetMute(out bool mute);
    }

    public sealed class EndpointState
    {
        public string Id;
        public string FriendlyName;
        public bool Mute;
        public float Volume;
    }

    public static class Silencer
    {
        public const uint DEVICE_STATE_ACTIVE = 0x1;
        public const uint CLSCTX_ALL = 23;

        private static readonly Guid IID_IAudioEndpointVolume = new Guid("5CDF2C82-841E-4546-9722-0CF74078229A");
        private static readonly PropertyKey PKEY_Device_FriendlyName = new PropertyKey(new Guid("a45c254e-df1c-4efd-8020-67d146a850e0"), 14);

        private static void Check(int hr, string what)
        {
            if (hr != 0)
            {
                throw new COMException(what + " failed", hr);
            }
        }

        private static IAudioEndpointVolume GetVolume(IMMDevice device)
        {
            Guid iid = IID_IAudioEndpointVolume;
            object activated;
            Check(device.Activate(ref iid, CLSCTX_ALL, IntPtr.Zero, out activated), "IMMDevice.Activate(IAudioEndpointVolume)");
            return (IAudioEndpointVolume)activated;
        }

        private static string GetFriendlyName(IMMDevice device)
        {
            IPropertyStore properties;
            Check(device.OpenPropertyStore(0, out properties), "IMMDevice.OpenPropertyStore");
            PropertyKey key = PKEY_Device_FriendlyName;
            PropVariant value;
            Check(properties.GetValue(ref key, out value), "IPropertyStore.GetValue");
            if (value.vt == 31 && value.pointerValue != IntPtr.Zero)
            {
                return Marshal.PtrToStringUni(value.pointerValue);
            }
            return "(unknown audio endpoint)";
        }

        public static List<EndpointState> GetRenderStates()
        {
            List<EndpointState> states = new List<EndpointState>();
            IMMDeviceEnumerator enumerator = (IMMDeviceEnumerator)new MMDeviceEnumeratorComObject();
            IMMDeviceCollection collection;
            Check(enumerator.EnumAudioEndpoints(EDataFlow.eRender, DEVICE_STATE_ACTIVE, out collection), "IMMDeviceEnumerator.EnumAudioEndpoints");
            uint count;
            Check(collection.GetCount(out count), "IMMDeviceCollection.GetCount");
            for (uint index = 0; index < count; index++)
            {
                IMMDevice device;
                Check(collection.Item(index, out device), "IMMDeviceCollection.Item");
                string id;
                Check(device.GetId(out id), "IMMDevice.GetId");
                IAudioEndpointVolume volume = GetVolume(device);
                bool mute;
                Check(volume.GetMute(out mute), "IAudioEndpointVolume.GetMute");
                float level;
                Check(volume.GetMasterVolumeLevelScalar(out level), "IAudioEndpointVolume.GetMasterVolumeLevelScalar");
                EndpointState state = new EndpointState();
                state.Id = id;
                state.FriendlyName = GetFriendlyName(device);
                state.Mute = mute;
                state.Volume = level;
                states.Add(state);
            }
            return states;
        }

        public static int EnforceSilence()
        {
            int fixedCount = 0;
            IMMDeviceEnumerator enumerator = (IMMDeviceEnumerator)new MMDeviceEnumeratorComObject();
            foreach (EndpointState state in GetRenderStates())
            {
                if (state.Mute && state.Volume < 0.001f)
                {
                    continue;
                }
                try
                {
                    IMMDevice device;
                    Check(enumerator.GetDevice(state.Id, out device), "IMMDeviceEnumerator.GetDevice");
                    IAudioEndpointVolume volume = GetVolume(device);
                    Check(volume.SetMute(true, IntPtr.Zero), "IAudioEndpointVolume.SetMute");
                    Check(volume.SetMasterVolumeLevelScalar(0f, IntPtr.Zero), "IAudioEndpointVolume.SetMasterVolumeLevelScalar");
                    fixedCount++;
                }
                catch (COMException)
                {
                }
            }
            return fixedCount;
        }

        public static void SetEndpoint(string id, bool mute, float volumeScalar)
        {
            IMMDeviceEnumerator enumerator = (IMMDeviceEnumerator)new MMDeviceEnumeratorComObject();
            IMMDevice device;
            Check(enumerator.GetDevice(id, out device), "IMMDeviceEnumerator.GetDevice");
            IAudioEndpointVolume volume = GetVolume(device);
            Check(volume.SetMute(mute, IntPtr.Zero), "IAudioEndpointVolume.SetMute");
            Check(volume.SetMasterVolumeLevelScalar(volumeScalar, IntPtr.Zero), "IAudioEndpointVolume.SetMasterVolumeLevelScalar");
        }
    }
}
'@

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

    # Earlier ScriptBox releases disabled the Windows Audio service or every
    # MEDIA-class device; both approaches hang the Windows 11 taskbar and
    # Quick Settings. Both services stay Automatic and running; silence now
    # comes from muting the audio output endpoints instead.
    foreach ($serviceName in $audioServiceNames) {
        Set-Service -Name $serviceName -StartupType Automatic -ErrorAction Stop
    }
    foreach ($serviceName in $audioServiceNames) {
        Start-Service -Name $serviceName -ErrorAction Stop
    }
    Write-Host '[INFO] Windows Audio and Audio Endpoint Builder remain Automatic and running for the Windows 11 system tray.'

    # Heal machines that ran the previous device-disable version: re-enable
    # any disabled audio devices so their endpoints come back and can be
    # muted, then give Audio Endpoint Builder a moment to rebuild them.
    $disabledAudioDevices = @(Get-PnpDevice -Class MEDIA -PresentOnly -ErrorAction SilentlyContinue |
        Where-Object Status -eq 'Error')
    foreach ($device in $disabledAudioDevices) {
        try {
            Enable-PnpDevice -InstanceId $device.InstanceId -Confirm:$false -ErrorAction Stop
            Write-Host "[INFO] Previously disabled audio device re-enabled: $($device.FriendlyName)"
        }
        catch {
            Write-Host "[WARNING] Could not re-enable audio device '$($device.FriendlyName)': $($_.Exception.Message)"
        }
    }
    if ($disabledAudioDevices.Count -gt 0) {
        Start-Sleep -Seconds 5
    }

    if (-not ('SbxAudio.Silencer' -as [type])) {
        Add-Type -TypeDefinition $interopSource -Language CSharp
    }

    $endpointsBefore = [SbxAudio.Silencer]::GetRenderStates()
    if ($endpointsBefore.Count -eq 0) {
        Write-Host '[INFO] No active audio output endpoints are present; there is nothing to mute yet.'
    }
    foreach ($endpoint in $endpointsBefore) {
        Write-Host "[INFO] Muting audio output endpoint: $($endpoint.FriendlyName)"
    }
    [void][SbxAudio.Silencer]::EnforceSilence()

    # Write the standalone enforcement script. It embeds the same interop
    # source so it has no dependency on ScriptBox or this script.
    New-Item -Path $enforcementDirectory -ItemType Directory -Force | Out-Null
    $enforcementHeader = @(
        '# Enforce-AudioMute.ps1 - written by ScriptBox "Disable Machine Audio".',
        '# Re-asserts mute and zero volume on every active audio output endpoint so',
        '# volume-key presses and newly connected audio devices stay silent. Removed',
        '# by ScriptBox Fixes > Repair System Tray and Audio.',
        "`$ErrorActionPreference = 'Stop'"
    ) -join "`r`n"
    $enforcementBody = @'
Add-Type -TypeDefinition $interopSource -Language CSharp
while ($true) {
    try { [void][SbxAudio.Silencer]::EnforceSilence() } catch { }
    Start-Sleep -Seconds 15
}
'@
    $enforcementContent = $enforcementHeader + "`r`n" +
        "`$interopSource = @'" + "`r`n" +
        $interopSource + "`r`n" +
        "'@" + "`r`n" +
        $enforcementBody + "`r`n"
    [IO.File]::WriteAllText(
        $enforcementScriptPath,
        $enforcementContent,
        (New-Object Text.UTF8Encoding($false))
    )
    Write-Host "[INFO] Mute enforcement script written: $enforcementScriptPath"

    # The task is registered from XML because New-ScheduledTaskTrigger cannot
    # express event or session-unlock triggers. It runs as the built-in Users
    # group in the interactive session (CoreAudio is unreliable in session 0),
    # at logon, at unlock, when Kernel-PnP configures a device (new USB or
    # HDMI audio), and every 30 minutes as a safety net.
    $taskXml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Author>ScriptBox</Author>
    <Description>Keeps machine audio output muted. Registered by ScriptBox Disable Machine Audio; removed by ScriptBox Repair System Tray and Audio.</Description>
    <URI>\ScriptBox\EnforceAudioMute</URI>
  </RegistrationInfo>
  <Triggers>
    <LogonTrigger>
      <Enabled>true</Enabled>
    </LogonTrigger>
    <SessionStateChangeTrigger>
      <Enabled>true</Enabled>
      <StateChange>SessionUnlock</StateChange>
    </SessionStateChangeTrigger>
    <EventTrigger>
      <Enabled>true</Enabled>
      <Subscription>&lt;QueryList&gt;&lt;Query Id="0" Path="Microsoft-Windows-Kernel-PnP/Configuration"&gt;&lt;Select Path="Microsoft-Windows-Kernel-PnP/Configuration"&gt;*[System[(EventID=400 or EventID=410 or EventID=430)]]&lt;/Select&gt;&lt;/Query&gt;&lt;/QueryList&gt;</Subscription>
    </EventTrigger>
    <TimeTrigger>
      <Repetition>
        <Interval>PT30M</Interval>
        <StopAtDurationEnd>false</StopAtDurationEnd>
      </Repetition>
      <StartBoundary>2020-01-01T00:00:00</StartBoundary>
      <Enabled>true</Enabled>
    </TimeTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <GroupId>S-1-5-32-545</GroupId>
      <RunLevel>LeastPrivilege</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>true</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <IdleSettings>
      <StopOnIdleEnd>false</StopOnIdleEnd>
      <RestartOnIdle>false</RestartOnIdle>
    </IdleSettings>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>true</Hidden>
    <RunOnlyIfIdle>false</RunOnlyIfIdle>
    <WakeToRun>false</WakeToRun>
    <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>
    <Priority>7</Priority>
    <RestartOnFailure>
      <Interval>PT1M</Interval>
      <Count>3</Count>
    </RestartOnFailure>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe</Command>
      <Arguments>-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "$enforcementScriptPath"</Arguments>
    </Exec>
  </Actions>
</Task>
"@
    Register-ScheduledTask -TaskName $enforcementTaskName -TaskPath '\ScriptBox' `
        -Xml $taskXml -Force | Out-Null
    Write-Host "[INFO] Scheduled task registered: \ScriptBox\$enforcementTaskName"

    try {
        Start-ScheduledTask -TaskPath '\ScriptBox\' -TaskName $enforcementTaskName -ErrorAction Stop
        Write-Host '[INFO] Mute enforcement is running now; it also starts at logon, at unlock, when audio devices are connected, and every 30 minutes.'
    }
    catch {
        Write-Host "[WARNING] Could not start the enforcement task immediately (it will run at the next sign-in): $($_.Exception.Message)"
    }

    Start-Sleep -Seconds 2
    $registeredTask = Get-ScheduledTask -TaskPath '\ScriptBox\' -TaskName $enforcementTaskName `
        -ErrorAction SilentlyContinue
    $finalEndpoints = [SbxAudio.Silencer]::GetRenderStates()
    $unmutedEndpoints = @($finalEndpoints | Where-Object { -not $_.Mute -or $_.Volume -ge 0.001 })
    $unsafeAudioServices = @($audioServiceNames | Where-Object {
        $service = Get-CimInstance -ClassName Win32_Service -Filter "Name='$_'"
        -not $service -or $service.StartMode -ne 'Auto' -or $service.State -ne 'Running'
    })
    $rdpPlaybackBlocked = (Get-ItemPropertyValue -LiteralPath $terminalServicesPolicyPath -Name 'fDisableCam') -eq 1

    # Zero active endpoints counts as success: a machine without audio
    # hardware is already silent and the task will mute anything that appears.
    if ($unmutedEndpoints.Count -gt 0 -or $null -eq $registeredTask -or
        -not (Test-Path -LiteralPath $enforcementScriptPath) -or
        $unsafeAudioServices.Count -gt 0 -or -not $rdpPlaybackBlocked) {
        throw 'The final audio-mute check failed. Every active audio output endpoint must be muted at zero volume, the EnforceAudioMute task and enforcement script must exist, both audio services must stay Automatic/Running, and the RDP playback policy must be enabled.'
    }

    if ($finalEndpoints.Count -eq 0) {
        Write-Host '[SUCCESS] No active audio output endpoints exist on this machine; the enforcement task will mute any that appear.'
    }
    else {
        Write-Host "[SUCCESS] All $($finalEndpoints.Count) active audio output endpoints are muted at zero volume."
    }
    Write-Host '[SUCCESS] Audio is muted through the same CoreAudio API as the tray volume slider; no service or device was disabled, so the Windows 11 system tray stays responsive.'
    Write-Host '[SUCCESS] The ScriptBox\EnforceAudioMute task keeps audio muted and silences newly connected audio devices.'
    Write-Host '[WARNING] Microphone and other audio input remain available; only audio output is muted.'
    Write-Host '[WARNING] Programs using exclusive-mode WASAPI or ASIO output can bypass the Windows master volume; standard Windows playback is silenced.'
    Write-Host '[WARNING] Use Fixes -> Repair System Tray and Audio to restore sound.'
}
catch {
    Write-Host "[ERROR] Failed to disable machine audio: $($_.Exception.Message)"
    throw
}
