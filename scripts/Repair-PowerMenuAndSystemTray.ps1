#Requires -Version 5.1
<#
.SYNOPSIS
    Repairs Windows shell policy and restores machine audio services.

.DESCRIPTION
    Restores the four Windows PolicyManager Start defaults changed by older
    ScriptBox releases and removes ScriptBox's NoClose policy from existing
    non-special user profiles and the Default user profile.

    ScriptBox never set the NoTrayItemsDisplay policy that directly hides the
    notification area, so this repair leaves unrelated organization-managed
    notification-area policy unchanged.

    Also reverses Disable Machine Audio: removes its local fDisableCam
    policy, stops and unregisters the ScriptBox\EnforceAudioMute scheduled
    task and deletes its enforcement script, returns Windows Audio Endpoint
    Builder and Windows Audio to Automatic, starts both services in
    dependency order, re-enables any disabled MEDIA-class (audio) devices
    from older releases, and unmutes every active audio output endpoint to
    50 percent volume through the documented CoreAudio endpoint-volume API.
    A sign-out or restart reloads the affected Windows 11 shell surfaces.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$terminalServicesPolicyPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services'
$audioServiceNames = @('AudioEndpointBuilder', 'Audiosrv')
$enforcementDirectory = 'C:\ProgramData\ScriptBox'
$enforcementScriptPath = 'C:\ProgramData\ScriptBox\Enforce-AudioMute.ps1'

# Windows CoreAudio endpoint-volume interop, identical to the source used by
# Disable Machine Audio. The interface GUIDs and vtable member order are
# load-bearing: they must match mmdeviceapi.h and endpointvolume.h exactly.
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

    if (Test-Path -LiteralPath $terminalServicesPolicyPath) {
        $terminalServicesPolicy = Get-ItemProperty `
            -LiteralPath $terminalServicesPolicyPath `
            -ErrorAction Stop
        if ($terminalServicesPolicy.PSObject.Properties.Name -contains 'fDisableCam') {
            Remove-ItemProperty `
                -LiteralPath $terminalServicesPolicyPath `
                -Name 'fDisableCam' `
                -ErrorAction Stop
            Write-Log INFO 'Local Remote Desktop playback block removed: fDisableCam'
        }
        else {
            Write-Log INFO 'Local Remote Desktop playback policy was already clear.'
        }
    }

    # Stop and remove the mute enforcement task before unmuting, or its loop
    # would re-mute the endpoints within seconds.
    $enforcementTask = Get-ScheduledTask -TaskPath '\ScriptBox\' -TaskName 'EnforceAudioMute' `
        -ErrorAction SilentlyContinue
    if ($enforcementTask) {
        try {
            Stop-ScheduledTask -TaskPath '\ScriptBox\' -TaskName 'EnforceAudioMute' -ErrorAction Stop
        }
        catch {
            Write-Log INFO 'The audio mute enforcement task had no running instance to stop.'
        }
        Unregister-ScheduledTask -TaskPath '\ScriptBox\' -TaskName 'EnforceAudioMute' `
            -Confirm:$false -ErrorAction Stop
        Write-Log INFO 'Audio mute enforcement task removed: \ScriptBox\EnforceAudioMute'
    }
    else {
        Write-Log INFO 'No audio mute enforcement task was present.'
    }

    try {
        $scheduleService = New-Object -ComObject 'Schedule.Service'
        $scheduleService.Connect()
        $rootTaskFolder = $scheduleService.GetFolder('\')
        $scriptBoxTaskFolder = $null
        try {
            $scriptBoxTaskFolder = $rootTaskFolder.GetFolder('ScriptBox')
        }
        catch {
            $scriptBoxTaskFolder = $null
        }
        if ($null -ne $scriptBoxTaskFolder -and
            $scriptBoxTaskFolder.GetTasks(1).Count -eq 0 -and
            $scriptBoxTaskFolder.GetFolders(1).Count -eq 0) {
            $rootTaskFolder.DeleteFolder('ScriptBox', 0)
            Write-Log INFO 'Empty ScriptBox scheduled-task folder removed.'
        }
    }
    catch {
        Write-Log WARNING "Could not remove the ScriptBox scheduled-task folder: $($_.Exception.Message)"
    }

    if (Test-Path -LiteralPath $enforcementScriptPath) {
        Remove-Item -LiteralPath $enforcementScriptPath -Force
        Write-Log INFO "Audio mute enforcement script removed: $enforcementScriptPath"
    }
    else {
        Write-Log INFO 'No audio mute enforcement script was present.'
    }
    if ((Test-Path -LiteralPath $enforcementDirectory) -and
        @(Get-ChildItem -LiteralPath $enforcementDirectory -Force).Count -eq 0) {
        Remove-Item -LiteralPath $enforcementDirectory -Force
        Write-Log INFO "Empty ScriptBox data folder removed: $enforcementDirectory"
    }

    foreach ($serviceName in $audioServiceNames) {
        Set-Service -Name $serviceName -StartupType Automatic -ErrorAction Stop
    }
    foreach ($serviceName in $audioServiceNames) {
        Start-Service -Name $serviceName -ErrorAction Stop
        $service = Get-Service -Name $serviceName -ErrorAction Stop
        $service.WaitForStatus(
            [ServiceProcess.ServiceControllerStatus]::Running,
            [TimeSpan]::FromSeconds(15)
        )
    }

    $disabledAudioDevices = @(Get-PnpDevice -Class MEDIA -PresentOnly -ErrorAction SilentlyContinue |
        Where-Object { $_.Problem -eq 'CM_PROB_DISABLED' })
    if ($disabledAudioDevices.Count -eq 0) {
        Write-Log INFO 'No disabled audio devices were found.'
    }
    foreach ($device in $disabledAudioDevices) {
        try {
            Enable-PnpDevice -InstanceId $device.InstanceId -Confirm:$false -ErrorAction Stop
            Write-Log INFO "Audio device re-enabled: $($device.FriendlyName)"
        }
        catch {
            Write-Log WARNING "Could not re-enable audio device '$($device.FriendlyName)': $($_.Exception.Message)"
        }
    }
    if ($disabledAudioDevices.Count -gt 0) {
        # Give Windows Audio Endpoint Builder a moment to rebuild the
        # endpoints of the re-enabled devices before unmuting them.
        Start-Sleep -Seconds 5
    }

    # Unmute every active audio output endpoint and restore a sensible
    # 50 percent volume through the same CoreAudio endpoint-volume API the
    # tray volume slider uses.
    if (-not ('SbxAudio.Silencer' -as [type])) {
        Add-Type -TypeDefinition $interopSource -Language CSharp
    }
    $renderEndpoints = @([SbxAudio.Silencer]::GetRenderStates())
    if ($renderEndpoints.Count -eq 0) {
        Write-Log INFO 'No active audio output endpoints were found to unmute.'
    }
    foreach ($endpoint in $renderEndpoints) {
        try {
            [SbxAudio.Silencer]::SetEndpoint($endpoint.Id, $false, 0.5)
            Write-Log INFO "Audio output endpoint unmuted to 50 percent volume: $($endpoint.FriendlyName)"
        }
        catch {
            Write-Log WARNING "Could not unmute audio endpoint '$($endpoint.FriendlyName)': $($_.Exception.Message)"
        }
    }

    $failedAudioServices = @($audioServiceNames | Where-Object {
        $service = Get-CimInstance -ClassName Win32_Service -Filter "Name='$_'"
        -not $service -or $service.StartMode -ne 'Auto' -or $service.State -ne 'Running'
    })
    $audioPolicyStillPresent = $false
    if (Test-Path -LiteralPath $terminalServicesPolicyPath) {
        $policyAfter = Get-ItemProperty `
            -LiteralPath $terminalServicesPolicyPath `
            -ErrorAction Stop
        $audioPolicyStillPresent = $policyAfter.PSObject.Properties.Name -contains 'fDisableCam'
    }
    $enforcementTaskStillPresent = $null -ne (Get-ScheduledTask -TaskPath '\ScriptBox\' `
        -TaskName 'EnforceAudioMute' -ErrorAction SilentlyContinue)
    if ($failedAudioServices.Count -gt 0 -or $audioPolicyStillPresent -or
        $enforcementTaskStillPresent -or (Test-Path -LiteralPath $enforcementScriptPath)) {
        throw 'The audio restoration check failed. Both audio services must be Automatic/Running, fDisableCam must be absent, and the EnforceAudioMute task and enforcement script must be removed.'
    }

    Write-Log SUCCESS 'Legacy ScriptBox power/shell policy changes were removed, the audio mute enforcement task and script were deleted, audio output was unmuted to 50 percent volume, and machine audio services were restored.'
    Write-Log WARNING 'Sign out or restart Windows to reload the Start menu, power menu, notification area, and Quick Settings.'
    return
}
catch {
    Write-Log ERROR $_.Exception.Message
    throw
}
