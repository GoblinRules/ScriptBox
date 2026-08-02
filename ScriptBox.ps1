#requires -Version 5.1
<#+
.SYNOPSIS
    ScriptBox - a portable, category-based Windows script launcher.
.DESCRIPTION
    Runs entirely from memory, creates only a short-lived temporary workspace,
    and removes that workspace when the window closes.
#>

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:AppName = 'ScriptBox'
$script:Version = '3.3.7'
$script:Repository = 'https://github.com/GoblinRules/ScriptBox'
$script:SelfSource = 'https://raw.githubusercontent.com/GoblinRules/ScriptBox/main/ScriptBox.ps1'
$script:IconSource = 'https://raw.githubusercontent.com/GoblinRules/ScriptBox/main/assets/icon.png'
$script:RawScriptRoot = "https://raw.githubusercontent.com/GoblinRules/ScriptBox/v$($script:Version)/scripts"
$script:TempRoot = $null
$script:ActiveSection = 'Scripts'
$script:ActiveCategory = 'All scripts'
$script:IsDarkTheme = $true
$script:SystemInfoLoaded = $false
$script:SystemInfoSnapshot = $null
$script:SystemInfoGather = $null
$script:ApplicationStatusCache = @{}
$script:ApplicationStatusPills = @{}
$script:ApplicationStatusGather = $null
$script:IconGather = $null
$script:TerminalMode = 'Normal'
$script:SectionButtons = @{}
$script:RunState = $null
$script:RunButtons = New-Object System.Collections.Generic.List[object]
$script:SelectionControls = New-Object System.Collections.Generic.List[object]
$script:SelectedIds = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
$script:ApplicationSelectionControls = New-Object System.Collections.Generic.List[object]
$script:SelectedApplicationIds = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
$script:RunQueue = New-Object 'System.Collections.Generic.Queue[object]'
$script:QueueResults = New-Object System.Collections.Generic.List[object]
$script:IsQueueRunning = $false
$script:QueueTitle = 'Selected scripts'
$script:QueueNoun = 'scripts'

# WPF needs an STA thread, and running inline via irm | iex ties the app's
# life to the user's console process (a UI failure would close their
# terminal). Hand off to a dedicated hidden Windows PowerShell host whenever
# the thread is MTA (PowerShell 7 default) or the launcher was piped through
# Invoke-Expression, without writing the launcher itself to disk.
$script:IsPipedLaunch = -not $PSScriptRoot
if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA' -or
    ($script:IsPipedLaunch -and $env:SCRIPTBOX_HANDOFF -ne '1')) {
    try {
        $handoff = "& { `$env:SCRIPTBOX_HANDOFF = '1'; Invoke-RestMethod -UseBasicParsing '$($script:SelfSource)' | Invoke-Expression }"
        $encodedHandoff = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($handoff))
        Start-Process -FilePath 'powershell.exe' -ArgumentList @(
            '-NoLogo', '-NoProfile', '-STA', '-EncodedCommand', $encodedHandoff
        ) -WindowStyle Hidden -ErrorAction Stop
        Write-Host 'ScriptBox is opening in its own window; this console is free to use or close.'
        return
    }
    catch {
        if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') { throw }
        # The detached host could not start but this console is STA, so fall
        # through and run inline as older versions did.
    }
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml
Add-Type -AssemblyName System.Drawing

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function New-ScriptBoxTempRoot {
    $base = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    $path = Join-Path $base ("ScriptBox-{0}" -f [Guid]::NewGuid().ToString('N'))
    if (-not $path.StartsWith($base, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Refusing to create a temporary workspace outside the Windows temp directory.'
    }
    [IO.Directory]::CreateDirectory($path) | Out-Null
    return $path
}

function Remove-ScriptBoxTempRoot {
    if ([string]::IsNullOrWhiteSpace($script:TempRoot)) { return }

    $base = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    $target = [IO.Path]::GetFullPath($script:TempRoot)
    if ($target.StartsWith($base, [StringComparison]::OrdinalIgnoreCase) -and
        (Split-Path -Leaf $target) -like 'ScriptBox-*' -and
        (Test-Path -LiteralPath $target)) {
        Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction SilentlyContinue
    }
    $script:TempRoot = $null
}

function ConvertTo-EncodedPowerShellCommand {
    param([Parameter(Mandatory)][string]$Text)
    return [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Text))
}

function Read-SharedTextFile {
    param([Parameter(Mandatory)][string]$Path)

    $stream = [IO.File]::Open(
        $Path,
        [IO.FileMode]::Open,
        [IO.FileAccess]::Read,
        [IO.FileShare]::ReadWrite
    )
    try {
        $reader = New-Object IO.StreamReader($stream)
        try {
            return $reader.ReadToEnd()
        }
        finally {
            $reader.Dispose()
        }
    }
    finally {
        $stream.Dispose()
    }
}

function New-CatalogItem {
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Category,
        [Parameter(Mandatory)][string]$Description,
        [string]$ScriptPath = '',
        [string]$SourceUri = '',
        [scriptblock]$InlineScript,
        [string]$ScriptArguments = '',
        [string]$Impact = 'Makes a temporary or user-requested change.',
        [bool]$RequiresAdmin = $false,
        [bool]$NeedsBypass = $false,
        [bool]$RequiresConfirmation = $true,
        [string]$InputTitle = '',
        [string]$InputMessage = '',
        [string]$InputVariable = '',
        [bool]$InputOptional = $false,
        [bool]$InputSecret = $false,
        [string]$RequiredInputValue = '',
        [ValidateSet('Summary', 'Terminal', 'None')][string]$ResultMode = 'Summary',
        [string]$SuccessMessage = 'The requested task completed successfully.',
        [string]$ConflictGroup = '',
        [bool]$CanQueue = $true,
        [bool]$ShowInAllScripts = $true,
        [int]$RunOrder = 100,
        [string]$Accent = '#818CF8'
    )

    if ($InputVariable -and $InputVariable -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') {
        throw "Catalog input variable '$InputVariable' is not a valid PowerShell variable name."
    }
    if ($RequiredInputValue -and (-not $InputVariable -or $InputOptional -or $InputSecret)) {
        throw "Catalog item '$Id' can require an exact input only for a required, non-secret input variable."
    }
    $sourceCount = 0
    if (-not [string]::IsNullOrWhiteSpace($ScriptPath)) { $sourceCount++ }
    if (-not [string]::IsNullOrWhiteSpace($SourceUri)) { $sourceCount++ }
    if ($InlineScript) { $sourceCount++ }
    if ($sourceCount -ne 1) {
        throw "Catalog item '$Id' must define exactly one of ScriptPath, SourceUri, or InlineScript."
    }
    if ($ScriptPath) {
        $SourceUri = '{0}/{1}' -f $script:RawScriptRoot.TrimEnd('/'), $ScriptPath.TrimStart('/')
    }

    [pscustomobject]@{
        Id                   = $Id
        Name                 = $Name
        Category             = $Category
        Description          = $Description
        ScriptPath           = $ScriptPath
        SourceUri            = $SourceUri
        InlineScript         = $InlineScript
        ScriptArguments      = $ScriptArguments
        Impact               = $Impact
        RequiresAdmin        = $RequiresAdmin
        NeedsBypass          = $NeedsBypass
        RequiresConfirmation = $RequiresConfirmation
        RunsRemoteCode       = [string]::IsNullOrWhiteSpace($SourceUri) -eq $false
        InputTitle           = $InputTitle
        InputMessage         = $InputMessage
        InputVariable        = $InputVariable
        InputOptional        = $InputOptional
        InputSecret          = $InputSecret
        RequiredInputValue   = $RequiredInputValue
        ResultMode           = $ResultMode
        SuccessMessage       = $SuccessMessage
        ConflictGroup        = $ConflictGroup
        CanQueue             = $CanQueue
        ShowInAllScripts     = $ShowInAllScripts
        RunOrder             = $RunOrder
        Accent               = $Accent
    }
}

# ============================================================================
# SCRIPT CATALOG
# Add, remove, or edit entries in this array. The UI and category navigation
# are generated automatically from these definitions.
# ============================================================================
$script:Catalog = @(
    New-CatalogItem -Id 'shutdown-windows' -Name 'Shut Down Windows' -Category 'Warning - Use With Caution' -Description 'Shuts down this computer after a 30-second warning.' -ScriptPath 'Shutdown-Windows.ps1' -Impact 'Open work may be lost. Windows displays a 30-second countdown before shutting down.' -ConflictGroup 'power-action' -ShowInAllScripts $false -RunOrder 900 -Accent '#A855F7' -SuccessMessage 'Windows accepted the shutdown request and started the 30-second countdown.'
    New-CatalogItem -Id 'erase-reinstall-windows' -Name 'Unattended Erase and Reinstall' -Category 'Warning - Use With Caution' -Description 'Fully cleans the internal Windows disk and reinstalls Windows without further reset prompts.' -ScriptPath 'Reset-WindowsRemoveEverything.ps1' -ScriptArguments '-Confirmation $EraseConfirmation' -Impact 'PERMANENT DATA LOSS: after a 60-second cancellation window, Microsoft protected wipe removes every user profile, application, setting, and partition from the internal Windows disk, including a D: partition on that same disk. Microsoft warns that some device configurations may become unbootable if recovery fails. This cannot be undone.' -RequiresAdmin $true -InputTitle 'Type ERASE ALL INTERNAL DATA' -InputMessage 'This unattended action is irreversible. Back up anything required, connect AC power, and have the BitLocker recovery key available. Type ERASE ALL INTERNAL DATA exactly to schedule the protected wipe of C: and any D: partition on the same disk.' -InputVariable 'EraseConfirmation' -RequiredInputValue 'ERASE ALL INTERNAL DATA' -ConflictGroup 'power-action' -CanQueue $false -ShowInAllScripts $false -ResultMode 'Terminal' -RunOrder 999 -Accent '#EF4444' -SuccessMessage 'The unattended protected wipe was scheduled with a 60-second cancellation window.'
    New-CatalogItem -Id 'always-on-power' -Name 'Keep PC Awake' -Category 'Power' -Description 'Keeps the display, computer, and laptop active for reliable remote access.' -ScriptPath 'Configure-AlwaysOnPower.ps1' -Impact 'Changes the active power plan, disables sleep and hibernation, and makes lid-close and power-button actions do nothing.' -RequiresAdmin $true -Accent '#22D3EE' -SuccessMessage 'The active power plan now keeps the computer awake on AC and battery.'
    New-CatalogItem -Id 'keep-network-active' -Name 'Keep Network Active' -Category 'Power' -Description 'Reduces adapter and power-plan sleep behavior so networking remains available while locked.' -ScriptPath 'Keep-NetworkActive.ps1' -Impact 'Disables several network, PCIe, and USB power-saving features and writes a log under C:\Tools\Logs.' -RequiresAdmin $true -Accent '#2DD4BF' -SuccessMessage 'Supported network power-saving settings were disabled to improve locked-session connectivity.'
    New-CatalogItem -Id 'hide-shutdown-options' -Name 'Hide Shutdown Options' -Category 'Security' -Description 'Hides Shutdown, Restart, Sleep, and Hibernate for existing and future Windows users without changing notification-area policy.' -ScriptPath 'Hide-ShutdownOptions.ps1' -Impact 'Sets only the documented per-user NoClose policy, including offline and Default user registry hives. It does not alter Windows PolicyManager defaults or system-tray policy.' -RequiresAdmin $true -ConflictGroup 'power-menu-visibility' -Accent '#C084FC' -SuccessMessage 'Power commands are hidden for existing profiles and the Default user profile without changing notification-area policy.'
    New-CatalogItem -Id 'repair-power-menu-system-tray' -Name 'Repair System Tray and Audio' -Category 'Fixes' -Description 'Restores machine audio and reverses legacy ScriptBox policies that can disturb Windows 11 shell surfaces.' -ScriptPath 'Repair-PowerMenuAndSystemTray.ps1' -Impact 'Removes ScriptBox''s local fDisableCam policy, returns Windows Audio Endpoint Builder and Windows Audio to Automatic/Running, re-enables audio devices disabled by Disable Machine Audio, restores the four legacy PolicyManager Start defaults, and removes ScriptBox''s NoClose value from existing and future-user profiles. Sign out or restart afterward to reload the shell.' -RequiresAdmin $true -ConflictGroup 'power-menu-visibility' -Accent '#34D399' -SuccessMessage 'Machine audio and legacy ScriptBox shell policies were restored; sign out or restart Windows to reload the system tray.'
    New-CatalogItem -Id 'idle-lock-10-minutes' -Name 'Lock After 10 Minutes' -Category 'Security' -Description 'Locks signed-in Windows sessions after ten minutes without keyboard or mouse activity.' -ScriptPath 'Configure-IdleLock.ps1' -Impact 'Sets computer and user inactivity policies and refreshes Group Policy. A sign-out or restart may be needed.' -RequiresAdmin $true -Accent '#F472B6' -SuccessMessage 'Windows is configured to lock idle sessions after ten minutes.'
    New-CatalogItem -Id 'allow-password-signin' -Name 'Allow Password Sign-in' -Category 'Security' -Description 'Allows Microsoft-account users to choose password sign-in while keeping their existing PIN.' -ScriptPath 'Allow-PasswordSignIn.ps1' -Impact 'Sets the machine-wide DevicePasswordLessBuildVersion registry value to 0. Existing Windows Hello PINs are not removed.' -RequiresAdmin $true -Accent '#C084FC' -SuccessMessage 'Password sign-in is permitted and existing Windows Hello PINs remain available.'
    New-CatalogItem -Id 'enable-location-services' -Name 'Enable Location Services' -Category 'Windows' -Description 'Removes common policy blocks and restores the Windows Geolocation Service.' -ScriptPath 'Enable-LocationServices.ps1' -Impact 'Changes machine policy values, configures lfsvc for demand start, starts it, and refreshes Group Policy.' -RequiresAdmin $true -Accent '#34D399' -SuccessMessage 'Location policy restrictions were removed and the Geolocation Service was restored.'
    New-CatalogItem -Id 'disable-ipv6' -Name 'Disable IPv6 Components' -Category 'Windows' -Description 'Uses the supported DisabledComponents registry policy to disable Windows IPv6 components.' -ScriptPath 'Disable-IPv6.ps1' -Impact 'Sets a machine-wide networking registry value to 0xFF. A restart is required and IPv6-dependent services may be affected.' -RequiresAdmin $true -Accent '#F59E0B' -SuccessMessage 'IPv6 components are configured as disabled and the change will apply after restart.'
    New-CatalogItem -Id 'disable-machine-audio' -Name 'Disable Machine Audio' -Category 'Windows' -Description 'Disables every audio device and Remote Desktop audio while keeping the Windows audio services running for the Windows 11 system tray.' -ScriptPath 'Disable-MachineAudio.ps1' -Impact 'Disables all present audio (MEDIA-class) devices and blocks RDP playback redirection, so playback and microphone/input audio are unavailable. Windows Audio and Audio Endpoint Builder stay Automatic and running so the Windows 11 taskbar, volume flyout, and Quick Settings remain responsive. Use Fixes > Repair System Tray and Audio to reverse it.' -RequiresAdmin $true -Accent '#F472B6' -SuccessMessage 'All audio devices are disabled while the Windows audio services keep the Windows 11 shell responsive.'
    New-CatalogItem -Id 'enable-rdp-current-user' -Name 'Enable Remote Desktop' -Category 'Remote Access' -Description 'Enables Remote Desktop for this PC with NLA and permits the interactively signed-in user.' -ScriptPath 'Enable-RDPForCurrentUser.ps1' -Impact 'Enables the machine-level Remote Desktop setting and policy, starts Remote Desktop Services, opens inbound TCP/UDP 3389 firewall rules, and changes local group membership.' -RequiresAdmin $true -Accent '#22D3EE' -SuccessMessage 'Remote Desktop was enabled for this PC, with NLA, firewall access, and user membership configured successfully.'
    New-CatalogItem -Id 'windows-update-security' -Name 'Security-Focused Updates' -Category 'Windows Update' -Description 'Keeps monthly updates automatic while blocking previews and deferring feature upgrades.' -ScriptPath 'Configure-WindowsUpdateSecurityFocused.ps1' -Impact 'Changes Windows Update policy, excludes drivers, defers feature upgrades for 365 days, and starts an update scan.' -RequiresAdmin $true -ConflictGroup 'windows-update-mode' -Accent '#34D399' -SuccessMessage 'Windows Update now prioritizes monthly quality updates without optional previews or drivers.'
    New-CatalogItem -Id 'windows-update-manual' -Name 'Manual Updates Only' -Category 'Windows Update' -Description 'Stops automatic update downloads and installations while keeping manual checking available.' -ScriptPath 'Configure-WindowsUpdateManual.ps1' -Impact 'Removes conflicting update policy and disables automatic Windows Update downloads and installation.' -RequiresAdmin $true -ConflictGroup 'windows-update-mode' -Accent '#F59E0B' -SuccessMessage 'Windows Update is now manual only; someone must regularly check and install security updates.'
    New-CatalogItem -Id 'install-ninite-apps' -Name 'Install Core Apps' -Category 'Software' -Description 'Installs or updates 7-Zip, Chrome, and Firefox through Ninite.' -ScriptPath 'Install-NiniteApps.ps1' -Impact 'Downloads a signed Ninite executable, runs it unattended, installs or updates three applications, then removes the installer.' -RequiresAdmin $true -Accent '#34D399' -SuccessMessage '7-Zip, Chrome, and Firefox were installed or updated.'
    New-CatalogItem -Id 'deploy-laptop-lid-check' -Name 'Deploy Laptop Lid Check' -Category 'Utilities' -Description 'Adds a Public Desktop shortcut that shows the current laptop-lid state in a friendly popup.' -ScriptPath 'Deploy-LaptopLidCheck.ps1' -Impact 'Creates C:\ProgramData\LaptopLidCheck and C:\Users\Public\Desktop\Folder.lnk for all users.' -RequiresAdmin $true -Accent '#C084FC' -SuccessMessage 'The matching Laptop Lid Check popup and Public Desktop shortcut were installed.'
    New-CatalogItem -Id 'show-connected-usb-devices' -Name 'View Connected USB Devices' -Category 'Utilities' -Description 'Shows present USB Plug and Play devices, locations, and USB paths in a formatted table popup.' -ScriptPath 'Show-ConnectedUSBDevices.ps1' -Impact 'Performs a read-only PnP device query and opens a sortable popup. It makes no system changes.' -CanQueue $false -ResultMode 'None' -Accent '#22D3EE' -SuccessMessage 'The connected USB device table was displayed.'
    New-CatalogItem -Id 'launch-jetfuel' -Name 'Launch JetFuel' -Category 'Tools' -Description 'Downloads and runs the current JetFuel launcher.' -SourceUri 'https://tails.revhooks.cc' -Impact 'Executes remote PowerShell from tails.revhooks.cc. Review the source you trust before running it.' -RequiresAdmin $true -NeedsBypass $true -ResultMode 'None' -Accent '#22D3EE'
    New-CatalogItem -Id 'launch-invokex' -Name 'Launch InvokeX' -Category 'Tools' -Description 'Downloads and runs the current InvokeX installer from GitHub.' -SourceUri 'https://raw.githubusercontent.com/GoblinRules/InvokeX/main/install.ps1' -Impact 'Executes remote PowerShell from GoblinRules/InvokeX. The downloaded tool may create its own files.' -NeedsBypass $true -ResultMode 'None' -Accent '#C084FC'
    New-CatalogItem -Id 'launch-winutil' -Name 'Launch WinUtil' -Category 'Tools' -Description 'Downloads and runs Chris Titus Tech Windows Utility.' -SourceUri 'https://christitus.com/win' -Impact 'Executes remote PowerShell from christitus.com. Changes are made only when selected inside WinUtil.' -RequiresAdmin $true -NeedsBypass $true -ResultMode 'None' -Accent '#2DD4BF'
    New-CatalogItem -Id 'kvm-client-tailscale-diagnostics' -Name 'KVM Client Tailscale Diagnostics' -Category 'Diagnostics' -Description 'Tests the viewer-side Tailscale path, latency, loss, NAT conditions, and JetKVM web reachability.' -ScriptPath 'KvmClientTailscaleDiagnostics.ps1' -ScriptArguments '-KvmName $KvmName -PingCount 10 -NonInteractive' -Impact 'Performs read-only Tailscale, ping, netcheck, and TCP tests and saves a text report to Downloads.' -InputTitle 'KVM machine name' -InputMessage 'Enter the KVM machine name exactly as it appears in Tailscale.' -InputVariable 'KvmName' -Accent '#22D3EE' -SuccessMessage 'The viewer-side KVM connection tests completed; review the good, warning, and problem counts below.'
    New-CatalogItem -Id 'kvm-site-network-diagnostics' -Name 'KVM Site Network Diagnostics' -Category 'Diagnostics' -Description 'Checks the KVM-site router path, NAT, firewall, UDP/STUN, port mapping, and Tailscale conditions.' -ScriptPath 'KvmSiteNetworkDiagnostics.ps1' -ScriptArguments '-KvmName $KvmName -NonInteractive' -Impact 'Performs read-only local and internet connectivity tests and saves a text report to Downloads.' -InputTitle 'KVM report label' -InputMessage 'Enter the KVM machine name. It labels the report and enables an optional Tailscale lookup.' -InputVariable 'KvmName' -Accent '#34D399' -SuccessMessage 'The KVM-site network tests completed; review the good, warning, and problem counts below.'
    New-CatalogItem -Id 'watch-wol-packets' -Name 'Watch Wake-on-LAN Packets' -Category 'Diagnostics' -Description 'Opens a live popup that watches network adapters for UDP packets on Wake-on-LAN ports 7 and 9.' -ScriptPath 'Watch-WakeOnLanPackets.ps1' -Impact 'Stops any existing machine-wide Pktmon capture, replaces all Pktmon filters with UDP 7 and 9 filters, and runs a live NIC capture until the popup closes. Closing it stops capture and removes the filters.' -RequiresAdmin $true -CanQueue $false -ResultMode 'None' -Accent '#34D399' -SuccessMessage 'Wake-on-LAN packet watching finished and Pktmon was cleaned up.'
    New-CatalogItem -Id 'configure-hp-bios' -Name 'Configure HP BIOS' -Category 'BIOS' -Description 'Configures common writable HP commercial BIOS settings and installs HPCMSL with compatible gallery tooling if needed.' -ScriptPath 'Configure-HPBIOS.ps1' -ScriptArguments '-BIOSPassword $BIOSPassword' -Impact 'If needed, installs the NuGet provider, repairs PackageManagement/PowerShellGet, accepts the HP module licence, and installs HPCMSL for all users. PSGallery is trusted only during setup and its prior policy is restored afterward. A fresh Windows PowerShell process is used, with PowerShell 7 as a fallback only when it is already installed. The action then changes supported firmware settings. Test each model and restart afterward.' -RequiresAdmin $true -InputTitle 'BIOS setup password' -InputMessage 'Optional: enter the BIOS setup password, or leave it blank if none is configured.' -InputVariable 'BIOSPassword' -InputOptional $true -InputSecret $true -ConflictGroup 'bios-vendor' -Accent '#22D3EE' -SuccessMessage 'Supported HP BIOS settings were applied or reported with model-specific guidance.'
    New-CatalogItem -Id 'configure-hp-g3-g5-mini-wol-kvm' -Name 'Configure HP G3/G5 Mini WOL/KVM' -Category 'BIOS' -Description 'Configures an HP EliteDesk 800 G3 or G5 Desktop Mini for JetKVM USB power, pre-boot keyboard access, and Wake-on-LAN.' -ScriptPath 'Configure-HPEliteDesk800G5WolKvm.ps1' -ScriptArguments '-BiosPassword $BIOSPassword' -Impact "The script is restricted to HP EliteDesk 800 G3 and G5 Desktop Mini systems, including 35W and 65W variants, so it stops without making changes on other models.`n`nIt will:`n$([char]0x2022) Check and configure the required HP BIOS settings for JetKVM USB power, pre-boot keyboard access, Wake-on-LAN, and recovery after a power cut. Settings are applied only when that exact HP BIOS setting is exposed; settings unavailable on a G3 or G5 are reported as warnings and are not guessed or forced.`n$([char]0x2022) Disable Windows Fast Startup.`n$([char]0x2022) Enable WakeOnMagicPacket and disable pattern-based waking on every physical wired Ethernet adapter that supports those options.`n$([char]0x2022) Enable supported driver options such as Shutdown WOL, S5 WOL, and PME.`n$([char]0x2022) Arm the Ethernet adapter with powercfg /deviceenablewake.`n$([char]0x2022) Avoid restarting the network adapter while running; some adapter changes require a PC restart before becoming active.`n$([char]0x2022) Export every HP BIOS setting and all configuration results to a TXT report.`n$([char]0x2022) Display the selected wired MAC address in colon format, for example AA:BB:CC:DD:EE:FF, and copy it to the clipboard.`n`nRestart the PC once after completion." -RequiresAdmin $true -InputTitle 'HP G3/G5 Mini BIOS password' -InputMessage 'Optional: enter the HP BIOS administrator password, or leave it blank if none is configured.' -InputVariable 'BIOSPassword' -InputOptional $true -InputSecret $true -ConflictGroup 'bios-vendor' -CanQueue $false -ResultMode 'None' -Accent '#F59E0B' -SuccessMessage 'The HP G3/G5 Mini WOL/KVM configuration finished and displayed its MAC address and report path.'
    New-CatalogItem -Id 'configure-dell-bios' -Name 'Configure Dell BIOS' -Category 'BIOS' -Description 'Configures common Dell commercial BIOS settings using Dell Command Configure.' -ScriptPath 'Configure-DellBIOS.ps1' -ScriptArguments '-BIOSPassword $BIOSPassword' -Impact 'May install Dell Command Configure and changes supported firmware settings. Test each model and restart afterward.' -RequiresAdmin $true -InputTitle 'BIOS setup password' -InputMessage 'Optional: enter the BIOS setup password, or leave it blank if none is configured.' -InputVariable 'BIOSPassword' -InputOptional $true -InputSecret $true -ConflictGroup 'bios-vendor' -Accent '#C084FC' -SuccessMessage 'Supported Dell BIOS settings were applied or reported with model-specific guidance.'
    New-CatalogItem -Id 'configure-lenovo-bios' -Name 'Configure Lenovo BIOS' -Category 'BIOS' -Description 'Configures Lenovo BIOS through built-in WMI, including a verified ThinkCentre M710q Tiny WOL/KVM profile.' -ScriptPath 'Configure-LenovoBIOS.ps1' -ScriptArguments '-BIOSPassword $BIOSPassword' -Impact 'On an M710q Tiny, enables Ethernet, WOL, Smart Power On, USB and legacy USB support; disables Enhanced Power Saving Mode; and powers on after AC recovery. Other Lenovo models receive exact-name matches only. Restart afterward.' -RequiresAdmin $true -InputTitle 'BIOS setup password' -InputMessage 'Optional: enter the Lenovo supervisor/administrator BIOS password, or leave it blank if none is configured.' -InputVariable 'BIOSPassword' -InputOptional $true -InputSecret $true -ConflictGroup 'bios-vendor' -Accent '#34D399' -SuccessMessage 'Lenovo BIOS settings were saved once and verified against the firmware readback report.'
)
# ============================== END CATALOG ================================

# InvokeX-compatible application actions in a portable ScriptBox shell. The
# shell itself remains install-free; an application is downloaded or launched
# only after its own action button (or an explicitly selected batch) is used.
$script:ApplicationLinks = @(
    [pscustomobject]@{ Id='trip'; Name='TRIP (Tray IP)'; Description='Lightweight system tray IP monitor with notifications and overlay.'; Tags=@('NETWORK','UTILITY'); Uri='https://github.com/GoblinRules/TRIP'; LinkLabel='GitHub'; Accent='#22D3EE'; Actions=@(
        [pscustomobject]@{ Text='Download Portable'; Type='Portable'; Uri='https://github.com/GoblinRules/TRIP/releases/download/v2.4.0/TRIP.exe'; FileName='TRIP.exe'; RequiresAdmin=$false; Impact='Downloads the portable TRIP executable to the current user''s Desktop. It does not run it automatically.' },
        [pscustomobject]@{ Text='Download Installer'; Type='Exe'; Uri='https://github.com/GoblinRules/TRIP/releases/download/v2.4.0/TRIP_Setup.exe'; FileName='TRIP_Setup.exe'; RequiresAdmin=$true; Impact='Downloads the TRIP installer to a temporary file and starts it with administrator rights.' }
    ) }
    [pscustomobject]@{ Id='clearshot'; Name='ClearShot'; Description='Screenshot tool with region capture, annotation editor, and hotkeys.'; Tags=@('UTILITY'); Uri='https://github.com/GoblinRules/ClearShot'; LinkLabel='GitHub'; Accent='#A855F7'; Actions=@(
        [pscustomobject]@{ Text='Download Portable'; Type='Portable'; Uri='https://github.com/GoblinRules/ClearShot/releases/download/v1.3.8/ClearShot.exe'; FileName='ClearShot.exe'; RequiresAdmin=$false; Impact='Downloads the portable ClearShot executable to the current user''s Desktop. It does not run it automatically.' },
        [pscustomobject]@{ Text='Download Installer'; Type='Exe'; Uri='https://github.com/GoblinRules/ClearShot/releases/download/v1.3.8/ClearShot_Setup_1.3.8.exe'; FileName='ClearShot_Setup_1.3.8.exe'; RequiresAdmin=$true; Impact='Downloads the ClearShot installer to a temporary file and starts it with administrator rights.' }
    ) }
    [pscustomobject]@{ Id='slickclick'; Name='SlickClick'; Description="Lightweight auto-clicker$([char]0x2014)set pace, pick targets, and use tray controls."; Tags=@('UTILITY'); Uri='https://github.com/GoblinRules/SlickClick'; LinkLabel='GitHub'; Accent='#34D399'; Actions=@(
        [pscustomobject]@{ Text='Download Portable'; Type='Portable'; Uri='https://github.com/GoblinRules/SlickClick/releases/download/V1.3.2/SlickClick.exe'; FileName='SlickClick.exe'; RequiresAdmin=$false; Impact='Downloads the portable SlickClick executable to the current user''s Desktop. It does not run it automatically.' },
        [pscustomobject]@{ Text='Download Installer'; Type='Exe'; Uri='https://github.com/GoblinRules/SlickClick/releases/download/V1.3.2/SlickClick_Setup_v1.3.2.exe'; FileName='SlickClick_Setup_v1.3.2.exe'; RequiresAdmin=$true; Impact='Downloads the SlickClick installer to a temporary file and starts it with administrator rights.' }
    ) }
    [pscustomobject]@{ Id='pyautoclicker'; Name='PyAutoClicker'; Description='Automated clicking utility for Windows.'; Tags=@('UTILITY'); Uri='https://github.com/GoblinRules/PyAutoClicker'; LinkLabel='GitHub'; Accent='#F59E0B'; Actions=@(
        [pscustomobject]@{ Text='Install'; Type='RemoteScript'; Uri='https://raw.githubusercontent.com/GoblinRules/PyAutoClicker/main/install.ps1'; FileName=''; RequiresAdmin=$true; Impact='Downloads and runs the current PyAutoClicker installation script from its GitHub repository.' }
    ) }
    [pscustomobject]@{ Id='ippy-tray'; Name='IP Python Tray App'; Description='System tray IP address display utility (legacy).'; Tags=@('NETWORK','UTILITY'); Uri='https://github.com/GoblinRules/ippy-tray-app'; LinkLabel='GitHub'; Accent='#38BDF8'; Actions=@(
        [pscustomobject]@{ Text='Install'; Type='RemoteScript'; Uri='https://raw.githubusercontent.com/GoblinRules/ippy-tray-app/main/install.ps1'; FileName=''; RequiresAdmin=$true; Impact='Downloads and runs the legacy IP Python Tray App installation script from its GitHub repository.' }
    ) }
    [pscustomobject]@{ Id='powereventprovider'; Name='PowerEventProvider'; Description='Power management event provider service.'; Tags=@('POWER','SYSTEM'); Uri='https://github.com/GoblinRules/powereventprovider'; LinkLabel='GitHub'; Accent='#F472B6'; Actions=@(
        [pscustomobject]@{ Text='Download & Install'; Type='Msi'; Uri='https://github.com/GoblinRules/powereventprovider/releases/download/V1.1/PowerEventProviderSetup.msi'; FileName='PowerEventProviderSetup.msi'; RequiresAdmin=$true; Impact='Downloads the PowerEventProvider MSI and installs it for this computer without forcing a restart.' },
        [pscustomobject]@{ Text='View Power Logs'; Type='Command'; Uri=''; FileName=''; RequiresAdmin=$false; Impact='Reads recent PowerEventProvider events from the Windows Application log.'; Script='Get-EventLog -LogName Application -Source "PowerEventProvider" -Newest 50 | Format-Table TimeGenerated, EntryType, Message -AutoSize -Wrap' }
    ) }
    [pscustomobject]@{ Id='ctt-winutil'; Name='CTT WinUtil'; Description='Windows utility collection by Chris Titus Tech.'; Tags=@('SYSTEM','UTILITY'); Uri='https://github.com/ChrisTitusTech/winutil'; LinkLabel='GitHub'; Accent='#2DD4BF'; Actions=@(
        [pscustomobject]@{ Text='Run WinUtil'; Type='RemoteWindow'; Uri='https://christitus.com/win'; FileName=''; RequiresAdmin=$true; Impact='Opens an elevated PowerShell window and runs the current CTT WinUtil launcher.' }
    ) }
    [pscustomobject]@{ Id='mass'; Name='MASS'; Description='Microsoft Activation Scripts.'; Tags=@('SYSTEM'); Uri='https://github.com/massgravel/Microsoft-Activation-Scripts'; LinkLabel='GitHub'; Accent='#C084FC'; Actions=@(
        [pscustomobject]@{ Text='Run MASS'; Type='RemoteWindow'; Uri='https://get.activated.win'; FileName=''; RequiresAdmin=$true; Impact='Opens an elevated PowerShell window and runs Microsoft Activation Scripts from its current launcher.' }
    ) }
    [pscustomobject]@{ Id='tailscale'; Name='Tailscale'; Description='VPN and secure networking mesh.'; Tags=@('NETWORK','SECURITY'); Uri='https://tailscale.com/'; LinkLabel='Website'; Accent='#60A5FA'; Actions=@(
        [pscustomobject]@{ Text='Download & Install'; Type='Exe'; Uri='https://pkgs.tailscale.com/stable/tailscale-setup-latest.exe'; FileName='Tailscale_Setup.exe'; RequiresAdmin=$true; Impact='Downloads the current stable Tailscale installer and starts it with administrator rights.' }
    ) }
    [pscustomobject]@{ Id='mumu'; Name='MuMu Player'; Description='Android emulator for Windows.'; Tags=@('UTILITY'); Uri='https://www.mumuplayer.com/'; LinkLabel='Website'; Accent='#FB7185'; Actions=@(
        [pscustomobject]@{ Text='Download & Install'; Type='Exe'; Uri='https://a11.gdl.netease.com/MuMu_5.0.2_gw-overseas12_all_1754534682.exe?n=MuMu_5.0.2_lMBe7ZC.exe'; FileName='MuMu_Player_Setup.exe'; RequiresAdmin=$true; Impact='Downloads the MuMu Player installer and starts it with administrator rights.' }
    ) }
    [pscustomobject]@{ Id='ninite'; Name='Ninite Installer'; Description='Essential apps bundle: 7-Zip, Chrome, and Firefox.'; Tags=@('UTILITY','BROWSER'); Uri='https://ninite.com/'; LinkLabel='Website'; Accent='#4ADE80'; Actions=@(
        [pscustomobject]@{ Text='Download & Install'; Type='Exe'; Uri='https://ninite.com/7zip-chrome-firefox/ninite.exe'; FileName='Ninite_Core_Apps.exe'; RequiresAdmin=$true; Impact='Downloads the Ninite bundle and installs or updates 7-Zip, Chrome, and Firefox.' }
    ) }
)

$script:IsAdministrator = Test-IsAdministrator
$script:TempRoot = New-ScriptBoxTempRoot

$windowXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="ScriptBox" Width="1480" Height="900" MinWidth="1120" MinHeight="720"
        WindowStartupLocation="CenterScreen" Background="{DynamicResource AppBackground}" Foreground="{DynamicResource PrimaryText}"
        FontFamily="Segoe UI" UseLayoutRounding="True">
    <Window.Resources>
        <SolidColorBrush x:Key="AppBackground" Color="#0A0A0F"/>
        <SolidColorBrush x:Key="SidebarBackground" Color="#0E0E16"/>
        <SolidColorBrush x:Key="SurfaceBackground" Color="#12121A"/>
        <SolidColorBrush x:Key="CardBackground" Color="#80161622"/>
        <SolidColorBrush x:Key="ControlBackground" Color="#1A1A28"/>
        <SolidColorBrush x:Key="InputBackground" Color="#1A1A28"/>
        <SolidColorBrush x:Key="TerminalBackground" Color="#08080D"/>
        <SolidColorBrush x:Key="ThemeBorder" Color="#14FFFFFF"/>
        <SolidColorBrush x:Key="PrimaryText" Color="#F0F0F5"/>
        <SolidColorBrush x:Key="SecondaryText" Color="#9898B0"/>
        <SolidColorBrush x:Key="MutedText" Color="#5A5A75"/>
        <LinearGradientBrush x:Key="AccentGradient" StartPoint="0,0" EndPoint="1,1">
            <GradientStop Color="#6366F1" Offset="0"/>
            <GradientStop Color="#4F46E5" Offset="1"/>
        </LinearGradientBrush>
        <LinearGradientBrush x:Key="DangerGradient" StartPoint="0,0" EndPoint="1,1">
            <GradientStop Color="#EF4444" Offset="0"/>
            <GradientStop Color="#DC2626" Offset="1"/>
        </LinearGradientBrush>
        <Style TargetType="Button">
            <Setter Property="Foreground" Value="{DynamicResource PrimaryText}"/>
            <Setter Property="Background" Value="{DynamicResource ControlBackground}"/>
            <Setter Property="BorderBrush" Value="{DynamicResource ThemeBorder}"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding" Value="14,8"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="ButtonBorder" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                                BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="6" Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}"
                                              VerticalAlignment="{TemplateBinding VerticalContentAlignment}"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="ButtonBorder" Property="Opacity" Value="0.88"/></Trigger>
                            <Trigger Property="IsPressed" Value="True"><Setter TargetName="ButtonBorder" Property="Opacity" Value="0.70"/></Trigger>
                            <Trigger Property="IsEnabled" Value="False"><Setter TargetName="ButtonBorder" Property="Opacity" Value="0.42"/></Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style TargetType="TextBox">
            <Setter Property="Foreground" Value="{DynamicResource PrimaryText}"/>
            <Setter Property="Background" Value="{DynamicResource InputBackground}"/>
            <Setter Property="BorderBrush" Value="{DynamicResource ThemeBorder}"/>
            <Setter Property="CaretBrush" Value="#6366F1"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="TextBox">
                        <Border Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                                BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="6">
                            <ScrollViewer x:Name="PART_ContentHost" Margin="{TemplateBinding Padding}"/>
                        </Border>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style TargetType="CheckBox">
            <Setter Property="Foreground" Value="{DynamicResource SecondaryText}"/>
            <Setter Property="VerticalContentAlignment" Value="Center"/>
        </Style>
    </Window.Resources>
    <Grid>
        <Grid.ColumnDefinitions>
            <ColumnDefinition Width="236"/>
            <ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>
        <Grid.RowDefinitions>
            <RowDefinition Height="62"/>
            <RowDefinition Height="*"/>
            <RowDefinition x:Name="TerminalRow" Height="170"/>
        </Grid.RowDefinitions>

        <Border x:Name="SidebarShell" Grid.Column="0" Grid.RowSpan="3" Background="{DynamicResource SidebarBackground}" BorderBrush="{DynamicResource ThemeBorder}" BorderThickness="0,0,1,0">
            <Grid Margin="16,18">
                <Grid.RowDefinitions>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="*"/>
                    <RowDefinition Height="0"/>
                    <RowDefinition Height="Auto"/>
                </Grid.RowDefinitions>
                <StackPanel Orientation="Horizontal">
                    <Border Width="44" Height="44" CornerRadius="10" Background="#1A6366F1" BorderBrush="#6366F1" BorderThickness="1">
                        <Image x:Name="AppIcon" Width="38" Height="38" Stretch="Uniform"/>
                    </Border>
                    <StackPanel Margin="11,1,0,0">
                        <TextBlock Text="SCRIPTBOX" FontSize="18" FontWeight="Bold" Foreground="{DynamicResource PrimaryText}"/>
                        <Border Background="#266366F1" CornerRadius="20" Padding="8,2" HorizontalAlignment="Left" Margin="0,2,0,0">
                            <TextBlock x:Name="VersionLabel" Text="PORTABLE" FontSize="9" FontWeight="SemiBold" Foreground="#818CF8"/>
                        </Border>
                    </StackPanel>
                </StackPanel>

                <Grid Grid.Row="1" Margin="0,30,0,18">
                    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
                    <TextBlock Text="SECTIONS" FontSize="10" FontWeight="Bold" Foreground="{DynamicResource MutedText}" Margin="4,0,0,10"/>
                    <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
                        <StackPanel x:Name="SectionHost" Margin="0,0,6,0"/>
                    </ScrollViewer>
                </Grid>

                <Border Grid.Row="3" Background="Transparent" BorderThickness="0" Padding="0">
                    <StackPanel>
                        <Button x:Name="ControlPanelButton" Content="&#x2692;  Control Panel" Height="34" FontSize="10" HorizontalContentAlignment="Left" Padding="11,6" Margin="0,0,0,6"/>
                        <Button x:Name="SettingsButton" Content="&#x2699;  Settings" Height="34" FontSize="10" HorizontalContentAlignment="Left" Padding="11,6" Margin="0,0,0,6"/>
                        <Button x:Name="OpenTerminalButton" Content="&#x25B0;  Terminal" Height="34" FontSize="10" HorizontalContentAlignment="Left" Padding="11,6" Margin="0,0,0,6"/>
                        <Button x:Name="TaskManagerButton" Content="&#x25A6;  Task Manager" Height="34" FontSize="10" HorizontalContentAlignment="Left" Padding="11,6" Margin="0,0,0,6"/>
                        <Button x:Name="ElevateButton" Content="&#x21BB;  Restart as Admin" Height="34" FontSize="10" HorizontalContentAlignment="Left" Padding="11,6" Margin="0,0,0,9"/>
                        <TextBlock x:Name="PrivilegeLabel" FontSize="10" FontWeight="SemiBold" Foreground="#22C55E" Margin="2,0,0,4"/>
                        <TextBlock Text="ScriptBox stays portable" FontSize="9" Foreground="{DynamicResource MutedText}" Margin="2,0,0,0"/>
                    </StackPanel>
                </Border>
            </Grid>
        </Border>

        <Grid Grid.Column="1" Grid.Row="0" Margin="26,10,26,8">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <Grid x:Name="SearchPanel" Width="520" HorizontalAlignment="Left">
                <TextBlock Text="&#x2315;" FontSize="17" Foreground="{DynamicResource MutedText}" Margin="13,7,0,0" Panel.ZIndex="1"/>
                <TextBlock x:Name="SearchHint" Text="Search apps and scripts...  (Ctrl+K)" FontSize="12" Foreground="{DynamicResource MutedText}"
                           Margin="39,12,0,0" IsHitTestVisible="False" Panel.ZIndex="1"/>
                <TextBox x:Name="SearchBox" Height="42" Padding="38,11,13,8" FontSize="13" VerticalContentAlignment="Center"/>
            </Grid>
            <StackPanel x:Name="BatchPanel" Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center" Margin="12,0,0,0">
                <Button x:Name="NewInstallButton" Content="NEW INSTALL" Height="42" Padding="14,7" Margin="0,0,8,0" Foreground="White" BorderThickness="0">
                    <Button.Background><LinearGradientBrush StartPoint="0,0" EndPoint="1,1"><GradientStop Color="#22C55E" Offset="0"/><GradientStop Color="#16A34A" Offset="1"/></LinearGradientBrush></Button.Background>
                </Button>
                <Button x:Name="ClearSelectionButton" Content="CLEAR" Height="42" Padding="12,7" Margin="0,0,8,0"
                        Background="{DynamicResource ControlBackground}" BorderBrush="{DynamicResource ThemeBorder}" Foreground="{DynamicResource SecondaryText}"/>
                <Button x:Name="RunSelectedButton" Content="RUN SELECTED (0)" Height="42" Padding="14,7"
                        Background="{DynamicResource AccentGradient}" BorderBrush="#6366F1" Foreground="White"/>
                <Button x:Name="ThemeToggleButton" Content="LIGHT" Height="42" Padding="12,7" Margin="8,0,0,0"/>
            </StackPanel>
        </Grid>

        <ScrollViewer Grid.Column="1" Grid.Row="1" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" Margin="26,12,12,8">
            <StackPanel>
                <StackPanel Margin="6,0,14,20">
                    <TextBlock x:Name="PageTitle" Text="Scripts" FontSize="28" FontWeight="Bold" Foreground="{DynamicResource PrimaryText}"/>
                    <TextBlock x:Name="ResultsLabel" Text="Safe, visible execution with live output." FontSize="13" Foreground="{DynamicResource SecondaryText}" Margin="0,5,0,0"/>
                </StackPanel>
                <Border x:Name="ScriptTabsPanel" Background="{DynamicResource SurfaceBackground}" BorderBrush="{DynamicResource ThemeBorder}" BorderThickness="1" CornerRadius="14" Padding="10" Margin="0,0,14,14">
                    <WrapPanel x:Name="CategoryHost"/>
                </Border>
                <WrapPanel x:Name="CardsHost"/>
            </StackPanel>
        </ScrollViewer>

        <Border x:Name="TerminalShell" Grid.Column="1" Grid.Row="2" Margin="26,4,26,12" Background="{DynamicResource TerminalBackground}" BorderBrush="{DynamicResource ThemeBorder}" BorderThickness="1" CornerRadius="10">
            <Grid>
                <Grid.RowDefinitions>
                    <RowDefinition Height="39"/>
                    <RowDefinition Height="*"/>
                </Grid.RowDefinitions>
                <Border BorderBrush="#0FFFFFFF" BorderThickness="0,0,0,1" Padding="14,0">
                    <Grid>
                        <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                            <Ellipse Width="10" Height="10" Fill="#EF4444" Margin="0,0,6,0"/>
                            <Ellipse Width="10" Height="10" Fill="#F59E0B" Margin="0,0,6,0"/>
                            <Ellipse Width="10" Height="10" Fill="#22C55E" Margin="0,0,9,0"/>
                            <TextBlock Text="TERMINAL" FontSize="10" FontWeight="Bold" Foreground="#9898B0" VerticalAlignment="Center"/>
                            <TextBlock x:Name="TerminalStatus" Text="  READY" FontSize="10" FontWeight="Bold" Foreground="#22C55E" VerticalAlignment="Center"/>
                        </StackPanel>
                        <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center">
                            <Button x:Name="ExpandTerminalButton" Content="EXPAND" FontSize="9" Padding="9,5" Margin="0,0,6,0"/>
                            <Button x:Name="CollapseTerminalButton" Content="COLLAPSE" FontSize="9" Padding="9,5" Margin="0,0,6,0"/>
                            <Button x:Name="CopyTerminalButton" Content="COPY ALL" FontSize="9" Padding="9,5" Margin="0,0,6,0"/>
                            <Button x:Name="ClearTerminalButton" Content="CLEAR" FontSize="9" Padding="11,5"/>
                        </StackPanel>
                    </Grid>
                </Border>
                <TextBox x:Name="TerminalOutput" Grid.Row="1" IsReadOnly="True" AcceptsReturn="True" TextWrapping="NoWrap"
                         VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto" BorderThickness="0"
                         FontFamily="Cascadia Mono,Consolas" FontSize="11" Padding="14,10" Background="{DynamicResource TerminalBackground}" Foreground="#9898B0"/>
            </Grid>
        </Border>
    </Grid>
</Window>
'@

[xml]$xamlXml = $windowXaml
$reader = New-Object System.Xml.XmlNodeReader($xamlXml)
$script:Window = [Windows.Markup.XamlReader]::Load($reader)

# Any unhandled dispatcher exception would otherwise terminate the host
# process, which is the user's own console when the launcher runs inline.
$script:Window.Dispatcher.Add_UnhandledException({
    param($sender, $eventArgs)
    $eventArgs.Handled = $true
    try { Add-TerminalLine ("Unexpected UI error: " + $eventArgs.Exception.Message) } catch { }
})

$script:CardsHost = $script:Window.FindName('CardsHost')
$script:CategoryHost = $script:Window.FindName('CategoryHost')
$script:SectionHost = $script:Window.FindName('SectionHost')
$script:ScriptTabsPanel = $script:Window.FindName('ScriptTabsPanel')
$script:SearchBox = $script:Window.FindName('SearchBox')
$script:SearchHint = $script:Window.FindName('SearchHint')
$script:SearchPanel = $script:Window.FindName('SearchPanel')
$script:PageTitle = $script:Window.FindName('PageTitle')
$script:ResultsLabel = $script:Window.FindName('ResultsLabel')
$script:TerminalOutput = $script:Window.FindName('TerminalOutput')
$script:TerminalStatus = $script:Window.FindName('TerminalStatus')
$script:TerminalRow = $script:Window.FindName('TerminalRow')
$script:ClearTerminalButton = $script:Window.FindName('ClearTerminalButton')
$script:CopyTerminalButton = $script:Window.FindName('CopyTerminalButton')
$script:ExpandTerminalButton = $script:Window.FindName('ExpandTerminalButton')
$script:CollapseTerminalButton = $script:Window.FindName('CollapseTerminalButton')
$script:RunSelectedButton = $script:Window.FindName('RunSelectedButton')
$script:ClearSelectionButton = $script:Window.FindName('ClearSelectionButton')
$script:NewInstallButton = $script:Window.FindName('NewInstallButton')
$script:ThemeToggleButton = $script:Window.FindName('ThemeToggleButton')
$script:ElevateButton = $script:Window.FindName('ElevateButton')
$script:ControlPanelButton = $script:Window.FindName('ControlPanelButton')
$script:SettingsButton = $script:Window.FindName('SettingsButton')
$script:OpenTerminalButton = $script:Window.FindName('OpenTerminalButton')
$script:TaskManagerButton = $script:Window.FindName('TaskManagerButton')
$script:PrivilegeLabel = $script:Window.FindName('PrivilegeLabel')
$script:AppIcon = $script:Window.FindName('AppIcon')
$script:VersionLabel = $script:Window.FindName('VersionLabel')

function Add-TerminalLine {
    param(
        [Parameter(Mandatory)][string]$Text,
        [switch]$NoTimestamp
    )
    $prefix = if ($NoTimestamp) { '' } else { '[{0}] ' -f (Get-Date -Format 'HH:mm:ss') }
    $script:TerminalOutput.AppendText($prefix + $Text + [Environment]::NewLine)
    $script:TerminalOutput.ScrollToEnd()
}

function Set-RunButtonsEnabled {
    param([bool]$Enabled)

    foreach ($button in $script:RunButtons) {
        $button.IsHitTestVisible = $Enabled
        $button.Focusable = $Enabled
        $button.Opacity = if ($Enabled) { 1.0 } else { 0.45 }
    }
    foreach ($control in $script:SelectionControls) {
        $control.IsHitTestVisible = $Enabled
        $control.Focusable = $Enabled
        $control.Opacity = if ($Enabled) { 1.0 } else { 0.45 }
    }
    foreach ($control in $script:ApplicationSelectionControls) {
        $control.IsHitTestVisible = $Enabled
        $control.Focusable = $Enabled
        $control.Opacity = if ($Enabled) { 1.0 } else { 0.45 }
    }
    Update-SelectionControls
}

function Update-SelectionControls {
    if ($script:ActiveSection -eq 'Applications') {
        $count = $script:SelectedApplicationIds.Count
        $script:RunSelectedButton.Content = "INSTALL SELECTED ($count)"
        $idle = -not $script:RunState -and -not $script:IsQueueRunning
        $canRun = $idle -and $count -ge 1

        $script:RunSelectedButton.IsHitTestVisible = $canRun
        $script:RunSelectedButton.Focusable = $canRun
        $script:RunSelectedButton.Opacity = if ($canRun) { 1.0 } else { 0.42 }
        $script:RunSelectedButton.ToolTip = if ($canRun) { 'Run the primary action for each selected application in order.' } else { 'Select one or more applications.' }
        $script:ClearSelectionButton.IsHitTestVisible = $canRun
        $script:ClearSelectionButton.Focusable = $canRun
        $script:ClearSelectionButton.Opacity = if ($canRun) { 1.0 } else { 0.42 }
        $script:ClearSelectionButton.ToolTip = if ($canRun) { 'Clear all selected applications.' } else { 'No applications are selected.' }
        return
    }

    $count = $script:SelectedIds.Count
    $script:RunSelectedButton.Content = "RUN SELECTED ($count)"
    $idle = -not $script:RunState -and -not $script:IsQueueRunning
    $canRun = $idle -and $count -ge 2
    $canClear = $idle -and $count -ge 1

    $script:RunSelectedButton.IsHitTestVisible = $canRun
    $script:RunSelectedButton.Focusable = $canRun
    $script:RunSelectedButton.Opacity = if ($canRun) { 1.0 } else { 0.42 }
    $script:RunSelectedButton.ToolTip = if ($canRun) { 'Run the selected scripts in order.' } else { 'Select at least two scripts to run a queue.' }

    $script:ClearSelectionButton.IsHitTestVisible = $canClear
    $script:ClearSelectionButton.Focusable = $canClear
    $script:ClearSelectionButton.Opacity = if ($canClear) { 1.0 } else { 0.42 }
    $script:ClearSelectionButton.ToolTip = if ($canClear) { 'Clear all selected scripts.' } else { 'No scripts are selected.' }
}

function Set-ApplicationSelected {
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][bool]$Selected
    )
    if ($Selected) { [void]$script:SelectedApplicationIds.Add($Id) } else { [void]$script:SelectedApplicationIds.Remove($Id) }
    Update-SelectionControls
}

function Set-CatalogItemSelected {
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][bool]$Selected
    )
    if ($Selected) { [void]$script:SelectedIds.Add($Id) } else { [void]$script:SelectedIds.Remove($Id) }
    Update-SelectionControls
}

function Show-ScriptBoxDialog {
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('OK', 'YesNo')][string]$Buttons = 'OK',
        [ValidateSet('Info', 'Warning')][string]$Kind = 'Info'
    )

    $popupXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="560" SizeToContent="Height" MinHeight="245" MaxHeight="520"
        WindowStartupLocation="CenterOwner" WindowStyle="None" AllowsTransparency="True"
        Background="Transparent" Foreground="#F8FAFC" FontFamily="Segoe UI"
        ResizeMode="NoResize" ShowInTaskbar="False">
    <Border Background="#12121A" BorderBrush="#14FFFFFF" BorderThickness="1" CornerRadius="14">
        <Border.Effect>
            <DropShadowEffect Color="#000000" BlurRadius="28" ShadowDepth="8" Opacity="0.65"/>
        </Border.Effect>
        <Grid>
            <Grid.RowDefinitions>
                <RowDefinition Height="52"/>
                <RowDefinition Height="*"/>
                <RowDefinition Height="70"/>
            </Grid.RowDefinitions>
            <Border x:Name="PopupDragRegion" CornerRadius="14,14,0,0" Background="#12121A" BorderBrush="#0FFFFFFF" BorderThickness="0,0,0,1">
                <Grid Margin="18,0,10,0">
                    <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                        <Ellipse Width="8" Height="8" Fill="#6366F1" Margin="0,0,10,0"/>
                        <TextBlock x:Name="PopupTitle" FontSize="13" FontWeight="Bold" Foreground="#F8FAFC" VerticalAlignment="Center"/>
                    </StackPanel>
                    <Button x:Name="PopupCloseButton" Content="&#xD7;" Width="34" Height="30" Padding="0"
                            HorizontalAlignment="Right" VerticalAlignment="Center" Background="Transparent"
                            BorderThickness="0" Foreground="#94A3B8" FontSize="20" FontWeight="Normal"/>
                </Grid>
            </Border>

            <Grid Grid.Row="1" Margin="24,24,28,22">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="58"/>
                    <ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>
                <Border x:Name="PopupMarkBorder" Width="44" Height="44" CornerRadius="22" VerticalAlignment="Top"
                        Background="#1AEF4444" BorderBrush="#EF4444" BorderThickness="1">
                    <TextBlock x:Name="PopupMark" Text="!" HorizontalAlignment="Center" VerticalAlignment="Center"
                               FontSize="22" FontWeight="Bold" Foreground="#EF4444"/>
                </Border>
                <StackPanel Grid.Column="1" VerticalAlignment="Center">
                    <TextBlock x:Name="PopupMessage" TextWrapping="Wrap" FontSize="13" LineHeight="20" Foreground="#DCE5F5"/>
                    <TextBlock x:Name="PopupHint" Text="Review the details above before continuing." Margin="0,12,0,0"
                               FontSize="10" FontWeight="SemiBold" Foreground="#64748B"/>
                </StackPanel>
            </Grid>

            <Border Grid.Row="2" Background="#12121A" CornerRadius="0,0,14,14" BorderBrush="#0FFFFFFF" BorderThickness="0,1,0,0">
                <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center" Margin="20,0">
                    <Button x:Name="PopupSecondaryButton" Content="CANCEL" MinWidth="104" Height="36" Margin="0,0,10,0"
                            Background="#1A1A28" BorderBrush="#14FFFFFF" Foreground="#9898B0"/>
                    <Button x:Name="PopupPrimaryButton" Content="CONTINUE" MinWidth="112" Height="36"
                            BorderThickness="0" Foreground="#FFFFFF">
                        <Button.Background><LinearGradientBrush StartPoint="0,0" EndPoint="1,1"><GradientStop Color="#6366F1" Offset="0"/><GradientStop Color="#4F46E5" Offset="1"/></LinearGradientBrush></Button.Background>
                    </Button>
                </StackPanel>
            </Border>
        </Grid>
    </Border>
</Window>
'@
    [xml]$popupXml = $popupXaml
    $popupReader = New-Object System.Xml.XmlNodeReader($popupXml)
    $popup = [Windows.Markup.XamlReader]::Load($popupReader)
    if ($script:Window.IsVisible) { $popup.Owner = $script:Window }
    $popup.FindName('PopupTitle').Text = $Title.ToUpperInvariant()
    $popup.FindName('PopupMessage').Text = $Message

    if ($Kind -eq 'Info') {
        $popup.FindName('PopupMark').Text = 'i'
        $popup.FindName('PopupMark').Foreground = '#6366F1'
        $popup.FindName('PopupMarkBorder').BorderBrush = '#6366F1'
        $popup.FindName('PopupHint').Text = 'ScriptBox keeps its temporary output until the task finishes.'
    }

    $primaryButton = $popup.FindName('PopupPrimaryButton')
    $secondaryButton = $popup.FindName('PopupSecondaryButton')
    if ($Buttons -eq 'OK') {
        $primaryButton.Content = 'OK'
        $secondaryButton.Visibility = 'Collapsed'
    } else {
        $primaryButton.Content = 'YES, RUN'
    }

    $answer = [pscustomobject]@{ Value = $false }
    $primaryButton.Add_Click({ $answer.Value = $true; $popup.Close() }.GetNewClosure())
    $secondaryButton.Add_Click({ $popup.Close() }.GetNewClosure())
    $popup.FindName('PopupCloseButton').Add_Click({ $popup.Close() }.GetNewClosure())
    $popup.FindName('PopupDragRegion').Add_MouseLeftButtonDown({
        param($sender, $eventArgs)
        if ($eventArgs.LeftButton -eq [Windows.Input.MouseButtonState]::Pressed) { $popup.DragMove() }
    }.GetNewClosure())
    if ($env:SCRIPTBOX_TEST_MODE -eq '1') {
        $popup.Add_ContentRendered({ $popup.Close() }.GetNewClosure())
    }
    $popup.ShowDialog() | Out-Null
    return $answer.Value
}

function Show-ScriptBoxInputDialog {
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$Message,
        [string]$InitialValue = '',
        [bool]$Optional = $false,
        [bool]$Secret = $false,
        [string]$RequiredValue = ''
    )

    $inputXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="560" SizeToContent="Height" MinHeight="300"
        WindowStartupLocation="CenterOwner" WindowStyle="None" AllowsTransparency="True"
        Background="Transparent" Foreground="#F8FAFC" FontFamily="Segoe UI"
        ResizeMode="NoResize" ShowInTaskbar="False">
    <Border Background="#12121A" BorderBrush="#14FFFFFF" BorderThickness="1" CornerRadius="14">
        <Border.Effect>
            <DropShadowEffect Color="#000000" BlurRadius="28" ShadowDepth="8" Opacity="0.65"/>
        </Border.Effect>
        <Grid>
            <Grid.RowDefinitions>
                <RowDefinition Height="52"/>
                <RowDefinition Height="*"/>
                <RowDefinition Height="70"/>
            </Grid.RowDefinitions>
            <Border x:Name="InputDragRegion" CornerRadius="14,14,0,0" Background="#12121A" BorderBrush="#0FFFFFFF" BorderThickness="0,0,0,1">
                <Grid Margin="18,0,10,0">
                    <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                        <Ellipse Width="8" Height="8" Fill="#22C55E" Margin="0,0,10,0"/>
                        <TextBlock x:Name="InputTitle" FontSize="13" FontWeight="Bold" Foreground="#F8FAFC" VerticalAlignment="Center"/>
                    </StackPanel>
                    <Button x:Name="InputCloseButton" Content="&#xD7;" Width="34" Height="30" Padding="0"
                            HorizontalAlignment="Right" VerticalAlignment="Center" Background="Transparent"
                            BorderThickness="0" Foreground="#94A3B8" FontSize="20" FontWeight="Normal"/>
                </Grid>
            </Border>

            <StackPanel Grid.Row="1" Margin="26,24,26,24">
                <TextBlock x:Name="InputMessage" TextWrapping="Wrap" FontSize="13" LineHeight="20" Foreground="#DCE5F5"/>
                <TextBox x:Name="InputValue" Margin="0,18,0,0" Height="42" Padding="12,9"
                         Background="#1A1A28" Foreground="#F0F0F5" CaretBrush="#6366F1"
                         BorderBrush="#14FFFFFF" BorderThickness="1" FontFamily="Cascadia Mono,Consolas" FontSize="13"/>
                <PasswordBox x:Name="SecretInputValue" Visibility="Collapsed" Margin="0,18,0,0" Height="42" Padding="12,9"
                             Background="#1A1A28" Foreground="#F0F0F5" CaretBrush="#6366F1"
                             BorderBrush="#14FFFFFF" BorderThickness="1" FontFamily="Cascadia Mono,Consolas" FontSize="13"/>
                <TextBlock x:Name="InputHint" Text="The value is passed only to this run." Margin="2,10,0,0"
                           FontSize="10" FontWeight="SemiBold" Foreground="#64748B"/>
            </StackPanel>

            <Border Grid.Row="2" Background="#12121A" CornerRadius="0,0,14,14" BorderBrush="#0FFFFFFF" BorderThickness="0,1,0,0">
                <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center" Margin="20,0">
                    <Button x:Name="InputCancelButton" Content="CANCEL" MinWidth="104" Height="36" Margin="0,0,10,0"
                            Background="#1A1A28" BorderBrush="#14FFFFFF" Foreground="#9898B0"/>
                    <Button x:Name="InputRunButton" Content="CONTINUE" MinWidth="112" Height="36"
                            BorderThickness="0" Foreground="#FFFFFF">
                        <Button.Background><LinearGradientBrush StartPoint="0,0" EndPoint="1,1"><GradientStop Color="#6366F1" Offset="0"/><GradientStop Color="#4F46E5" Offset="1"/></LinearGradientBrush></Button.Background>
                    </Button>
                </StackPanel>
            </Border>
        </Grid>
    </Border>
</Window>
'@
    [xml]$inputXml = $inputXaml
    $inputReader = New-Object System.Xml.XmlNodeReader($inputXml)
    $popup = [Windows.Markup.XamlReader]::Load($inputReader)
    if ($script:Window.IsVisible) { $popup.Owner = $script:Window }

    $popup.FindName('InputTitle').Text = $Title.ToUpperInvariant()
    $popup.FindName('InputMessage').Text = $Message
    $inputBox = $popup.FindName('InputValue')
    $secretBox = $popup.FindName('SecretInputValue')
    $inputHint = $popup.FindName('InputHint')
    $inputBox.Text = $InitialValue
    if ($Secret) {
        $inputBox.Visibility = 'Collapsed'
        $secretBox.Visibility = 'Visible'
        $secretBox.Password = $InitialValue
        $inputHint.Text = 'The password is masked, passed only to this run, and is not written to the log.'
    } elseif ($Optional) {
        $inputHint.Text = 'Optional: leave this blank to continue without a value.'
    } elseif ($RequiredValue) {
        $inputHint.Text = 'The text must match exactly before CONTINUE is accepted.'
    }
    $result = [pscustomobject]@{ Confirmed = $false; Value = '' }

    $accept = {
        $value = if ($Secret) { $secretBox.Password } else { $inputBox.Text }
        if (-not $Optional -and [string]::IsNullOrWhiteSpace($value)) { return }
        $normalizedValue = if ($null -eq $value) { '' } elseif ($Secret) { [string]$value } else { $value.Trim() }
        if ($RequiredValue -and -not [string]::Equals($normalizedValue, $RequiredValue, [StringComparison]::Ordinal)) {
            $inputHint.Text = "Enter $RequiredValue exactly; capitalization and internal spaces must match."
            $inputHint.Foreground = '#EF4444'
            $inputBox.Focus() | Out-Null
            $inputBox.SelectAll()
            return
        }
        $result.Confirmed = $true
        $result.Value = $normalizedValue
        $popup.Close()
    }.GetNewClosure()
    $popup.FindName('InputRunButton').Add_Click($accept)
    $popup.FindName('InputCancelButton').Add_Click({ $popup.Close() }.GetNewClosure())
    $popup.FindName('InputCloseButton').Add_Click({ $popup.Close() }.GetNewClosure())
    $popup.FindName('InputDragRegion').Add_MouseLeftButtonDown({
        param($sender, $eventArgs)
        if ($eventArgs.LeftButton -eq [Windows.Input.MouseButtonState]::Pressed) { $popup.DragMove() }
    }.GetNewClosure())
    $submitOnEnter = {
        param($sender, $eventArgs)
        if ($eventArgs.Key -eq [Windows.Input.Key]::Enter) { & $accept; $eventArgs.Handled = $true }
    }.GetNewClosure()
    $inputBox.Add_KeyDown($submitOnEnter)
    $secretBox.Add_KeyDown($submitOnEnter)
    $popup.Add_ContentRendered({
        if ($env:SCRIPTBOX_TEST_MODE -eq '1') {
            if ($Secret) { $secretBox.Password = 'scriptbox-test' } else { $inputBox.Text = 'scriptbox-test' }
            & $accept
        } else {
            if ($Secret) {
                $secretBox.Focus() | Out-Null
            } else {
                $inputBox.Focus() | Out-Null
                $inputBox.SelectAll()
            }
        }
    }.GetNewClosure())

    $popup.ShowDialog() | Out-Null
    return $result
}

function Get-CatalogPreview {
    param([Parameter(Mandatory)]$Item)

    if ($Item.InlineScript) { return $Item.InlineScript.ToString().Trim() }
    $arguments = if ($Item.ScriptArguments) { ' ' + $Item.ScriptArguments } else { '' }
    return @(
        '# Downloaded only when RUN is selected.',
        "`$source = Invoke-RestMethod -UseBasicParsing '$($Item.SourceUri)'",
        '$downloadedScript = [scriptblock]::Create($source)',
        ('& $downloadedScript' + $arguments)
    ) -join [Environment]::NewLine
}

function Show-ScriptInfo {
    param([Parameter(Mandatory)]$Item)

    $dialogXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="720" Height="610" MinWidth="620" MinHeight="500"
        WindowStartupLocation="CenterOwner" Background="Transparent" Foreground="#F8FAFC"
        FontFamily="Segoe UI" ResizeMode="CanResizeWithGrip" ShowInTaskbar="False"
        WindowStyle="None" AllowsTransparency="True">
    <Border Background="#12121A" BorderBrush="#14FFFFFF" BorderThickness="1" CornerRadius="14">
        <Grid>
            <Grid.RowDefinitions><RowDefinition Height="52"/><RowDefinition Height="*"/></Grid.RowDefinitions>
            <Border x:Name="InfoDragRegion" CornerRadius="14,14,0,0" Background="#12121A" BorderBrush="#0FFFFFFF" BorderThickness="0,0,0,1">
                <Grid Margin="18,0,10,0">
                    <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                        <Ellipse Width="8" Height="8" Fill="#6366F1" Margin="0,0,10,0"/>
                        <TextBlock Text="SCRIPT DETAILS" FontSize="11" FontWeight="Bold" Foreground="#E2E8F0" VerticalAlignment="Center"/>
                    </StackPanel>
                    <Button x:Name="WindowCloseButton" Content="&#xD7;" Width="34" Height="30" Padding="0" HorizontalAlignment="Right"
                            VerticalAlignment="Center" Background="Transparent" BorderThickness="0" Foreground="#94A3B8" FontSize="20"/>
                </Grid>
            </Border>
            <Grid Grid.Row="1" Margin="26,22,26,26">
                <Grid.RowDefinitions>
                    <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
                    <RowDefinition Height="*"/><RowDefinition Height="Auto"/>
                </Grid.RowDefinitions>
                <TextBlock x:Name="InfoTitle" FontSize="25" FontWeight="Bold"/>
                <TextBlock x:Name="InfoDescription" Grid.Row="1" Margin="0,9,0,0" TextWrapping="Wrap" Foreground="#9898B0" FontSize="13"/>
                <Border Grid.Row="2" Margin="0,18,0,16" Padding="14" CornerRadius="10" Background="#1A1A28" BorderBrush="#14FFFFFF" BorderThickness="1">
                    <StackPanel>
                        <TextBlock x:Name="InfoImpact" TextWrapping="Wrap" Foreground="#F59E0B" FontSize="12"/>
                        <TextBlock x:Name="InfoRequirements" TextWrapping="Wrap" Foreground="#9898B0" FontSize="12" Margin="0,8,0,0"/>
                    </StackPanel>
                </Border>
                <Grid Grid.Row="3">
                    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
                    <TextBlock Text="SCRIPT PREVIEW" FontSize="10" FontWeight="Bold" Foreground="#64748B" Margin="2,0,0,8"/>
                    <TextBox x:Name="InfoCode" Grid.Row="1" IsReadOnly="True" AcceptsReturn="True" TextWrapping="NoWrap"
                             VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto" Padding="14"
                             Background="#08080D" Foreground="#9898B0" BorderBrush="#14FFFFFF" BorderThickness="1"
                             FontFamily="Cascadia Mono,Consolas" FontSize="11"/>
                </Grid>
                <StackPanel Grid.Row="4" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,18,0,0">
                    <Button x:Name="CopyButton" Content="COPY SCRIPT" Margin="0,0,10,0" Padding="15,8" Background="#1A1A28" Foreground="#9898B0" BorderBrush="#14FFFFFF"/>
                    <Button x:Name="CloseButton" Content="CLOSE" Padding="20,8" Foreground="White" BorderThickness="0">
                        <Button.Background><LinearGradientBrush StartPoint="0,0" EndPoint="1,1"><GradientStop Color="#6366F1" Offset="0"/><GradientStop Color="#4F46E5" Offset="1"/></LinearGradientBrush></Button.Background>
                    </Button>
                </StackPanel>
            </Grid>
        </Grid>
    </Border>
</Window>
'@
    [xml]$dialogXml = $dialogXaml
    $dialogReader = New-Object System.Xml.XmlNodeReader($dialogXml)
    $dialog = [Windows.Markup.XamlReader]::Load($dialogReader)
    if ($script:Window.IsVisible) { $dialog.Owner = $script:Window }
    $dialog.Title = "$($Item.Name) - ScriptBox"
    $dialog.FindName('InfoTitle').Text = $Item.Name
    $dialog.FindName('InfoDescription').Text = $Item.Description
    $dialog.FindName('InfoImpact').Text = "IMPACT  $([char]0x2022)  $($Item.Impact)"

    $requirements = @()
    $requirements += if ($Item.RequiresAdmin) { 'Administrator approval: required' } else { 'Administrator approval: not required' }
    $requirements += if ($Item.NeedsBypass) { 'Execution policy: Bypass for this child process' } else { 'Execution policy: current/default policy' }
    if ($Item.RunsRemoteCode) { $requirements += 'Download: script source is fetched only when RUN begins' }
    if ($Item.InputVariable) {
        $inputTraits = @()
        if ($Item.InputOptional) { $inputTraits += 'optional' } else { $inputTraits += 'required' }
        if ($Item.InputSecret) { $inputTraits += 'masked' }
        $requirements += "Input: $($Item.InputTitle) requested before launch ($($inputTraits -join ', '))"
    }
    if (-not $Item.CanQueue) { $requirements += 'Batch queue: unavailable; run this action by itself' }
    $dialog.FindName('InfoRequirements').Text = ($requirements -join "  $([char]0x2022)  ")
    $code = Get-CatalogPreview -Item $Item
    $dialog.FindName('InfoCode').Text = $code

    $copyButton = $dialog.FindName('CopyButton')
    $closeButton = $dialog.FindName('CloseButton')
    $windowCloseButton = $dialog.FindName('WindowCloseButton')
    $copyButton.Add_Click({ [Windows.Clipboard]::SetText($code) }.GetNewClosure())
    $closeButton.Add_Click({ $dialog.Close() }.GetNewClosure())
    $windowCloseButton.Add_Click({ $dialog.Close() }.GetNewClosure())
    $dialog.FindName('InfoDragRegion').Add_MouseLeftButtonDown({
        param($sender, $eventArgs)
        if ($eventArgs.LeftButton -eq [Windows.Input.MouseButtonState]::Pressed) { $dialog.DragMove() }
    }.GetNewClosure())
    if ($env:SCRIPTBOX_TEST_MODE -eq '1') {
        $dialog.Add_ContentRendered({ $dialog.Close() }.GetNewClosure())
    }
    $dialog.ShowDialog() | Out-Null
}

function New-FriendlyResult {
    param(
        [Parameter(Mandatory)]$Item,
        [Parameter(Mandatory)][int]$ExitCode,
        [string]$Output = ''
    )

    $good = [regex]::Matches($Output, '(?im)(\[(SUCCESS|GOOD)\]|:\s*PASS\b)').Count
    $warning = [regex]::Matches($Output, '(?im)\[(WARNING|WARN|CHECK|AMBER|UNSUPPORTED)\]').Count
    $problem = [regex]::Matches($Output, '(?im)(\[(ERROR|BAD|RED)\]|:\s*FAIL\b)').Count
    if ($ExitCode -ne 0 -and $problem -eq 0) { $problem = 1 }

    $overall = [regex]::Match($Output, '(?im)^.*?Overall:\s*(.+)$')
    $summary = if ($overall.Success) { $overall.Groups[1].Value.Trim() } else { $Item.SuccessMessage }
    if ($ExitCode -ne 0) {
        $headline = 'This task needs attention'
        $state = 'Error'
        if (-not $overall.Success) { $summary = 'The task stopped before it could finish. Review the problem details and terminal output below.' }
    } elseif ($warning -gt 0 -or $problem -gt 0) {
        $headline = 'Completed with items to review'
        $state = 'Warning'
    } else {
        $headline = 'Completed successfully'
        $state = 'Success'
    }

    [pscustomobject]@{
        Item         = $Item
        ExitCode     = $ExitCode
        Output       = $Output
        GoodCount    = $good
        WarningCount = $warning
        ProblemCount = $problem
        Headline     = $headline
        Summary      = $summary
        State        = $state
    }
}

function Show-ScriptBoxResult {
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$Headline,
        [Parameter(Mandatory)][string]$Summary,
        [Parameter(Mandatory)][string]$Output,
        [int]$GoodCount = 0,
        [int]$WarningCount = 0,
        [int]$ProblemCount = 0,
        [ValidateSet('Success', 'Warning', 'Error')][string]$State = 'Success'
    )

    $resultXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="780" Height="660" MinWidth="680" MinHeight="560"
        WindowStartupLocation="CenterOwner" Background="Transparent" Foreground="#F8FAFC"
        FontFamily="Segoe UI" ResizeMode="CanResizeWithGrip" ShowInTaskbar="False"
        WindowStyle="None" AllowsTransparency="True">
    <Border x:Name="ResultFrame" Background="#12121A" BorderBrush="#22C55E" BorderThickness="1" CornerRadius="14">
        <Grid>
            <Grid.RowDefinitions><RowDefinition Height="52"/><RowDefinition Height="*"/></Grid.RowDefinitions>
            <Border x:Name="ResultDragRegion" CornerRadius="14,14,0,0" Background="#12121A" BorderBrush="#0FFFFFFF" BorderThickness="0,0,0,1">
                <Grid Margin="18,0,10,0">
                    <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                        <Ellipse x:Name="ResultDot" Width="8" Height="8" Fill="#22C55E" Margin="0,0,10,0"/>
                        <TextBlock Text="SCRIPT RESULTS" FontSize="11" FontWeight="Bold" Foreground="#E2E8F0"/>
                    </StackPanel>
                    <Button x:Name="ResultCloseX" Content="&#xD7;" Width="34" Height="30" Padding="0" HorizontalAlignment="Right"
                            VerticalAlignment="Center" Background="Transparent" BorderThickness="0" Foreground="#94A3B8" FontSize="20"/>
                </Grid>
            </Border>
            <Grid Grid.Row="1" Margin="26,22,26,26">
                <Grid.RowDefinitions>
                    <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
                    <RowDefinition Height="*"/><RowDefinition Height="Auto"/>
                </Grid.RowDefinitions>
                <TextBlock x:Name="ResultTitle" FontSize="13" FontWeight="Bold" Foreground="#94A3B8"/>
                <TextBlock x:Name="ResultHeadline" Grid.Row="1" Margin="0,5,0,0" FontSize="25" FontWeight="Bold" TextWrapping="Wrap"/>
                <Grid Grid.Row="2" Margin="0,18,0,16">
                    <Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition/><ColumnDefinition/></Grid.ColumnDefinitions>
                    <Border Margin="0,0,8,0" Padding="14" CornerRadius="10" Background="#1A22C55E" BorderBrush="#4D22C55E" BorderThickness="1">
                        <StackPanel><TextBlock Text="GOOD" Foreground="#22C55E" FontSize="10" FontWeight="Bold"/><TextBlock x:Name="GoodCount" Foreground="#F0F0F5" FontSize="24" FontWeight="Bold"/></StackPanel>
                    </Border>
                    <Border Grid.Column="1" Margin="4,0" Padding="14" CornerRadius="10" Background="#1AF59E0B" BorderBrush="#4DF59E0B" BorderThickness="1">
                        <StackPanel><TextBlock Text="REVIEW" Foreground="#F59E0B" FontSize="10" FontWeight="Bold"/><TextBlock x:Name="ReviewCount" Foreground="#F0F0F5" FontSize="24" FontWeight="Bold"/></StackPanel>
                    </Border>
                    <Border Grid.Column="2" Margin="8,0,0,0" Padding="14" CornerRadius="10" Background="#1AEF4444" BorderBrush="#4DEF4444" BorderThickness="1">
                        <StackPanel><TextBlock Text="PROBLEMS" Foreground="#EF4444" FontSize="10" FontWeight="Bold"/><TextBlock x:Name="ProblemCount" Foreground="#F0F0F5" FontSize="24" FontWeight="Bold"/></StackPanel>
                    </Border>
                </Grid>
                <Grid Grid.Row="3">
                    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
                    <Border Padding="14" CornerRadius="10" Background="#1A1A28" BorderBrush="#14FFFFFF" BorderThickness="1" Margin="0,0,0,14">
                        <TextBlock x:Name="ResultSummary" TextWrapping="Wrap" Foreground="#DCE5F5" FontSize="13" LineHeight="20"/>
                    </Border>
                    <TextBox x:Name="ResultOutput" Grid.Row="1" IsReadOnly="True" AcceptsReturn="True" TextWrapping="NoWrap"
                             VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto" Padding="14"
                             Background="#08080D" Foreground="#9898B0" BorderBrush="#14FFFFFF" BorderThickness="1"
                             FontFamily="Cascadia Mono,Consolas" FontSize="11"/>
                </Grid>
                <StackPanel Grid.Row="4" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,18,0,0">
                    <Button x:Name="ResultCopy" Content="COPY OUTPUT" Margin="0,0,10,0" Padding="22,8"
                            Background="#1A1A28" BorderBrush="#14FFFFFF" BorderThickness="1" Foreground="#9898B0"/>
                    <Button x:Name="ResultSave" Content="SAVE RESULTS" Margin="0,0,10,0" Padding="22,8"
                            Background="#1A1A28" BorderBrush="#14FFFFFF" BorderThickness="1" Foreground="#9898B0"/>
                    <Button x:Name="ResultClose" Content="DONE" Padding="22,8" Foreground="White" BorderThickness="0">
                        <Button.Background><LinearGradientBrush StartPoint="0,0" EndPoint="1,1"><GradientStop Color="#6366F1" Offset="0"/><GradientStop Color="#4F46E5" Offset="1"/></LinearGradientBrush></Button.Background>
                    </Button>
                </StackPanel>
            </Grid>
        </Grid>
    </Border>
</Window>
'@
    [xml]$resultXml = $resultXaml
    $resultReader = New-Object System.Xml.XmlNodeReader($resultXml)
    $dialog = [Windows.Markup.XamlReader]::Load($resultReader)
    if ($script:Window.IsVisible) { $dialog.Owner = $script:Window }
    $dialog.FindName('ResultTitle').Text = $Title.ToUpperInvariant()
    $dialog.FindName('ResultHeadline').Text = $Headline
    $dialog.FindName('ResultSummary').Text = $Summary
    $dialog.FindName('ResultOutput').Text = if ([string]::IsNullOrWhiteSpace($Output)) { 'No additional terminal details were returned.' } else { $Output.Trim() }
    $dialog.FindName('GoodCount').Text = [string]$GoodCount
    $dialog.FindName('ReviewCount').Text = [string]$WarningCount
    $dialog.FindName('ProblemCount').Text = [string]$ProblemCount
    $accent = switch ($State) { 'Error' { '#EF4444' } 'Warning' { '#F59E0B' } default { '#22C55E' } }
    $dialog.FindName('ResultFrame').BorderBrush = $accent
    $dialog.FindName('ResultDot').Fill = $accent
    $dialog.FindName('ResultClose').Add_Click({ $dialog.Close() }.GetNewClosure())
    $dialog.FindName('ResultCloseX').Add_Click({ $dialog.Close() }.GetNewClosure())
    $addTerminalLine = ${function:Add-TerminalLine}
    $saveTitle = $Title
    $dialog.FindName('ResultCopy').Add_Click({
        try { [Windows.Clipboard]::SetText($dialog.FindName('ResultOutput').Text) }
        catch { & $addTerminalLine "Results could not be copied: $($_.Exception.Message)" }
    }.GetNewClosure())
    $dialog.FindName('ResultSave').Add_Click({
        try {
            $saveDialog = New-Object Microsoft.Win32.SaveFileDialog
            $safeName = (($saveTitle -replace '[^A-Za-z0-9 _-]', ' ') -replace '\s+', '-').Trim('-')
            $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
            $saveDialog.FileName = if ($safeName) { "ScriptBox-Results-$safeName-$timestamp.txt" } else { "ScriptBox-Results-$timestamp.txt" }
            $saveDialog.Filter = 'Text files (*.txt)|*.txt|All files (*.*)|*.*'
            $saveDialog.InitialDirectory = [Environment]::GetFolderPath('Desktop')
            if ($saveDialog.ShowDialog()) {
                [IO.File]::WriteAllText($saveDialog.FileName, $dialog.FindName('ResultOutput').Text, (New-Object Text.UTF8Encoding($false)))
            }
        }
        catch { & $addTerminalLine "Results could not be saved: $($_.Exception.Message)" }
    }.GetNewClosure())
    $dialog.FindName('ResultDragRegion').Add_MouseLeftButtonDown({
        param($sender, $eventArgs)
        if ($eventArgs.LeftButton -eq [Windows.Input.MouseButtonState]::Pressed) { $dialog.DragMove() }
    }.GetNewClosure())
    if ($env:SCRIPTBOX_TEST_MODE -eq '1') { $dialog.Add_ContentRendered({ $dialog.Close() }.GetNewClosure()) }
    $dialog.ShowDialog() | Out-Null
}

function Get-CatalogPayload {
    param([Parameter(Mandatory)]$Item)

    if ($Item.InlineScript) { return $Item.InlineScript.ToString() }
    if ($Item.SourceUri -notmatch '^https://') { throw "Refusing to download a non-HTTPS script source: $($Item.SourceUri)" }
    $safeUri = $Item.SourceUri.Replace("'", "''")
    $safeTask = $Item.Name.Replace("'", "''")
    $arguments = if ($Item.ScriptArguments) { ' ' + $Item.ScriptArguments } else { '' }
    return @(
        "Write-Host '[INFO] Downloading $safeTask only now because RUN was selected.'",
        "`$source = Invoke-RestMethod -UseBasicParsing '$safeUri'",
        "if ([string]::IsNullOrWhiteSpace(`$source)) { throw 'The downloaded script was empty.' }",
        '$downloadedScript = [scriptblock]::Create($source)',
        ('& $downloadedScript' + $arguments)
    ) -join [Environment]::NewLine
}

function Start-CatalogItem {
    param(
        [Parameter(Mandatory)]$Item,
        [switch]$FromQueue
    )

    if ($script:RunState) {
        Add-TerminalLine 'Another script is already running.'
        return
    }

    if ($Item.RequiresConfirmation -and -not $FromQueue) {
        $warning = if ($Item.RunsRemoteCode) {
            "$($Item.Impact)`n`nOnly continue if you trust the listed source."
        } else {
            $Item.Impact
        }
        $confirmed = Show-ScriptBoxDialog -Title "Run $($Item.Name)?" -Message $warning -Buttons YesNo -Kind Warning
        if (-not $confirmed) {
            Add-TerminalLine "Cancelled: $($Item.Name)"
            return
        }
    }

    $inputPrelude = ''
    if ($Item.InputVariable) {
        $inputResult = Show-ScriptBoxInputDialog -Title $Item.InputTitle -Message $Item.InputMessage `
            -Optional $Item.InputOptional -Secret $Item.InputSecret -RequiredValue $Item.RequiredInputValue
        if (-not $inputResult.Confirmed) {
            Add-TerminalLine "Cancelled: $($Item.Name)"
            if ($FromQueue) {
                $script:QueueResults.Add((New-FriendlyResult -Item $Item -ExitCode 1 -Output '[WARNING] Cancelled by the user before launch.')) | Out-Null
                Start-NextQueuedItem
            }
            return
        }
        if ($Item.RequiredInputValue -and
            -not [string]::Equals($inputResult.Value, $Item.RequiredInputValue, [StringComparison]::Ordinal)) {
            Add-TerminalLine "Input did not match the exact required value for $($Item.Name); nothing was launched."
            return
        }
        $safeInputValue = $inputResult.Value.Replace("'", "''")
        $inputPrelude = '$' + $Item.InputVariable + " = '" + $safeInputValue + "'" + [Environment]::NewLine
    }

    try {
        if ([string]::IsNullOrWhiteSpace($script:TempRoot) -or -not (Test-Path -LiteralPath $script:TempRoot)) {
            $script:TempRoot = New-ScriptBoxTempRoot
            Add-TerminalLine 'The temporary workspace was missing and has been recreated safely.'
        }
        $runId = [Guid]::NewGuid().ToString('N')
        $logPath = Join-Path $script:TempRoot "$runId.log"
        $donePath = "$logPath.done"
        [IO.File]::WriteAllText($logPath, '', (New-Object Text.UTF8Encoding($false)))
    }
    catch {
        Add-TerminalLine ("Could not prepare the temporary output workspace: {0}" -f $_.Exception.Message)
        if ($FromQueue) {
            $script:QueueResults.Add((New-FriendlyResult -Item $Item -ExitCode 1 -Output ("[ERROR] " + $_.Exception.Message))) | Out-Null
            Start-NextQueuedItem
        }
        return
    }

    $safeLogPath = $logPath.Replace("'", "''")
    $safeName = $Item.Name.Replace("'", "''")
    try {
        $payload = $inputPrelude + (Get-CatalogPayload -Item $Item)
    }
    catch {
        Add-TerminalLine ("Could not prepare {0}: {1}" -f $Item.Name, $_.Exception.Message)
        if ($FromQueue) {
            $script:QueueResults.Add((New-FriendlyResult -Item $Item -ExitCode 1 -Output ("[ERROR] " + $_.Exception.Message))) | Out-Null
            Start-NextQueuedItem
        }
        return
    }
    $runnerTemplate = @'
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'Continue'
$logPath = '__LOG_PATH__'
function Write-TaskLog {
    param([object]$Value)
    $rendered = ($Value | Out-String -Width 240).TrimEnd()
    if ([string]::IsNullOrWhiteSpace($rendered)) { return }
    $line = '[{0}] {1}{2}' -f (Get-Date -Format 'HH:mm:ss'), $rendered, [Environment]::NewLine
    for ($attempt = 1; $attempt -le 8; $attempt++) {
        try {
            [IO.File]::AppendAllText($logPath, $line, (New-Object Text.UTF8Encoding($false)))
            return
        }
        catch [IO.IOException] {
            if ($attempt -eq 8) { throw }
            Start-Sleep -Milliseconds (25 * $attempt)
        }
    }
}
$exitCode = 0
try {
    Write-TaskLog 'Starting __TASK_NAME__...'
    & {
__PAYLOAD__
    } *>&1 | ForEach-Object { Write-TaskLog $_ }
    Write-TaskLog 'Task completed successfully.'
}
catch {
    $exitCode = 1
    Write-TaskLog ('ERROR: ' + $_.Exception.Message)
    Write-TaskLog $_.ScriptStackTrace
}
finally {
    [IO.File]::WriteAllText(($logPath + '.done'), [string]$exitCode, (New-Object Text.UTF8Encoding($false)))
}
exit $exitCode
'@
    $runner = $runnerTemplate.Replace('__LOG_PATH__', $safeLogPath).Replace('__TASK_NAME__', $safeName).Replace('__PAYLOAD__', $payload)
    $encoded = ConvertTo-EncodedPowerShellCommand -Text $runner

    $arguments = New-Object System.Collections.Generic.List[string]
    @('-NoLogo', '-NoProfile') | ForEach-Object { $arguments.Add($_) }
    if ($Item.NeedsBypass) {
        @('-ExecutionPolicy', 'Bypass') | ForEach-Object { $arguments.Add($_) }
    }
    @('-EncodedCommand', $encoded) | ForEach-Object { $arguments.Add($_) }

    $startParams = @{
        FilePath    = 'powershell.exe'
        ArgumentList = $arguments.ToArray()
        PassThru    = $true
        WindowStyle = 'Hidden'
        ErrorAction = 'Stop'
    }
    $willElevate = $Item.RequiresAdmin -and -not $script:IsAdministrator
    if ($willElevate) { $startParams.Verb = 'RunAs' }

    try {
        Add-TerminalLine ("Launching {0}{1}{2}..." -f $Item.Name,
            $(if ($willElevate) { ' with administrator approval' } else { '' }),
            $(if ($Item.NeedsBypass) { ' using a process-scoped policy bypass' } else { '' }))
        $process = Start-Process @startParams
        $script:RunState = [pscustomobject]@{
            Item        = $Item
            Process     = $process
            LogPath     = $logPath
            DonePath    = $donePath
            ReadLength  = 0
            FromQueue   = [bool]$FromQueue
        }
        $script:TerminalStatus.Text = '  RUNNING'
        $script:TerminalStatus.Foreground = '#3B82F6'
        Set-RunButtonsEnabled -Enabled $false
    }
    catch {
        Remove-Item -LiteralPath $logPath -Force -ErrorAction SilentlyContinue
        Add-TerminalLine ("Could not launch {0}: {1}" -f $Item.Name, $_.Exception.Message)
        $script:TerminalStatus.Text = '  READY'
        $script:TerminalStatus.Foreground = '#22C55E'
        if ($FromQueue) {
            $script:QueueResults.Add((New-FriendlyResult -Item $Item -ExitCode 1 -Output ("[ERROR] " + $_.Exception.Message))) | Out-Null
            Start-NextQueuedItem
        }
    }
}

function Set-ThemeBrushColor {
    param(
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$Color
    )

    $convertedColor = [Windows.Media.ColorConverter]::ConvertFromString($Color)
    $replacementBrush = New-Object Windows.Media.SolidColorBrush
    $replacementBrush.Color = $convertedColor
    $script:Window.Resources.Remove($Key)
    $script:Window.Resources.Add($Key, $replacementBrush)
}

function Set-ScriptBoxTheme {
    param([Parameter(Mandatory)][ValidateSet('Dark', 'Light')][string]$Theme)

    $script:IsDarkTheme = $Theme -eq 'Dark'
    $colors = if ($script:IsDarkTheme) {
        @{
            AppBackground     = '#0A0A0F'
            SidebarBackground = '#0E0E16'
            SurfaceBackground = '#12121A'
            CardBackground    = '#80161622'
            ControlBackground = '#1A1A28'
            InputBackground   = '#1A1A28'
            TerminalBackground = '#08080D'
            ThemeBorder       = '#14FFFFFF'
            PrimaryText       = '#F0F0F5'
            SecondaryText     = '#9898B0'
            MutedText         = '#5A5A75'
        }
    }
    else {
        @{
            AppBackground     = '#F5F5F8'
            SidebarBackground = '#EEEEF4'
            SurfaceBackground = '#FFFFFF'
            CardBackground    = '#CCFFFFFF'
            ControlBackground = '#E8E8EE'
            InputBackground   = '#FFFFFF'
            TerminalBackground = '#FAFAFA'
            ThemeBorder       = '#14000000'
            PrimaryText       = '#1A1A2E'
            SecondaryText     = '#555570'
            MutedText         = '#8888A0'
        }
    }

    foreach ($entry in $colors.GetEnumerator()) {
        Set-ThemeBrushColor -Key $entry.Key -Color $entry.Value
    }
    $script:ThemeToggleButton.Content = if ($script:IsDarkTheme) { 'LIGHT' } else { 'DARK' }
    $script:TerminalOutput.Foreground = if ($script:IsDarkTheme) { '#9898B0' } else { '#555570' }
}

function Open-ReferenceUri {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Uri
    )

    try {
        if ($Uri -notmatch '^https://') { throw 'Only HTTPS publisher links are allowed.' }
        Start-Process -FilePath $Uri -ErrorAction Stop
        Add-TerminalLine "Opened publisher page for $Name. ScriptBox did not download or install anything."
    }
    catch {
        Show-ScriptBoxDialog -Title 'Could not open publisher page' -Message $_.Exception.Message -Buttons OK -Kind Info | Out-Null
    }
}

function Get-ApplicationStatus {
    param([Parameter(Mandatory)]$Application)

    if ($script:ApplicationStatusCache.ContainsKey($Application.Id)) {
        return [string]$script:ApplicationStatusCache[$Application.Id]
    }
    if ($env:SCRIPTBOX_TEST_MODE -eq '1') {
        $testStatus = if ($Application.Id -in @('ctt-winutil', 'mass')) { 'AVAILABLE' } else { 'NOT INSTALLED' }
        $script:ApplicationStatusCache[$Application.Id] = $testStatus
        return $testStatus
    }

    $installed = $false
    $status = 'NOT INSTALLED'
    try {
        switch ($Application.Id) {
            'trip' {
                $installed = @(
                    (Join-Path $env:LOCALAPPDATA 'TRIP\TRIP.exe'),
                    (Join-Path ([Environment]::GetFolderPath('Desktop')) 'TRIP.exe'),
                    'C:\Tools\TRIP\TRIP.exe'
                ) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
            }
            'clearshot' {
                $installed = @(
                    (Join-Path $env:LOCALAPPDATA 'ClearShot\ClearShot.exe'),
                    (Join-Path ([Environment]::GetFolderPath('Desktop')) 'ClearShot.exe'),
                    'C:\Program Files\ClearShot\ClearShot.exe'
                ) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
            }
            'slickclick' {
                $installed = @(
                    (Join-Path $env:LOCALAPPDATA 'SlickClick\SlickClick.exe'),
                    (Join-Path ([Environment]::GetFolderPath('Desktop')) 'SlickClick.exe'),
                    'C:\Program Files\SlickClick\SlickClick.exe'
                ) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
            }
            'pyautoclicker' {
                $installed = @(
                    (Join-Path ([Environment]::GetFolderPath('Desktop')) 'PyAutoClicker.lnk'),
                    'C:\Tools\PyAutoClicker\auto_clicker.py',
                    (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\PyAutoClicker\PyAutoClicker.lnk')
                ) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
            }
            'ippy-tray' {
                $installed = @(
                    'C:\Tools\TRIP\trip.py',
                    'C:\Tools\ippy-tray-app\trip.py',
                    (Join-Path ([Environment]::GetFolderPath('Desktop')) 'TRIP.lnk')
                ) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
            }
            'powereventprovider' { $installed = $null -ne (Get-Service -Name 'PowerEventProvider' -ErrorAction SilentlyContinue) }
            'ctt-winutil' { $status = 'AVAILABLE' }
            'mass' {
                $licensedWindows = Get-CimInstance -ClassName SoftwareLicensingProduct `
                    -Filter "ApplicationID='55c92734-d682-4d71-983e-d6ec3f16059f' AND LicenseStatus=1" `
                    -ErrorAction SilentlyContinue | Where-Object PartialProductKey | Select-Object -First 1
                if ($licensedWindows) { $status = 'INSTALLED' } else { $status = 'AVAILABLE' }
            }
            'tailscale' {
                $installed = @('C:\Program Files\Tailscale\tailscale.exe', 'C:\Program Files (x86)\Tailscale\tailscale.exe') |
                    Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
            }
            'mumu' {
                $installed = @('C:\Program Files\MuMu Player 12\shell\MuMuPlayer.exe', 'C:\Program Files\Netease\MuMuPlayer-12.0\shell\MuMuPlayer.exe') |
                    Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
            }
            'ninite' {
                $missing = @(
                    'C:\Program Files\7-Zip\7z.exe',
                    'C:\Program Files\Google\Chrome\Application\chrome.exe',
                    'C:\Program Files\Mozilla Firefox\firefox.exe'
                ) | Where-Object { -not (Test-Path -LiteralPath $_) }
                $installed = @($missing).Count -eq 0
            }
        }
        if ($installed) { $status = 'INSTALLED' }
    }
    catch { $status = 'NOT INSTALLED' }

    $script:ApplicationStatusCache[$Application.Id] = $status
    return $status
}

function Set-ApplicationStatusPill {
    param(
        [Parameter(Mandatory)]$Pill,
        [Parameter(Mandatory)]$Label,
        [Parameter(Mandatory)][string]$Status
    )

    $Pill.Background = if ($Status -in @('INSTALLED','AVAILABLE')) { '#1A22C55E' } else { '#0AFFFFFF' }
    $Label.Text = if ($Status -eq 'INSTALLED') { "$([char]0x2713) INSTALLED" } elseif ($Status -eq 'AVAILABLE') { "$([char]0x2713) AVAILABLE" } else { "$([char]0x25CB) NOT INSTALLED" }
    $Label.Foreground = if ($Status -in @('INSTALLED','AVAILABLE')) { '#22C55E' } else { $script:Window.Resources['MutedText'] }
}

function Start-ApplicationStatusGather {
    # Resolves every application status in an in-process background runspace so
    # the file, service, and CIM probes never freeze the UI thread. The payload
    # reuses the literal body of Get-ApplicationStatus with a runspace-local
    # status cache, receives plain catalog data, and returns Id -> status.
    $statusScript = "param(`$applications)`n" +
        "try {`n" +
        "`$script:ApplicationStatusCache = @{}`n" +
        "function Get-ApplicationStatus {`n" + ${function:Get-ApplicationStatus}.ToString() + "`n}`n" +
        "`$statuses = @{}`n" +
        "foreach (`$application in `$applications) { `$statuses[[string]`$application.Id] = [string](Get-ApplicationStatus -Application `$application) }`n" +
        "`$statuses`n" +
        "}`ncatch { @{ StatusGatherError = [string]`$_.Exception.Message } }"
    $gatherShell = [powershell]::Create()
    [void]$gatherShell.AddScript($statusScript).AddArgument(@($script:ApplicationLinks))
    $gatherTimer = New-Object Windows.Threading.DispatcherTimer
    $gatherTimer.Interval = [TimeSpan]::FromMilliseconds(250)
    $script:ApplicationStatusGather = @{
        PowerShell = $gatherShell
        Handle     = $gatherShell.BeginInvoke()
        Timer      = $gatherTimer
    }
    $gatherTimer.Add_Tick({
        $gather = $script:ApplicationStatusGather
        if (-not $gather) { return }
        if (-not $gather.Handle.IsCompleted) { return }
        $gather.Timer.Stop()
        $script:ApplicationStatusGather = $null
        $statuses = $null
        $gatherError = $null
        try {
            $results = $gather.PowerShell.EndInvoke($gather.Handle)
            $statuses = @($results | Where-Object { $_ -is [Collections.IDictionary] }) | Select-Object -Last 1
        }
        catch { $gatherError = $_.Exception.Message }
        finally { $gather.PowerShell.Dispose() }
        if (-not $gatherError -and $null -ne $statuses -and $statuses.Contains('StatusGatherError')) {
            $gatherError = [string]$statuses['StatusGatherError']
        }
        if (-not $gatherError -and $null -eq $statuses) {
            $gatherError = 'The background status check returned no data.'
        }
        if ($gatherError) {
            # Leave the pills in their CHECKING state and report the failure once.
            Add-TerminalLine "Application statuses could not be checked: $gatherError"
            return
        }
        foreach ($key in @($statuses.Keys)) {
            $script:ApplicationStatusCache[[string]$key] = [string]$statuses[$key]
        }
        if ($script:ActiveSection -ne 'Applications') { return }
        foreach ($id in @($script:ApplicationStatusPills.Keys)) {
            if (-not $script:ApplicationStatusCache.ContainsKey($id)) { continue }
            $pillEntry = $script:ApplicationStatusPills[$id]
            try {
                Set-ApplicationStatusPill -Pill $pillEntry.Pill -Label $pillEntry.Label -Status ([string]$script:ApplicationStatusCache[$id])
            }
            catch { }
        }
    })
    $gatherTimer.Start()
}

function ConvertTo-SingleQuotedPowerShellLiteral {
    param([AllowEmptyString()][string]$Value)
    return "'" + $Value.Replace("'", "''") + "'"
}

function New-ApplicationActionScript {
    param(
        [Parameter(Mandatory)]$Application,
        [Parameter(Mandatory)]$Action
    )

    if ($Action.Type -notin @('Portable', 'Exe', 'Msi', 'RemoteScript', 'RemoteWindow', 'Command')) {
        throw "Unsupported application action type: $($Action.Type)"
    }
    if ($Action.Type -ne 'Command' -and $Action.Uri -notmatch '^https://') {
        throw 'Application downloads and launchers must use HTTPS.'
    }

    $uriLiteral = ConvertTo-SingleQuotedPowerShellLiteral -Value ([string]$Action.Uri)
    $fileNameLiteral = ConvertTo-SingleQuotedPowerShellLiteral -Value ([string]$Action.FileName)
    switch ($Action.Type) {
        'Portable' {
            return @"
`$url = $uriLiteral
`$fileName = $fileNameLiteral
`$desktop = [Environment]::GetFolderPath('Desktop')
if ([string]::IsNullOrWhiteSpace(`$desktop) -or -not (Test-Path -LiteralPath `$desktop)) { throw 'The current user Desktop could not be found.' }
`$destination = Join-Path `$desktop `$fileName
Write-Host "Downloading $($Application.Name) portable to `$destination..."
Invoke-WebRequest -UseBasicParsing -Uri `$url -OutFile `$destination
Write-Host "[SUCCESS] $($Application.Name) was saved to `$destination. It was not started automatically."
"@
        }
        'Exe' {
            return @"
`$url = $uriLiteral
`$fileName = $fileNameLiteral
`$downloadPath = Join-Path ([IO.Path]::GetTempPath()) (([Guid]::NewGuid().ToString('N')) + '-' + `$fileName)
try {
    Write-Host "Downloading $($Application.Name) installer..."
    Invoke-WebRequest -UseBasicParsing -Uri `$url -OutFile `$downloadPath
    `$signature = Get-AuthenticodeSignature -FilePath `$downloadPath
    Write-Host "Authenticode status: `$(`$signature.Status)"
    Write-Host 'Starting installer...'
    `$installer = Start-Process -FilePath `$downloadPath -Wait -PassThru
    if (`$installer.ExitCode -notin @(0, 3010)) { throw "Installer exited with code `$(`$installer.ExitCode)." }
    Write-Host "[SUCCESS] $($Application.Name) installer completed with exit code `$(`$installer.ExitCode)."
}
finally { Remove-Item -LiteralPath `$downloadPath -Force -ErrorAction SilentlyContinue }
"@
        }
        'Msi' {
            return @"
`$url = $uriLiteral
`$fileName = $fileNameLiteral
`$downloadPath = Join-Path ([IO.Path]::GetTempPath()) (([Guid]::NewGuid().ToString('N')) + '-' + `$fileName)
try {
    Write-Host "Downloading $($Application.Name) installer..."
    Invoke-WebRequest -UseBasicParsing -Uri `$url -OutFile `$downloadPath
    `$signature = Get-AuthenticodeSignature -FilePath `$downloadPath
    Write-Host "Authenticode status: `$(`$signature.Status)"
    `$msiArguments = '/i "{0}" /passive /norestart' -f `$downloadPath
    `$installer = Start-Process -FilePath 'msiexec.exe' -ArgumentList `$msiArguments -Wait -PassThru
    if (`$installer.ExitCode -notin @(0, 3010)) { throw "MSI installer exited with code `$(`$installer.ExitCode)." }
    Write-Host "[SUCCESS] $($Application.Name) installation completed with exit code `$(`$installer.ExitCode)."
}
finally { Remove-Item -LiteralPath `$downloadPath -Force -ErrorAction SilentlyContinue }
"@
        }
        'RemoteScript' {
            return @"
Write-Host "Downloading the $($Application.Name) installer script..."
`$source = Invoke-RestMethod -UseBasicParsing -Uri $uriLiteral
if ([string]::IsNullOrWhiteSpace(`$source)) { throw 'The downloaded installer script was empty.' }
& ([scriptblock]::Create(`$source))
Write-Host "[SUCCESS] The $($Application.Name) installer script completed."
"@
        }
        'RemoteWindow' {
            return @"
`$launcher = "& { `$source = Invoke-RestMethod -UseBasicParsing -Uri $uriLiteral; if ([string]::IsNullOrWhiteSpace(`$source)) { throw 'The downloaded launcher was empty.' }; & ([scriptblock]::Create(`$source)) }"
`$encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes(`$launcher))
Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-EncodedCommand',`$encoded)
Write-Host "[SUCCESS] $($Application.Name) was launched in a separate elevated window."
"@
        }
        'Command' { return [string]$Action.Script }
    }
}

function New-ApplicationCatalogItem {
    param(
        [Parameter(Mandatory)]$Application,
        [Parameter(Mandatory)]$Action
    )
    $scriptText = New-ApplicationActionScript -Application $Application -Action $Action
    return New-CatalogItem -Id ("application-{0}-{1}" -f $Application.Id, [Guid]::NewGuid().ToString('N')) `
        -Name ("{0} $([char]0x2014) {1}" -f $Application.Name, $Action.Text) -Category 'Applications' `
        -Description $Action.Impact -InlineScript ([scriptblock]::Create($scriptText)) `
        -RequiresAdmin ([bool]$Action.RequiresAdmin) -RequiresConfirmation $false `
        -CanQueue $true -ResultMode 'Summary' -Accent '#6366F1' `
        -SuccessMessage ("{0}: {1} completed." -f $Application.Name, $Action.Text)
}

function Start-ApplicationAction {
    param(
        [Parameter(Mandatory)]$Application,
        [Parameter(Mandatory)]$Action
    )
    if ($script:RunState -or $script:IsQueueRunning) {
        Add-TerminalLine 'Wait for the current task or queue to finish.'
        return
    }
    $sourceText = if ([string]::IsNullOrWhiteSpace([string]$Action.Uri)) { 'Built-in Windows command' } else { [string]$Action.Uri }
    $message = "$($Action.Impact)`n`nSource:`n$sourceText`n`nScriptBox itself remains portable; this action affects only the selected application."
    if (-not (Show-ScriptBoxDialog -Title "$($Action.Text) $($Application.Name)?" -Message $message -Buttons YesNo -Kind Warning)) {
        Add-TerminalLine "Cancelled: $($Application.Name) $([char]0x2014) $($Action.Text)"
        return
    }
    Start-CatalogItem -Item (New-ApplicationCatalogItem -Application $Application -Action $Action)
}

function Clear-SelectedApplications {
    if ($script:RunState -or $script:IsQueueRunning -or $script:SelectedApplicationIds.Count -eq 0) { return }
    $script:SelectedApplicationIds.Clear()
    Render-Applications
    Add-TerminalLine 'Application selection cleared.'
}

function Start-SelectedApplications {
    if ($script:RunState -or $script:IsQueueRunning) {
        Add-TerminalLine 'Wait for the current task or queue to finish.'
        return
    }
    $applications = @($script:ApplicationLinks | Where-Object { $script:SelectedApplicationIds.Contains($_.Id) })
    if ($applications.Count -lt 1) { return }
    $names = @($applications | ForEach-Object { "$([char]0x2022) $($_.Name) $([char]0x2014) $($_.Actions[0].Text)" }) -join [Environment]::NewLine
    $message = "ScriptBox will run each selected application's primary action in order:`n`n$names`n`nDownloads and installers may show administrator or vendor prompts."
    if (-not (Show-ScriptBoxDialog -Title "Install $($applications.Count) selected application(s)?" -Message $message -Buttons YesNo -Kind Warning)) {
        Add-TerminalLine 'Selected application queue cancelled.'
        return
    }

    $script:RunQueue.Clear()
    $script:QueueResults.Clear()
    foreach ($application in $applications) {
        $script:RunQueue.Enqueue((New-ApplicationCatalogItem -Application $application -Action $application.Actions[0]))
    }
    $script:QueueTitle = 'Selected applications'
    $script:QueueNoun = 'application actions'
    $script:IsQueueRunning = $true
    $script:SelectedApplicationIds.Clear()
    Render-Applications
    Set-RunButtonsEnabled -Enabled $false
    Add-TerminalLine "Queued $($applications.Count) application action(s) for sequential execution."
    Start-NextQueuedItem
}

function New-TagPill {
    param([Parameter(Mandatory)][string]$Tag)
    $colors = @{ NETWORK='#1F3B82F6'; UTILITY='#1F22C55E'; POWER='#1FF59E0B'; SYSTEM='#1F8B5CF6'; SECURITY='#1FEF4444'; BROWSER='#1F06B6D4' }
    $foregrounds = @{ NETWORK='#60A5FA'; UTILITY='#4ADE80'; POWER='#FBBF24'; SYSTEM='#A78BFA'; SECURITY='#F87171'; BROWSER='#22D3EE' }
    $pill = New-Object Windows.Controls.Border
    $pill.Background = $colors[$Tag]
    $pill.CornerRadius = '20'
    $pill.Padding = '7,2'
    $pill.Margin = '0,0,6,0'
    $text = New-Object Windows.Controls.TextBlock
    $text.Text = $Tag
    $text.FontSize = 8
    $text.FontWeight = 'Bold'
    $text.Foreground = $foregrounds[$Tag]
    $pill.Child = $text
    return $pill
}

function New-ApplicationCard {
    param([Parameter(Mandatory)]$Application)

    $border = New-Object Windows.Controls.Border
    $border.Width = 304
    $border.Height = 246
    $border.Margin = '0,0,14,14'
    $border.Padding = '16'
    $border.CornerRadius = '14'
    $border.Background = $script:Window.Resources['CardBackground']
    $border.BorderBrush = $script:Window.Resources['ThemeBorder']
    $border.BorderThickness = '1'

    $grid = New-Object Windows.Controls.Grid
    $grid.RowDefinitions.Add((New-Object Windows.Controls.RowDefinition -Property @{ Height = 'Auto' }))
    $grid.RowDefinitions.Add((New-Object Windows.Controls.RowDefinition -Property @{ Height = 58 }))
    $grid.RowDefinitions.Add((New-Object Windows.Controls.RowDefinition -Property @{ Height = 'Auto' }))
    $grid.RowDefinitions.Add((New-Object Windows.Controls.RowDefinition -Property @{ Height = 'Auto' }))
    $grid.RowDefinitions.Add((New-Object Windows.Controls.RowDefinition -Property @{ Height = '*' }))
    $grid.RowDefinitions.Add((New-Object Windows.Controls.RowDefinition -Property @{ Height = 'Auto' }))

    $header = New-Object Windows.Controls.Grid
    $header.ColumnDefinitions.Add((New-Object Windows.Controls.ColumnDefinition -Property @{ Width = '*' }))
    $header.ColumnDefinitions.Add((New-Object Windows.Controls.ColumnDefinition -Property @{ Width = 'Auto' }))
    $header.ColumnDefinitions.Add((New-Object Windows.Controls.ColumnDefinition -Property @{ Width = 'Auto' }))

    $name = New-Object Windows.Controls.TextBlock
    $name.Text = $Application.Name
    $name.FontSize = 15
    $name.FontWeight = 'Bold'
    $name.Foreground = $script:Window.Resources['PrimaryText']
    $name.VerticalAlignment = 'Center'
    $name.TextTrimming = 'CharacterEllipsis'

    $statusPill = New-Object Windows.Controls.Border
    $statusPill.CornerRadius = '20'
    $statusPill.Padding = '10,4'
    $statusPill.Margin = '7,0,7,0'
    [Windows.Controls.Grid]::SetColumn($statusPill, 1)
    $statusLabel = New-Object Windows.Controls.TextBlock
    $statusLabel.FontSize = 8
    $statusLabel.FontWeight = 'Bold'
    $statusPill.Child = $statusLabel
    if ($env:SCRIPTBOX_TEST_MODE -eq '1' -or $script:ApplicationStatusCache.ContainsKey($Application.Id)) {
        # Cached (or synchronous test-mode) statuses render immediately.
        Set-ApplicationStatusPill -Pill $statusPill -Label $statusLabel -Status (Get-ApplicationStatus -Application $Application)
    } else {
        # Unknown statuses render as CHECKING; the background gather started by
        # Render-Applications resolves them without blocking the UI thread.
        $statusPill.Background = '#0AFFFFFF'
        $statusLabel.Text = "$([char]0x25CC) CHECKING..."
        $statusLabel.Foreground = $script:Window.Resources['MutedText']
    }
    $script:ApplicationStatusPills[$Application.Id] = @{ Pill = $statusPill; Label = $statusLabel }

    $selectBox = New-Object Windows.Controls.CheckBox
    $selectBox.Width = 20
    $selectBox.Height = 20
    $selectBox.ToolTip = 'Select for batch action'
    $selectBox.VerticalAlignment = 'Center'
    $selectBox.IsChecked = $script:SelectedApplicationIds.Contains($Application.Id)
    [Windows.Controls.Grid]::SetColumn($selectBox, 2)
    $setApplicationSelected = ${function:Set-ApplicationSelected}
    $selectBox.Add_Checked({ & $setApplicationSelected -Id $Application.Id -Selected $true }.GetNewClosure())
    $selectBox.Add_Unchecked({ & $setApplicationSelected -Id $Application.Id -Selected $false }.GetNewClosure())
    $script:ApplicationSelectionControls.Add($selectBox)

    $header.Children.Add($name) | Out-Null
    $header.Children.Add($statusPill) | Out-Null
    $header.Children.Add($selectBox) | Out-Null

    $description = New-Object Windows.Controls.TextBlock
    $description.Text = $Application.Description
    $description.FontSize = 11
    $description.TextWrapping = 'Wrap'
    $description.Foreground = $script:Window.Resources['SecondaryText']
    $description.Margin = '0,9,0,4'
    [Windows.Controls.Grid]::SetRow($description, 1)

    $tags = New-Object Windows.Controls.WrapPanel
    $tags.Margin = '0,2,0,7'
    foreach ($tag in $Application.Tags) { $tags.Children.Add((New-TagPill -Tag $tag)) | Out-Null }
    [Windows.Controls.Grid]::SetRow($tags, 2)

    $linkButton = New-Object Windows.Controls.Button
    $linkButton.Content = "$([char]0x2197)  $($Application.LinkLabel)"
    $linkButton.HorizontalAlignment = 'Left'
    $linkButton.Padding = '0,2'
    $linkButton.Background = 'Transparent'
    $linkButton.BorderBrush = 'Transparent'
    $linkButton.Foreground = '#818CF8'
    $linkButton.FontSize = 10
    $openReferenceUri = ${function:Open-ReferenceUri}
    $linkButton.Add_Click({ & $openReferenceUri -Name $Application.Name -Uri $Application.Uri }.GetNewClosure())
    [Windows.Controls.Grid]::SetRow($linkButton, 3)

    $actions = New-Object Windows.Controls.WrapPanel
    $actionCount = @($Application.Actions).Count
    $actionWidth = if ($actionCount -gt 1) { 129 } else { 266 }
    $startApplicationAction = ${function:Start-ApplicationAction}
    foreach ($action in $Application.Actions) {
        $actionButton = New-Object Windows.Controls.Button
        $actionButton.Content = $action.Text
        $actionButton.Width = $actionWidth
        $actionButton.Height = 34
        $actionButton.Padding = '7,4'
        $actionButton.Margin = if ($actionCount -gt 1 -and $actions.Children.Count -eq 0) { '0,0,8,0' } else { '0' }
        $actionButton.Background = if ($actions.Children.Count -eq 0) { $script:Window.Resources['AccentGradient'] } else { $script:Window.Resources['ControlBackground'] }
        $actionButton.BorderBrush = if ($actions.Children.Count -eq 0) { '#6366F1' } else { $script:Window.Resources['ThemeBorder'] }
        $actionButton.Foreground = if ($actions.Children.Count -eq 0) { '#FFFFFF' } else { $script:Window.Resources['SecondaryText'] }
        $actionButton.FontSize = 9
        $actionButton.Add_Click({ & $startApplicationAction -Application $Application -Action $action }.GetNewClosure())
        $script:RunButtons.Add($actionButton)
        $actions.Children.Add($actionButton) | Out-Null
    }
    [Windows.Controls.Grid]::SetRow($actions, 5)

    $grid.Children.Add($header) | Out-Null
    $grid.Children.Add($description) | Out-Null
    $grid.Children.Add($tags) | Out-Null
    $grid.Children.Add($linkButton) | Out-Null
    $grid.Children.Add($actions) | Out-Null
    $border.Child = $grid
    return $border
}

function Render-Applications {
    $script:CardsHost.Children.Clear()
    $script:RunButtons.Clear()
    $script:SelectionControls.Clear()
    $script:ApplicationSelectionControls.Clear()
    $script:ApplicationStatusPills = @{}
    $query = $script:SearchBox.Text.Trim()
    $applications = @($script:ApplicationLinks | Where-Object {
        [string]::IsNullOrWhiteSpace($query) -or
        $_.Name.IndexOf($query, [StringComparison]::OrdinalIgnoreCase) -ge 0 -or
        $_.Description.IndexOf($query, [StringComparison]::OrdinalIgnoreCase) -ge 0 -or
        ($_.Tags -join ' ').IndexOf($query, [StringComparison]::OrdinalIgnoreCase) -ge 0
    })
    foreach ($application in $applications) {
        $script:CardsHost.Children.Add((New-ApplicationCard -Application $application)) | Out-Null
    }
    $script:ResultsLabel.Text = "$($applications.Count) application card(s). ScriptBox stays portable; downloads and installs run only when selected."
    Update-SelectionControls
    if ($script:RunState -or $script:IsQueueRunning) { Set-RunButtonsEnabled -Enabled $false }
    if ($env:SCRIPTBOX_TEST_MODE -ne '1') {
        # Resolve any uncached statuses off the UI thread. If a gather is
        # already in flight, its completion tick updates the pending pills.
        $pending = @($script:ApplicationLinks | Where-Object { -not $script:ApplicationStatusCache.ContainsKey($_.Id) })
        if ($pending.Count -gt 0 -and $null -eq $script:ApplicationStatusGather) {
            Start-ApplicationStatusGather
        }
    }
}

function New-FeatureCard {
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Description,
        [string]$Accent = '#22D3EE',
        [double]$Width = 500,
        [double]$MinHeight = 230
    )

    $border = New-Object Windows.Controls.Border
    $border.Width = $Width
    $border.MinHeight = $MinHeight
    $border.Margin = '0,0,14,14'
    $border.Padding = '18'
    $border.CornerRadius = '14'
    $border.Background = $script:Window.Resources['CardBackground']
    $border.BorderBrush = $script:Window.Resources['ThemeBorder']
    $border.BorderThickness = '1'

    $stack = New-Object Windows.Controls.StackPanel
    $heading = New-Object Windows.Controls.TextBlock
    $heading.Text = $Title
    $heading.FontSize = 19
    $heading.FontWeight = 'Bold'
    $heading.Foreground = $script:Window.Resources['PrimaryText']
    $stack.Children.Add($heading) | Out-Null

    $subheading = New-Object Windows.Controls.TextBlock
    $subheading.Text = $Description
    $subheading.FontSize = 11
    $subheading.TextWrapping = 'Wrap'
    $subheading.Foreground = $script:Window.Resources['SecondaryText']
    $subheading.Margin = '0,6,0,14'
    if ([string]::IsNullOrWhiteSpace($Description)) { $subheading.Visibility = 'Collapsed' }
    $stack.Children.Add($subheading) | Out-Null

    $body = New-Object Windows.Controls.StackPanel
    $stack.Children.Add($body) | Out-Null
    $border.Child = $stack
    return [pscustomobject]@{ Border = $border; Body = $body; Accent = $Accent }
}

function Add-FeatureLabel {
    param([Parameter(Mandatory)]$HostPanel, [Parameter(Mandatory)][string]$Text)
    $label = New-Object Windows.Controls.TextBlock
    $label.Text = $Text
    $label.FontSize = 10
    $label.FontWeight = 'SemiBold'
    $label.Foreground = $script:Window.Resources['SecondaryText']
    $label.Margin = '0,4,0,4'
    $HostPanel.Children.Add($label) | Out-Null
}

function New-FeatureInput {
    param([string]$Text = '')
    $input = New-Object Windows.Controls.TextBox
    $input.Text = $Text
    $input.Height = 36
    $input.Padding = '9,8'
    $input.FontSize = 12
    $input.Margin = '0,0,0,9'
    return $input
}

function New-FeatureButton {
    param(
        [Parameter(Mandatory)][string]$Text,
        [string]$Accent = '#22D3EE'
    )
    $button = New-Object Windows.Controls.Button
    $button.Content = $Text
    $button.Background = $script:Window.Resources['AccentGradient']
    $button.BorderThickness = '0'
    $button.Foreground = 'White'
    $button.Margin = '0,4,7,0'
    $button.Padding = '12,7'
    return $button
}

function Start-UtilityCommand {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Description,
        [Parameter(Mandatory)][string]$ScriptText,
        [bool]$RequiresAdmin = $false
    )

    $utilityItem = New-CatalogItem -Id ("utility-{0}" -f [Guid]::NewGuid().ToString('N')) `
        -Name $Name -Category 'Built-in' -Description $Description `
        -InlineScript ([scriptblock]::Create($ScriptText)) -RequiresAdmin $RequiresAdmin `
        -RequiresConfirmation $false -CanQueue $false -ResultMode 'Summary' -Accent '#22D3EE'
    Start-CatalogItem -Item $utilityItem
}

function Get-SafeNetworkTarget {
    param([Parameter(Mandatory)][string]$Target)
    $trimmed = $Target.Trim()
    if ($trimmed -notmatch '^[A-Za-z0-9](?:[A-Za-z0-9.:-]{0,252}[A-Za-z0-9])?$') {
        throw 'Enter a hostname or IP address using only letters, numbers, dots, colons, and hyphens.'
    }
    return $trimmed
}

function Render-NetworkTools {
    $script:CardsHost.Children.Clear()
    $script:RunButtons.Clear()
    $script:SelectionControls.Clear()
    $script:ApplicationSelectionControls.Clear()

    $pingCard = New-FeatureCard -Title 'Ping' -Description 'Send ICMP echo requests with a configurable count.' -Accent '#22D3EE'
    Add-FeatureLabel -HostPanel $pingCard.Body -Text 'Address'
    $pingTarget = New-FeatureInput -Text '8.8.8.8'
    $pingCard.Body.Children.Add($pingTarget) | Out-Null
    Add-FeatureLabel -HostPanel $pingCard.Body -Text "Count (1$([char]0x2013)50)"
    $pingCount = New-FeatureInput -Text '4'
    $pingCard.Body.Children.Add($pingCount) | Out-Null
    $pingButton = New-FeatureButton -Text 'RUN PING' -Accent '#22D3EE'
    $getSafeNetworkTarget = ${function:Get-SafeNetworkTarget}
    $startUtilityCommand = ${function:Start-UtilityCommand}
    $showScriptBoxDialog = ${function:Show-ScriptBoxDialog}
    $pingButton.Add_Click({
        try {
            $target = & $getSafeNetworkTarget -Target $pingTarget.Text
            $count = 0
            if (-not [int]::TryParse($pingCount.Text, [ref]$count) -or $count -lt 1 -or $count -gt 50) {
                throw 'Ping count must be between 1 and 50.'
            }
            & $startUtilityCommand -Name "Ping $target" -Description 'Built-in read-only ping.' `
                -ScriptText "& ping.exe -n $count '$target'"
        }
        catch { & $showScriptBoxDialog -Title 'Ping input' -Message $_.Exception.Message -Buttons OK -Kind Info | Out-Null }
    }.GetNewClosure())
    $pingCard.Body.Children.Add($pingButton) | Out-Null
    $script:CardsHost.Children.Add($pingCard.Border) | Out-Null

    $traceCard = New-FeatureCard -Title 'Traceroute' -Description 'Trace the network path to a hostname or IP address.' -Accent '#A855F7'
    Add-FeatureLabel -HostPanel $traceCard.Body -Text 'Destination'
    $traceTarget = New-FeatureInput -Text '1.1.1.1'
    $traceCard.Body.Children.Add($traceTarget) | Out-Null
    $traceButton = New-FeatureButton -Text 'RUN TRACEROUTE' -Accent '#A855F7'
    $traceButton.Add_Click({
        try {
            $target = & $getSafeNetworkTarget -Target $traceTarget.Text
            & $startUtilityCommand -Name "Traceroute $target" -Description 'Built-in read-only route trace.' `
                -ScriptText "& tracert.exe -d '$target'"
        }
        catch { & $showScriptBoxDialog -Title 'Traceroute input' -Message $_.Exception.Message -Buttons OK -Kind Info | Out-Null }
    }.GetNewClosure())
    $traceCard.Body.Children.Add($traceButton) | Out-Null
    $script:CardsHost.Children.Add($traceCard.Border) | Out-Null

    $latencyCard = New-FeatureCard -Title 'Latency Test' -Description 'Measure response-time range, average, and packet loss.' -Accent '#60A5FA'
    Add-FeatureLabel -HostPanel $latencyCard.Body -Text 'Address'
    $latencyTarget = New-FeatureInput -Text '1.1.1.1'
    $latencyCard.Body.Children.Add($latencyTarget) | Out-Null
    Add-FeatureLabel -HostPanel $latencyCard.Body -Text "Samples (2$([char]0x2013)50)"
    $latencyCount = New-FeatureInput -Text '10'
    $latencyCard.Body.Children.Add($latencyCount) | Out-Null
    $latencyButton = New-FeatureButton -Text 'RUN LATENCY TEST' -Accent '#60A5FA'
    $latencyButton.Add_Click({
        try {
            $target = & $getSafeNetworkTarget -Target $latencyTarget.Text
            $count = 0
            if (-not [int]::TryParse($latencyCount.Text, [ref]$count) -or $count -lt 2 -or $count -gt 50) {
                throw 'Sample count must be between 2 and 50.'
            }
            $latencyScript = @"
`$replies = @(Test-Connection -ComputerName '$target' -Count $count -ErrorAction SilentlyContinue)
`$times = @(`$replies | Select-Object -ExpandProperty ResponseTime)
if (`$times.Count -eq 0) { Write-Error 'No ping replies were received.'; exit 1 }
`$stats = `$times | Measure-Object -Minimum -Maximum -Average
`$loss = [Math]::Round((1 - (`$times.Count / $count)) * 100, 1)
Write-Host 'Latency test: $target'
Write-Host ('Replies: {0}/{1}  Loss: {2}%' -f `$times.Count, $count, `$loss)
Write-Host ('Minimum: {0} ms  Average: {1:N1} ms  Maximum: {2} ms' -f `$stats.Minimum, `$stats.Average, `$stats.Maximum)
"@
            & $startUtilityCommand -Name "Latency $target" -Description 'Built-in read-only latency test.' -ScriptText $latencyScript
        }
        catch { & $showScriptBoxDialog -Title 'Latency input' -Message $_.Exception.Message -Buttons OK -Kind Info | Out-Null }
    }.GetNewClosure())
    $latencyCard.Body.Children.Add($latencyButton) | Out-Null
    $script:CardsHost.Children.Add($latencyCard.Border) | Out-Null

    $quickCard = New-FeatureCard -Title 'Quick Network Actions' -Description 'Common Windows networking commands with output streamed below.' -Accent '#34D399'
    $quickButtons = New-Object Windows.Controls.WrapPanel
    foreach ($action in @(
        [pscustomobject]@{ Text = 'FLUSH DNS'; Name = 'Flush DNS'; Admin = $true; Script = '& ipconfig.exe /flushdns' },
        [pscustomobject]@{ Text = 'IPCONFIG'; Name = 'IPConfig'; Admin = $false; Script = '& ipconfig.exe' },
        [pscustomobject]@{ Text = 'IPCONFIG /ALL'; Name = 'IPConfig all'; Admin = $false; Script = '& ipconfig.exe /all' },
        [pscustomobject]@{ Text = 'NETWORK INFO'; Name = 'Network info'; Admin = $false; Script = 'Import-Module NetAdapter -ErrorAction SilentlyContinue; @(Get-NetAdapter -ErrorAction SilentlyContinue) | Sort-Object Status, Name | Format-Table Name, Status, LinkSpeed, MacAddress, InterfaceDescription -AutoSize | Out-String -Width 240' }
    )) {
        $actionButton = New-FeatureButton -Text $action.Text -Accent '#34D399'
        $actionButton.Add_Click({
            & $startUtilityCommand -Name $action.Name -Description 'Built-in network action.' `
                -ScriptText $action.Script -RequiresAdmin $action.Admin
        }.GetNewClosure())
        $quickButtons.Children.Add($actionButton) | Out-Null
    }
    $quickCard.Body.Children.Add($quickButtons) | Out-Null
    $script:CardsHost.Children.Add($quickCard.Border) | Out-Null

    $script:ResultsLabel.Text = 'Built-in ping, traceroute, latency, and quick network commands.'
}

function Render-Diagnostics {
    $script:CardsHost.Children.Clear()
    $script:RunButtons.Clear()
    $script:SelectionControls.Clear()
    $script:ApplicationSelectionControls.Clear()
    $diagnosticCard = New-FeatureCard -Title 'Network Diagnostics' `
        -Description 'Read-only gateway, internet, DNS, TCP, and HTTPS checks. Detailed KVM and Wake-on-LAN diagnostics are on the cards below.' `
        -Accent '#38BDF8' -Width 940 -MinHeight 300
    $checklist = New-Object Windows.Controls.TextBlock
    $checklist.Text = "$([char]0x2022) Active adapters and default gateway`n$([char]0x2022) Gateway and public ICMP reachability`n$([char]0x2022) DNS resolution`n$([char]0x2022) TCP 443 connectivity`n$([char]0x2022) HTTPS connectivity"
    $checklist.FontSize = 13
    $checklist.LineHeight = 24
    $checklist.Foreground = $script:Window.Resources['SecondaryText']
    $checklist.Margin = '0,0,0,14'
    $diagnosticCard.Body.Children.Add($checklist) | Out-Null
    $runButton = New-FeatureButton -Text 'RUN NETWORK DIAGNOSTICS' -Accent '#38BDF8'
    $startUtilityCommand = ${function:Start-UtilityCommand}
    $runButton.Add_Click({
        $diagnosticScript = @'
$ErrorActionPreference = 'Continue'
Import-Module NetAdapter, NetTCPIP, DnsClient -ErrorAction SilentlyContinue
Write-Host '=== ACTIVE NETWORK ADAPTERS ==='
@(Get-NetAdapter -ErrorAction SilentlyContinue) | Where-Object Status -eq 'Up' | Format-Table Name, LinkSpeed, MacAddress, InterfaceDescription -AutoSize | Out-String -Width 240
Write-Host ''
$route = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Sort-Object RouteMetric | Select-Object -First 1
$gateway = if ($route) { $route.NextHop } else { $null }
Write-Host "Default gateway: $gateway"
foreach ($target in @($gateway, '1.1.1.1', '8.8.8.8') | Where-Object { $_ }) {
    $ok = Test-Connection -ComputerName $target -Count 2 -Quiet -ErrorAction SilentlyContinue
    Write-Host ("Ping {0}: {1}" -f $target, $(if ($ok) { 'PASS' } else { 'FAIL' }))
}
try {
    $dns = Resolve-DnsName -Name 'www.microsoft.com' -Type A -ErrorAction Stop | Select-Object -First 1
    Write-Host "DNS www.microsoft.com: PASS ($($dns.IPAddress))"
}
catch { Write-Host "DNS www.microsoft.com: FAIL ($($_.Exception.Message))" }
$tcp = Test-NetConnection -ComputerName 'www.microsoft.com' -Port 443 -WarningAction SilentlyContinue
Write-Host "TCP www.microsoft.com:443: $(if ($tcp.TcpTestSucceeded) { 'PASS' } else { 'FAIL' })"
try {
    $response = Invoke-WebRequest -UseBasicParsing -Uri 'https://www.microsoft.com/' -Method Head -TimeoutSec 12
    Write-Host "HTTPS microsoft.com: PASS ($([int]$response.StatusCode))"
}
catch { Write-Host "HTTPS microsoft.com: FAIL ($($_.Exception.Message))" }
'@
        & $startUtilityCommand -Name 'Network diagnostics' -Description 'Built-in read-only network diagnostics.' -ScriptText $diagnosticScript
    }.GetNewClosure())
    $diagnosticCard.Body.Children.Add($runButton) | Out-Null
    $script:CardsHost.Children.Add($diagnosticCard.Border) | Out-Null
    # Diagnostics-category catalog cards render here instead of in Scripts.
    # RUN SELECTED is never visible in this section, so the SELECT checkbox
    # is omitted; every other card behavior matches the Scripts section.
    foreach ($item in @($script:Catalog | Where-Object Category -eq 'Diagnostics')) {
        $script:CardsHost.Children.Add((New-Card -Item $item -HideSelection)) | Out-Null
    }
    $script:ResultsLabel.Text = 'One-click read-only network health checks with live terminal output.'
    if ($script:RunState -or $script:IsQueueRunning) { Set-RunButtonsEnabled -Enabled $false }
}

function Get-SystemInfoSnapshot {
    $os = Get-CimInstance -ClassName Win32_OperatingSystem
    $computer = Get-CimInstance -ClassName Win32_ComputerSystem
    $cpu = Get-CimInstance -ClassName Win32_Processor | Select-Object -First 1
    $bios = Get-CimInstance -ClassName Win32_BIOS
    $gpu = @(Get-CimInstance -ClassName Win32_VideoController | Select-Object -ExpandProperty Name)
    $drives = @(Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType=3' | Sort-Object DeviceID)
    $adapters = @(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object Status -eq 'Up' | Sort-Object Name)
    $memoryGb = [Math]::Round($computer.TotalPhysicalMemory / 1GB, 1)
    $uptime = (Get-Date) - $os.LastBootUpTime

    $driveText = @($drives | ForEach-Object {
        $size = [Math]::Round($_.Size / 1GB, 1)
        $free = [Math]::Round($_.FreeSpace / 1GB, 1)
        "$($_.DeviceID)  $free GB free of $size GB"
    }) -join [Environment]::NewLine
    $networkText = @($adapters | ForEach-Object {
        $address = @(Get-NetIPAddress -InterfaceIndex $_.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object -ExpandProperty IPAddress) -join ', '
        "$($_.Name)  $([char]0x2022)  $($_.LinkSpeed)`n$address`n$($_.MacAddress)"
    }) -join ([Environment]::NewLine + [Environment]::NewLine)

    return [ordered]@{
        'Operating System' = "$($os.Caption)`nVersion $($os.Version)  $([char]0x2022)  Build $($os.BuildNumber)`nUptime: $($uptime.Days)d $($uptime.Hours)h $($uptime.Minutes)m"
        'Hardware' = "$($computer.Manufacturer) $($computer.Model)`nCPU: $($cpu.Name)`nRAM: $memoryGb GB`nGPU: $($gpu -join ', ')"
        'Firmware' = "BIOS: $($bios.SMBIOSBIOSVersion)`nSerial: $($bios.SerialNumber)`nComputer: $env:COMPUTERNAME`nUser: $env:USERDOMAIN\$env:USERNAME"
        'Storage' = $(if ($driveText) { $driveText } else { 'No local fixed disks reported.' })
        'Network' = $(if ($networkText) { $networkText } else { 'No active network adapters reported.' })
    }
}

function New-SystemInfoCard {
    param([Parameter(Mandatory)][string]$Title, [Parameter(Mandatory)][string]$Value)
    $card = New-FeatureCard -Title $Title -Description '' -Accent '#60A5FA' -Width 500 -MinHeight 180
    $text = New-Object Windows.Controls.TextBlock
    $text.Text = $Value
    $text.FontFamily = 'Segoe UI'
    $text.FontSize = 12
    $text.LineHeight = 20
    $text.TextWrapping = 'Wrap'
    $text.Foreground = $script:Window.Resources['SecondaryText']
    $card.Body.Children.Add($text) | Out-Null
    return $card.Border
}

function Add-SystemInfoCards {
    foreach ($entry in $script:SystemInfoSnapshot.GetEnumerator()) {
        $script:CardsHost.Children.Add((New-SystemInfoCard -Title $entry.Key -Value ([string]$entry.Value))) | Out-Null
    }
    $refresh = New-FeatureCard -Title 'Refresh' -Description 'Reload the hardware, storage, and network snapshot.' -Accent '#34D399' -Width 500 -MinHeight 140
    $refreshButton = New-FeatureButton -Text 'REFRESH SYSTEM INFO' -Accent '#34D399'
    $refreshButton.Add_Click({
        $script:SystemInfoLoaded = $false
        $script:SystemInfoSnapshot = $null
        Render-SystemInfo
    })
    $refresh.Body.Children.Add($refreshButton) | Out-Null
    $script:CardsHost.Children.Add($refresh.Border) | Out-Null
    $script:ResultsLabel.Text = 'Read-only operating system, hardware, storage, and network details.'
}

function Start-SystemInfoGather {
    # Runs the snapshot in an in-process background runspace so multi-second
    # CIM and adapter queries never freeze the UI thread. The payload reuses
    # the literal body of Get-SystemInfoSnapshot, which is self-contained.
    $snapshotScript = "try {`n" + ${function:Get-SystemInfoSnapshot}.ToString() + "`n}`ncatch { [ordered]@{ SnapshotError = [string]`$_.Exception.Message } }"
    $gatherShell = [powershell]::Create()
    [void]$gatherShell.AddScript($snapshotScript)
    $gatherTimer = New-Object Windows.Threading.DispatcherTimer
    $gatherTimer.Interval = [TimeSpan]::FromMilliseconds(250)
    $script:SystemInfoGather = @{
        PowerShell = $gatherShell
        Handle     = $gatherShell.BeginInvoke()
        Timer      = $gatherTimer
    }
    $gatherTimer.Add_Tick({
        $gather = $script:SystemInfoGather
        if (-not $gather) { return }
        if (-not $gather.Handle.IsCompleted) { return }
        $gather.Timer.Stop()
        $script:SystemInfoGather = $null
        $snapshot = $null
        $gatherError = $null
        try {
            $results = $gather.PowerShell.EndInvoke($gather.Handle)
            $snapshot = @($results | Where-Object { $_ -is [Collections.IDictionary] }) | Select-Object -Last 1
        }
        catch { $gatherError = $_.Exception.Message }
        finally { $gather.PowerShell.Dispose() }
        if (-not $gatherError -and $null -ne $snapshot -and $snapshot.Contains('SnapshotError')) {
            $gatherError = [string]$snapshot['SnapshotError']
        }
        if (-not $gatherError -and $null -eq $snapshot) {
            $gatherError = 'The background snapshot returned no data.'
        }
        if ($gatherError) {
            $script:SystemInfoLoaded = $false
            $script:SystemInfoSnapshot = $null
            if ($script:ActiveSection -eq 'System Info') {
                $script:ResultsLabel.Text = "System information could not be loaded: $gatherError"
                Add-TerminalLine $script:ResultsLabel.Text
            }
            return
        }
        $script:SystemInfoSnapshot = $snapshot
        $script:SystemInfoLoaded = $true
        if ($script:ActiveSection -eq 'System Info') { Render-SystemInfo }
    })
    $gatherTimer.Start()
}

function Render-SystemInfo {
    $script:CardsHost.Children.Clear()
    $script:RunButtons.Clear()
    $script:SelectionControls.Clear()
    $script:ApplicationSelectionControls.Clear()
    try {
        if ($script:SystemInfoLoaded -and $null -ne $script:SystemInfoSnapshot) {
            Add-SystemInfoCards
            return
        }
        $script:ResultsLabel.Text = 'Gathering system information...'
        if ($env:SCRIPTBOX_TEST_MODE -eq '1') {
            # The validation harness asserts card counts immediately after
            # selecting the section, so gather synchronously in test mode.
            $script:SystemInfoSnapshot = Get-SystemInfoSnapshot
            $script:SystemInfoLoaded = $true
            Add-SystemInfoCards
            return
        }
        $placeholder = New-FeatureCard -Title 'System Information' `
            -Description 'Gathering system information... The cards will appear here in a moment.' `
            -Accent '#60A5FA' -Width 500 -MinHeight 140
        $script:CardsHost.Children.Add($placeholder.Border) | Out-Null
        if ($null -ne $script:SystemInfoGather) { return } # a gather is already in flight
        Start-SystemInfoGather
    }
    catch {
        $script:ResultsLabel.Text = "System information could not be loaded: $($_.Exception.Message)"
        Add-TerminalLine $script:ResultsLabel.Text
    }
}

function Set-TerminalMode {
    param([Parameter(Mandatory)][ValidateSet('Normal', 'Collapsed', 'Expanded')][string]$Mode)
    $script:TerminalMode = $Mode
    switch ($Mode) {
        'Collapsed' { $script:TerminalRow.Height = New-Object Windows.GridLength(48) }
        'Expanded'  { $script:TerminalRow.Height = New-Object Windows.GridLength(1.6, ([Windows.GridUnitType]::Star)) }
        default     { $script:TerminalRow.Height = New-Object Windows.GridLength(170) }
    }
    $script:TerminalOutput.Visibility = if ($Mode -eq 'Collapsed') { 'Collapsed' } else { 'Visible' }
}

function Restart-ScriptBoxAsAdministrator {
    if ($script:IsAdministrator) {
        Show-ScriptBoxDialog -Title 'Already elevated' -Message 'ScriptBox is already running with administrator rights.' -Buttons OK -Kind Info | Out-Null
        return
    }
    try {
        $handoff = "& { Invoke-RestMethod -UseBasicParsing '$($script:SelfSource)' | Invoke-Expression }"
        $encoded = ConvertTo-EncodedPowerShellCommand -Text $handoff
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -WindowStyle Hidden -ArgumentList @(
            '-NoLogo', '-NoProfile', '-STA', '-EncodedCommand', $encoded
        ) -ErrorAction Stop
        $script:Window.Close()
    }
    catch {
        Show-ScriptBoxDialog -Title 'Administrator restart cancelled' -Message $_.Exception.Message -Buttons OK -Kind Info | Out-Null
    }
}

function New-Card {
    param([Parameter(Mandatory)]$Item, [switch]$HideSelection)

    $border = New-Object Windows.Controls.Border
    $border.Width = 304
    $border.Height = 202
    $border.Margin = '0,0,14,14'
    $border.Padding = '18'
    $border.CornerRadius = '14'
    $border.Background = $script:Window.Resources['CardBackground']
    $border.BorderBrush = $script:Window.Resources['ThemeBorder']
    $border.BorderThickness = '1'

    $grid = New-Object Windows.Controls.Grid
    $grid.RowDefinitions.Add((New-Object Windows.Controls.RowDefinition -Property @{ Height = 'Auto' }))
    $grid.RowDefinitions.Add((New-Object Windows.Controls.RowDefinition -Property @{ Height = 'Auto' }))
    $grid.RowDefinitions.Add((New-Object Windows.Controls.RowDefinition -Property @{ Height = '*' }))
    $grid.RowDefinitions.Add((New-Object Windows.Controls.RowDefinition -Property @{ Height = 'Auto' }))

    $category = New-Object Windows.Controls.TextBlock
    $category.Text = $Item.Category.ToUpperInvariant()
    $category.FontSize = 9
    $category.FontWeight = 'Bold'
    $category.Foreground = $Item.Accent
    [Windows.Controls.Grid]::SetRow($category, 0)

    $name = New-Object Windows.Controls.TextBlock
    $name.Text = $Item.Name
    $name.FontSize = 16
    $name.FontWeight = 'Bold'
    $name.Foreground = $script:Window.Resources['PrimaryText']
    $name.Margin = '0,7,0,0'
    [Windows.Controls.Grid]::SetRow($name, 1)

    $description = New-Object Windows.Controls.TextBlock
    $description.Text = $Item.Description
    $description.FontSize = 11
    $description.Foreground = $script:Window.Resources['SecondaryText']
    $description.TextWrapping = 'Wrap'
    $description.Margin = '0,8,0,8'
    [Windows.Controls.Grid]::SetRow($description, 2)

    $footer = New-Object Windows.Controls.Grid
    $footer.ColumnDefinitions.Add((New-Object Windows.Controls.ColumnDefinition -Property @{ Width = '*' }))
    $footer.ColumnDefinitions.Add((New-Object Windows.Controls.ColumnDefinition -Property @{ Width = 'Auto' }))
    [Windows.Controls.Grid]::SetRow($footer, 3)

    $badges = New-Object Windows.Controls.StackPanel
    $badges.Orientation = 'Horizontal'
    $badges.VerticalAlignment = 'Center'
    $showScriptInfo = ${function:Show-ScriptInfo}
    $startCatalogItem = ${function:Start-CatalogItem}
    $selectBox = $null
    if (-not $HideSelection) {
        $selectBox = New-Object Windows.Controls.CheckBox
        $selectBox.Content = 'SELECT'
        $selectBox.FontSize = 9
        $selectBox.FontWeight = 'Bold'
        $selectBox.Foreground = $script:Window.Resources['SecondaryText']
        $selectBox.Margin = '0,0,10,0'
        $selectBox.VerticalAlignment = 'Center'
        $selectBox.IsChecked = $script:SelectedIds.Contains($Item.Id)
        $setCatalogItemSelected = ${function:Set-CatalogItemSelected}
        $selectBox.Add_Checked({
            & $setCatalogItemSelected -Id $Item.Id -Selected $true
        }.GetNewClosure())
        $selectBox.Add_Unchecked({
            & $setCatalogItemSelected -Id $Item.Id -Selected $false
        }.GetNewClosure())
        if ($Item.CanQueue) { $script:SelectionControls.Add($selectBox) }
    }
    $badgeParts = @()
    if ($Item.RequiresAdmin) { $badgeParts += 'ADMIN' }
    if ($Item.NeedsBypass) { $badgeParts += 'BYPASS' }
    if ($Item.InputSecret) { $badgeParts += 'SECRET INPUT' } elseif ($Item.InputVariable) { $badgeParts += 'INPUT' }
    if (-not $Item.CanQueue) { $badgeParts += 'RUN ALONE' }
    if (-not $badgeParts) { $badgeParts += 'STANDARD' }
    $badge = New-Object Windows.Controls.TextBlock
    $badge.Text = ($badgeParts -join "  $([char]0x2022)  ")
    $badge.FontSize = 9
    $badge.FontWeight = 'Bold'
    $badge.Foreground = if ($Item.RequiresAdmin) { '#F59E0B' } else { '#22C55E' }
    if ($Item.CanQueue -and -not $HideSelection) { $badges.Children.Add($selectBox) | Out-Null }
    $badges.Children.Add($badge) | Out-Null
    [Windows.Controls.Grid]::SetColumn($badges, 0)

    $actions = New-Object Windows.Controls.StackPanel
    $actions.Orientation = 'Horizontal'
    [Windows.Controls.Grid]::SetColumn($actions, 1)

    $infoButton = New-Object Windows.Controls.Button
    $infoButton.Content = 'i'
    $infoButton.Width = 32
    $infoButton.Height = 29
    $infoButton.Padding = '0'
    $infoButton.ToolTip = 'What does this script do?'
    $infoButton.Margin = '0,0,7,0'
    $infoButton.Add_Click({ & $showScriptInfo -Item $Item }.GetNewClosure())

    $runButton = New-Object Windows.Controls.Button
    $runButton.Content = 'RUN'
    $runButton.Height = 29
    $runButton.Padding = '14,4'
    $runButton.Background = $script:Window.Resources['AccentGradient']
    $runButton.BorderBrush = '#6366F1'
    $runButton.Foreground = '#FFFFFF'
    $runButton.ToolTip = 'Run this script'
    $runButton.Add_Click({ & $startCatalogItem -Item $Item }.GetNewClosure())
    $script:RunButtons.Add($runButton)

    $actions.Children.Add($infoButton) | Out-Null
    $actions.Children.Add($runButton) | Out-Null
    $footer.Children.Add($badges) | Out-Null
    $footer.Children.Add($actions) | Out-Null

    $grid.Children.Add($category) | Out-Null
    $grid.Children.Add($name) | Out-Null
    $grid.Children.Add($description) | Out-Null
    $grid.Children.Add($footer) | Out-Null
    $border.Child = $grid
    return $border
}

function Render-Cards {
    $script:CardsHost.Children.Clear()
    $script:RunButtons.Clear()
    $script:SelectionControls.Clear()
    $script:ApplicationSelectionControls.Clear()
    $query = $script:SearchBox.Text.Trim()
    $filtered = @($script:Catalog | Where-Object {
        # Diagnostics-category cards render in the Diagnostics section instead.
        $_.Category -ne 'Diagnostics' -and
        (($script:ActiveCategory -eq 'All scripts' -and $_.ShowInAllScripts) -or $_.Category -eq $script:ActiveCategory) -and
        ([string]::IsNullOrWhiteSpace($query) -or
         $_.Name.IndexOf($query, [StringComparison]::OrdinalIgnoreCase) -ge 0 -or
         $_.Description.IndexOf($query, [StringComparison]::OrdinalIgnoreCase) -ge 0 -or
         $_.Category.IndexOf($query, [StringComparison]::OrdinalIgnoreCase) -ge 0)
    })

    foreach ($item in $filtered) { $script:CardsHost.Children.Add((New-Card -Item $item)) | Out-Null }
    $script:ResultsLabel.Text = "{0} script{1} in {2}" -f $filtered.Count, $(if ($filtered.Count -eq 1) { '' } else { 's' }), $script:ActiveCategory.ToLowerInvariant()
    Update-SelectionControls
    if ($script:RunState -or $script:IsQueueRunning) { Set-RunButtonsEnabled -Enabled $false }
}

function Clear-SelectedItems {
    if ($script:RunState -or $script:IsQueueRunning -or $script:SelectedIds.Count -eq 0) { return }
    $script:SelectedIds.Clear()
    Render-Cards
    Add-TerminalLine 'Selection cleared.'
}

function Start-SelectedItems {
    if ($script:RunState -or $script:IsQueueRunning) {
        Add-TerminalLine 'Wait for the current task or queue to finish.'
        return
    }

    $items = @($script:Catalog | Where-Object { $script:SelectedIds.Contains($_.Id) } | Sort-Object RunOrder)
    if ($items.Count -lt 2) {
        Show-ScriptBoxDialog -Title 'Select more scripts' -Message 'Select two or more script cards, then choose RUN SELECTED.' -Buttons OK -Kind Info | Out-Null
        return
    }

    $conflicts = @($items | Where-Object ConflictGroup | Group-Object ConflictGroup | Where-Object Count -gt 1)
    if ($conflicts.Count -gt 0) {
        $details = @($conflicts | ForEach-Object {
            "Choose only one of: " + (($_.Group | ForEach-Object Name) -join ', ')
        }) -join [Environment]::NewLine
        Show-ScriptBoxDialog -Title 'Selections conflict' -Message $details -Buttons OK -Kind Warning | Out-Null
        return
    }

    $names = @($items | ForEach-Object { "$([char]0x2022) " + $_.Name }) -join [Environment]::NewLine
    $message = "The selected scripts will run one at a time in this order:`n`n$names`n`nScripts that need administrator rights may show a UAC prompt."
    if (-not (Show-ScriptBoxDialog -Title "Run $($items.Count) selected scripts?" -Message $message -Buttons YesNo -Kind Warning)) {
        Add-TerminalLine 'Selected script queue cancelled.'
        return
    }

    $script:RunQueue.Clear()
    $script:QueueResults.Clear()
    foreach ($item in $items) { $script:RunQueue.Enqueue($item) }
    $script:QueueTitle = 'Selected scripts'
    $script:QueueNoun = 'scripts'
    $script:IsQueueRunning = $true
    $script:SelectedIds.Clear()
    Render-Cards
    Set-RunButtonsEnabled -Enabled $false
    Add-TerminalLine "Queued $($items.Count) scripts for sequential execution."
    Start-NextQueuedItem
}

# One-click preparation preset for a freshly installed computer. The ids must
# match existing catalog entries; the order below is the exact run order.
$script:NewInstallPresetIds = @(
    'always-on-power'
    'keep-network-active'
    'hide-shutdown-options'
    'idle-lock-10-minutes'
    'allow-password-signin'
    'enable-location-services'
    'disable-ipv6'
    'disable-machine-audio'
    'enable-rdp-current-user'
    'windows-update-security'
    'install-ninite-apps'
    'deploy-laptop-lid-check'
)

function Start-NewInstallPreset {
    if ($script:RunState -or $script:IsQueueRunning) {
        Show-ScriptBoxDialog -Title 'New Install' `
            -Message 'Another task is still running. Wait for the current task or queue to finish, then choose NEW INSTALL again.' `
            -Buttons OK -Kind Info | Out-Null
        return
    }

    if (-not $script:IsAdministrator) {
        $elevate = Show-ScriptBoxDialog -Title 'Administrator recommended' `
            -Message 'New Install runs mostly administrator tasks, so a standard session shows a separate elevation prompt for each one. Restart ScriptBox as administrator now so elevation is approved once instead?' `
            -Buttons YesNo -Kind Info
        if ($elevate) {
            Restart-ScriptBoxAsAdministrator
            return
        }
    }

    $items = New-Object System.Collections.Generic.List[object]
    foreach ($presetId in $script:NewInstallPresetIds) {
        $presetItem = @($script:Catalog | Where-Object Id -eq $presetId)
        if ($presetItem.Count -ne 1) {
            Show-ScriptBoxDialog -Title 'New Install' `
                -Message "The New Install preset refers to a missing catalog item: $presetId." `
                -Buttons OK -Kind Warning | Out-Null
            return
        }
        $items.Add($presetItem[0])
    }

    $names = @($items | ForEach-Object { "$([char]0x2022) " + $_.Name }) -join [Environment]::NewLine
    $message = "New Install prepares this computer by running these tasks one after another:`n`n$names`n`nThis changes system settings on this computer. Tasks that need administrator rights may show a UAC prompt."
    if (-not (Show-ScriptBoxDialog -Title 'New Install' -Message $message -Buttons YesNo -Kind Warning)) {
        Add-TerminalLine 'New Install preset cancelled.'
        return
    }

    $script:RunQueue.Clear()
    $script:QueueResults.Clear()
    foreach ($item in $items) { $script:RunQueue.Enqueue($item) }
    $script:QueueTitle = 'New Install'
    $script:QueueNoun = 'New Install tasks'
    $script:IsQueueRunning = $true
    Set-RunButtonsEnabled -Enabled $false
    Add-TerminalLine "Queued $($items.Count) New Install tasks for sequential execution."
    Start-NextQueuedItem
}

function Start-NextQueuedItem {
    if (-not $script:IsQueueRunning -or $script:RunState) { return }

    if ($script:RunQueue.Count -gt 0) {
        $next = $script:RunQueue.Dequeue()
        Add-TerminalLine ("Queue: starting {0} ({1} remaining after this)." -f $next.Name, $script:RunQueue.Count)
        Start-CatalogItem -Item $next -FromQueue
        return
    }

    $script:IsQueueRunning = $false
    $script:TerminalStatus.Text = '  READY'
    $script:TerminalStatus.Foreground = '#22C55E'
    if ($script:QueueTitle -eq 'Selected applications') {
        $script:ApplicationStatusCache = @{}
        if ($script:ActiveSection -eq 'Applications') { Render-Applications }
    }
    Set-RunButtonsEnabled -Enabled $true
    Update-SelectionControls

    $results = @($script:QueueResults)
    if ($results.Count -eq 0) {
        Add-TerminalLine 'The queue finished without running a task.'
        return
    }

    $good = ($results | Measure-Object GoodCount -Sum).Sum
    $warning = ($results | Measure-Object WarningCount -Sum).Sum
    $problem = ($results | Measure-Object ProblemCount -Sum).Sum
    if ($null -eq $good) { $good = 0 }
    if ($null -eq $warning) { $warning = 0 }
    if ($null -eq $problem) { $problem = 0 }
    $failed = @($results | Where-Object ExitCode -ne 0).Count
    $state = if ($failed -gt 0) { 'Error' } elseif ($warning -gt 0 -or $problem -gt 0) { 'Warning' } else { 'Success' }
    $headline = if ($failed -gt 0) { "$failed of $($results.Count) tasks need attention" } elseif ($warning -gt 0 -or $problem -gt 0) { 'Queue completed with items to review' } else { 'All selected tasks completed successfully' }
    $summary = "ScriptBox completed $($results.Count) selected $($script:QueueNoun) sequentially. Each line below explains the final state."
    $output = @($results | ForEach-Object {
        $label = if ($_.ExitCode -ne 0) { '[ERROR]' } elseif ($_.WarningCount -gt 0 -or $_.ProblemCount -gt 0) { '[WARNING]' } else { '[SUCCESS]' }
        "$label $($_.Item.Name) - $($_.Summary)"
    }) -join [Environment]::NewLine
    Add-TerminalLine "$($script:QueueTitle) queue finished: $($results.Count) task(s), $failed failure(s)."
    Show-ScriptBoxResult -Title $script:QueueTitle -Headline $headline -Summary $summary -Output $output `
        -GoodCount $good -WarningCount $warning -ProblemCount $problem -State $state
    $script:QueueResults.Clear()
}

function Select-Category {
    param([string]$Category)
    $script:ActiveCategory = $Category
    foreach ($button in $script:CategoryHost.Children) {
        $selected = $button.Tag -eq $Category
        $button.Background = if ($selected) { '#266366F1' } else { $script:Window.Resources['ControlBackground'] }
        $button.BorderBrush = if ($selected) { '#806366F1' } else { $script:Window.Resources['ThemeBorder'] }
        $button.Foreground = if ($selected) { '#818CF8' } else { $script:Window.Resources['SecondaryText'] }
    }
    Render-Cards
}

function Render-ActiveSection {
    switch ($script:ActiveSection) {
        'Applications'  { Render-Applications }
        'Network Tools' { Render-NetworkTools }
        'Diagnostics'   { Render-Diagnostics }
        'System Info'   { Render-SystemInfo }
        default         { Render-Cards }
    }
}

function Select-Section {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Applications', 'Scripts', 'Network Tools', 'Diagnostics', 'System Info')]
        [string]$Section
    )

    $script:ActiveSection = $Section
    foreach ($entry in $script:SectionButtons.GetEnumerator()) {
        $selected = $entry.Key -eq $Section
        $entry.Value.Background = if ($selected) { '#266366F1' } else { 'Transparent' }
        $entry.Value.BorderBrush = if ($selected) { '#806366F1' } else { 'Transparent' }
        $entry.Value.Foreground = if ($selected) { '#818CF8' } else { $script:Window.Resources['SecondaryText'] }
    }

    $isScripts = $Section -eq 'Scripts'
    $hasBatchControls = $Section -in @('Applications', 'Scripts')
    $canSearch = $Section -in @('Applications', 'Scripts')
    $script:ScriptTabsPanel.Visibility = if ($isScripts) { 'Visible' } else { 'Collapsed' }
    $script:NewInstallButton.Visibility = if ($isScripts) { 'Visible' } else { 'Collapsed' }
    $script:RunSelectedButton.Visibility = if ($hasBatchControls) { 'Visible' } else { 'Collapsed' }
    $script:ClearSelectionButton.Visibility = if ($hasBatchControls) { 'Visible' } else { 'Collapsed' }
    $script:SearchPanel.Visibility = if ($canSearch) { 'Visible' } else { 'Collapsed' }
    $script:PageTitle.Text = switch ($Section) {
        'Applications'  { 'Application Installer' }
        'Network Tools' { 'Network Tools' }
        'Diagnostics'   { 'Network Diagnostics' }
        'System Info'   { 'System' }
        default         { 'Scripts' }
    }

    switch ($Section) {
        'Applications'  { $script:ResultsLabel.Text = 'Install, download, or run applications on demand.' }
        'Scripts'       { $script:ResultsLabel.Text = 'Safe, visible execution with live output.' }
        'Network Tools' { $script:ResultsLabel.Text = 'Built-in Windows network tools.' }
        'Diagnostics'   { $script:ResultsLabel.Text = 'Read-only network health checks.' }
        'System Info'   { $script:ResultsLabel.Text = 'Read-only machine details.' }
    }

    Render-ActiveSection
}

$sections = @('Applications', 'Scripts', 'Network Tools', 'Diagnostics', 'System Info')
$sectionIcons = @{ Applications=[string][char]0x25A3; Scripts=[string][char]0x2318; 'Network Tools'=[string][char]0x25D4; Diagnostics=[string][char]0x25CE; 'System Info'=[string][char]0x2699 }
$sectionShortcuts = @{ Applications='Ctrl+1'; Scripts='Ctrl+2'; 'Network Tools'='Ctrl+3'; Diagnostics='Ctrl+4'; 'System Info'='Ctrl+5' }
foreach ($sectionName in $sections) {
    $sectionButton = New-Object Windows.Controls.Button
    $sectionButton.Tag = $sectionName
    $sectionButton.Height = 50
    $sectionButton.HorizontalContentAlignment = 'Left'
    $sectionButton.Margin = '0,0,0,8'
    $sectionButton.Padding = '12,8'
    $sectionButton.Background = 'Transparent'
    $sectionButton.BorderBrush = 'Transparent'
    $sectionButton.Foreground = $script:Window.Resources['SecondaryText']

    $navContent = New-Object Windows.Controls.Grid
    $navContent.Width = 172
    $navContent.ColumnDefinitions.Add((New-Object Windows.Controls.ColumnDefinition -Property @{ Width = 26 }))
    $navContent.ColumnDefinitions.Add((New-Object Windows.Controls.ColumnDefinition -Property @{ Width = '*' }))
    $navContent.ColumnDefinitions.Add((New-Object Windows.Controls.ColumnDefinition -Property @{ Width = 'Auto' }))
    $navIcon = New-Object Windows.Controls.TextBlock
    $navIcon.Text = $sectionIcons[$sectionName]
    $navIcon.FontSize = 15
    $navIcon.VerticalAlignment = 'Center'
    $navLabel = New-Object Windows.Controls.TextBlock
    $navLabel.Text = $sectionName
    $navLabel.FontSize = 12
    $navLabel.VerticalAlignment = 'Center'
    [Windows.Controls.Grid]::SetColumn($navLabel, 1)
    $navShortcut = New-Object Windows.Controls.TextBlock
    $navShortcut.Text = $sectionShortcuts[$sectionName]
    $navShortcut.FontSize = 8
    $navShortcut.Foreground = $script:Window.Resources['MutedText']
    $navShortcut.VerticalAlignment = 'Center'
    [Windows.Controls.Grid]::SetColumn($navShortcut, 2)
    $navContent.Children.Add($navIcon) | Out-Null
    $navContent.Children.Add($navLabel) | Out-Null
    $navContent.Children.Add($navShortcut) | Out-Null
    $sectionButton.Content = $navContent
    $sectionButton.Add_Click({
        param($sender, $eventArgs)
        Select-Section -Section ([string]$sender.Tag)
    })
    $script:SectionButtons[$sectionName] = $sectionButton
    $script:SectionHost.Children.Add($sectionButton) | Out-Null
}

# Diagnostics-category cards live in the Diagnostics section, so the Scripts
# section shows neither a Diagnostics pill nor those cards under All scripts.
$categories = @('All scripts') + @($script:Catalog.Category | Sort-Object -Unique | Where-Object { $_ -ne 'Diagnostics' })
foreach ($categoryName in $categories) {
    $button = New-Object Windows.Controls.Button
    $count = if ($categoryName -eq 'All scripts') { @($script:Catalog | Where-Object { $_.ShowInAllScripts -and $_.Category -ne 'Diagnostics' }).Count } else { @($script:Catalog | Where-Object Category -eq $categoryName).Count }
    $button.Content = "$categoryName   $count"
    $button.Tag = $categoryName
    $button.HorizontalContentAlignment = 'Center'
    $button.Margin = '0,0,8,0'
    $button.Padding = '12,8'
    $button.Add_Click({
        param($sender, $eventArgs)
        Select-Category -Category ([string]$sender.Tag)
    })
    $script:CategoryHost.Children.Add($button) | Out-Null
}

$script:SearchBox.Add_TextChanged({
    $script:SearchHint.Visibility = if ([string]::IsNullOrWhiteSpace($script:SearchBox.Text)) { 'Visible' } else { 'Collapsed' }
    Render-ActiveSection
})
$script:RunSelectedButton.Add_Click({
    if ($script:ActiveSection -eq 'Applications') { Start-SelectedApplications } else { Start-SelectedItems }
})
$script:NewInstallButton.Add_Click({ Start-NewInstallPreset })
$script:ClearSelectionButton.Add_Click({
    if ($script:ActiveSection -eq 'Applications') { Clear-SelectedApplications } else { Clear-SelectedItems }
})
$script:ThemeToggleButton.Add_Click({
    Set-ScriptBoxTheme -Theme $(if ($script:IsDarkTheme) { 'Light' } else { 'Dark' })
    Select-Section -Section $script:ActiveSection
})
$script:ExpandTerminalButton.Add_Click({
    Set-TerminalMode -Mode $(if ($script:TerminalMode -eq 'Expanded') { 'Normal' } else { 'Expanded' })
})
$script:CollapseTerminalButton.Add_Click({
    Set-TerminalMode -Mode $(if ($script:TerminalMode -eq 'Collapsed') { 'Normal' } else { 'Collapsed' })
})
$script:ElevateButton.Add_Click({ Restart-ScriptBoxAsAdministrator })
$script:ControlPanelButton.Add_Click({
    try { Start-Process -FilePath 'control.exe' -ErrorAction Stop }
    catch { Add-TerminalLine "Could not open Control Panel: $($_.Exception.Message)" }
})
$script:SettingsButton.Add_Click({
    try { Start-Process -FilePath 'ms-settings:' -ErrorAction Stop }
    catch { Add-TerminalLine "Could not open Settings: $($_.Exception.Message)" }
})
$script:TaskManagerButton.Add_Click({
    try { Start-Process -FilePath 'taskmgr.exe' -ErrorAction Stop }
    catch { Add-TerminalLine "Task Manager could not be opened: $($_.Exception.Message)" }
})
$script:OpenTerminalButton.Add_Click({
    try { Start-Process -FilePath 'wt.exe' -ErrorAction Stop }
    catch {
        try { Start-Process -FilePath 'powershell.exe' -ErrorAction Stop }
        catch { Add-TerminalLine "Could not open a terminal: $($_.Exception.Message)" }
    }
})
$script:ClearTerminalButton.Add_Click({
    $script:TerminalOutput.Clear()
    Add-TerminalLine 'Terminal cleared. ScriptBox is ready.'
})
$script:CopyTerminalButton.Add_Click({
    try {
        [Windows.Clipboard]::SetText($script:TerminalOutput.Text)
        Add-TerminalLine 'Terminal output copied to the clipboard.'
    }
    catch { Add-TerminalLine "Terminal output could not be copied: $($_.Exception.Message)" }
})

$script:Window.Add_PreviewKeyDown({
    param($sender, $eventArgs)
    $control = ([Windows.Input.Keyboard]::Modifiers -band [Windows.Input.ModifierKeys]::Control) -ne 0
    if ($control) {
        switch ($eventArgs.Key) {
            'K' {
                if ($script:ActiveSection -notin @('Applications', 'Scripts')) { Select-Section -Section 'Scripts' }
                $script:SearchBox.Focus() | Out-Null
                $script:SearchBox.SelectAll()
                $eventArgs.Handled = $true
            }
            'D1' { Select-Section -Section 'Applications'; $eventArgs.Handled = $true }
            'D2' { Select-Section -Section 'Scripts'; $eventArgs.Handled = $true }
            'D3' { Select-Section -Section 'Network Tools'; $eventArgs.Handled = $true }
            'D4' { Select-Section -Section 'Diagnostics'; $eventArgs.Handled = $true }
            'D5' { Select-Section -Section 'System Info'; $eventArgs.Handled = $true }
            'T' {
                Set-TerminalMode -Mode $(if ($script:TerminalMode -eq 'Expanded') { 'Normal' } else { 'Expanded' })
                $eventArgs.Handled = $true
            }
            'Oem3' {
                Set-TerminalMode -Mode $(if ($script:TerminalMode -eq 'Collapsed') { 'Normal' } else { 'Collapsed' })
                $eventArgs.Handled = $true
            }
        }
    }
    elseif ($eventArgs.Key -eq [Windows.Input.Key]::Escape -and -not [string]::IsNullOrWhiteSpace($script:SearchBox.Text)) {
        $script:SearchBox.Clear()
        $eventArgs.Handled = $true
    }
})

$script:OutputTimer = New-Object Windows.Threading.DispatcherTimer
$script:OutputTimer.Interval = [TimeSpan]::FromMilliseconds(250)
$script:OutputTimer.Add_Tick({
    if (-not $script:RunState) { return }
    try {
        if (Test-Path -LiteralPath $script:RunState.LogPath) {
            $content = Read-SharedTextFile -Path $script:RunState.LogPath
            if ($content.Length -gt $script:RunState.ReadLength) {
                $newText = $content.Substring($script:RunState.ReadLength)
                $script:TerminalOutput.AppendText($newText)
                $script:TerminalOutput.ScrollToEnd()
                $script:RunState.ReadLength = $content.Length
            }
        }

        if (-not (Test-Path -LiteralPath $script:RunState.DonePath) -and $script:RunState.Process.HasExited) {
            # Some third-party launchers call exit from inside their downloaded
            # script, which bypasses the runner's finally block. Recover from
            # that cleanly instead of leaving ScriptBox stuck in RUNNING.
            [IO.File]::WriteAllText($script:RunState.DonePath, [string]$script:RunState.Process.ExitCode, (New-Object Text.UTF8Encoding($false)))
        }

        if (Test-Path -LiteralPath $script:RunState.DonePath) {
            $exitCode = [IO.File]::ReadAllText($script:RunState.DonePath).Trim()
            $finishedState = $script:RunState
            $finishedName = $finishedState.Item.Name
            $fullOutput = if (Test-Path -LiteralPath $finishedState.LogPath) {
                Read-SharedTextFile -Path $finishedState.LogPath
            } else { '' }
            $result = New-FriendlyResult -Item $finishedState.Item -ExitCode ([int]$exitCode) -Output $fullOutput
            Remove-Item -LiteralPath $finishedState.LogPath, $finishedState.DonePath -Force -ErrorAction SilentlyContinue
            $script:RunState = $null
            if ($exitCode -eq '0') {
                $script:TerminalStatus.Text = '  READY'
                $script:TerminalStatus.Foreground = '#22C55E'
                Add-TerminalLine "$finishedName finished."
            } else {
                $script:TerminalStatus.Text = '  ATTENTION'
                $script:TerminalStatus.Foreground = '#EF4444'
                Add-TerminalLine "$finishedName finished with an error. Review the output above."
            }

            if ($finishedState.FromQueue) {
                $script:QueueResults.Add($result) | Out-Null
                Start-NextQueuedItem
            } else {
                if ($finishedState.Item.Category -eq 'Applications') {
                    $script:ApplicationStatusCache = @{}
                    if ($script:ActiveSection -eq 'Applications') { Render-Applications }
                }
                Set-RunButtonsEnabled -Enabled $true
                Update-SelectionControls
                if ($finishedState.Item.ResultMode -eq 'Summary') {
                    Show-ScriptBoxResult -Title $finishedName -Headline $result.Headline -Summary $result.Summary `
                        -Output $result.Output -GoodCount $result.GoodCount -WarningCount $result.WarningCount `
                        -ProblemCount $result.ProblemCount -State $result.State
                }
            }
        }
    }
    catch {
        Add-TerminalLine ("Output monitor warning: {0}" -f $_.Exception.Message)
    }
})

function Set-ScriptBoxWindowIconFromFile {
    param([Parameter(Mandatory)][string]$Path)
    try {
        $iconBytes = [IO.File]::ReadAllBytes($Path)
        $iconStream = New-Object IO.MemoryStream(,$iconBytes)
        $bitmap = New-Object Windows.Media.Imaging.BitmapImage
        $bitmap.BeginInit()
        $bitmap.CacheOption = [Windows.Media.Imaging.BitmapCacheOption]::OnLoad
        $bitmap.StreamSource = $iconStream
        $bitmap.EndInit()
        $bitmap.Freeze()
        $iconStream.Dispose()
        $script:Window.Icon = $bitmap
        $script:AppIcon.Source = $bitmap
    } catch { }
}

if ($PSScriptRoot -and (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'assets\icon.png'))) {
    Set-ScriptBoxWindowIconFromFile -Path (Join-Path $PSScriptRoot 'assets\icon.png')
} else {
    # Download the icon in a background runspace so an irm | iex launch never
    # blocks startup on the network; the window shows no icon until it lands.
    $downloadedIcon = Join-Path $script:TempRoot 'icon.png'
    $iconScript = "param(`$uri, `$destination)`n" +
        "try {`n" +
        "Invoke-WebRequest -UseBasicParsing -Uri `$uri -OutFile `$destination -TimeoutSec 10`n" +
        "`$destination`n" +
        "}`ncatch { `$null }"
    $iconShell = [powershell]::Create()
    [void]$iconShell.AddScript($iconScript).AddArgument($script:IconSource).AddArgument($downloadedIcon)
    $iconTimer = New-Object Windows.Threading.DispatcherTimer
    $iconTimer.Interval = [TimeSpan]::FromMilliseconds(250)
    $script:IconGather = @{
        PowerShell = $iconShell
        Handle     = $iconShell.BeginInvoke()
        Timer      = $iconTimer
    }
    $iconTimer.Add_Tick({
        $gather = $script:IconGather
        if (-not $gather) { return }
        if (-not $gather.Handle.IsCompleted) { return }
        $gather.Timer.Stop()
        $script:IconGather = $null
        $iconPath = $null
        try {
            $results = $gather.PowerShell.EndInvoke($gather.Handle)
            $iconPath = @($results | Where-Object { $_ -is [string] -and $_ }) | Select-Object -Last 1
        }
        catch { $iconPath = $null }
        finally { $gather.PowerShell.Dispose() }
        if ($iconPath -and (Test-Path -LiteralPath $iconPath)) {
            Set-ScriptBoxWindowIconFromFile -Path $iconPath
        }
    })
    $iconTimer.Start()
}

$script:PrivilegeLabel.Text = if ($script:IsAdministrator) { "$([char]0x25CF) RUNNING AS ADMIN" } else { "$([char]0x25CF) STANDARD SESSION" }
$script:PrivilegeLabel.Foreground = if ($script:IsAdministrator) { '#22C55E' } else { '#F59E0B' }
$script:VersionLabel.Text = "PORTABLE  $([char]0x2022)  v$($script:Version)"
$script:ElevateButton.Visibility = if ($script:IsAdministrator) { 'Collapsed' } else { 'Visible' }
$script:Window.Title = "ScriptBox $($script:Version)"

$script:Window.Add_Closing({
    param($sender, $eventArgs)
    if ($script:RunState -or $script:IsQueueRunning) {
        $eventArgs.Cancel = $true
        Show-ScriptBoxDialog -Title 'Scripts still running' `
            -Message 'Wait for the current task and selected queue to finish before closing so ScriptBox can remove its temporary output safely.' `
            -Buttons OK -Kind Info | Out-Null
        return
    }
    $script:OutputTimer.Stop()
    Remove-ScriptBoxTempRoot
})

Set-ScriptBoxTheme -Theme 'Dark'
Select-Category -Category 'All scripts'
Select-Section -Section 'Scripts'
Add-TerminalLine "ScriptBox $($script:Version) ready. Use the left sections, or press Ctrl+1 through Ctrl+5 to move between them."
Add-TerminalLine 'Applications offers explicit portable downloads, installers, and run actions; ScriptBox itself is not installed.'
Add-TerminalLine 'In Scripts, select i for details, RUN for one task, or select several cards and RUN SELECTED.'
Add-TerminalLine 'Catalog scripts are downloaded on demand only when their run begins.'
Add-TerminalLine 'Temporary runtime data will be removed when this window closes.'
$script:OutputTimer.Start()

if ($env:SCRIPTBOX_TEST_MODE -eq '1') {
    if ($script:Catalog.Count -ne 27 -or @($script:Catalog | Where-Object InlineScript).Count -ne 0) {
        throw 'Lazy catalog validation failed.'
    }
    if ($script:SectionButtons.Count -ne 5 -or
        @($script:SectionButtons.Keys | Sort-Object) -join '|' -ne 'Applications|Diagnostics|Network Tools|Scripts|System Info') {
        throw 'Primary section navigation validation failed.'
    }
    Select-Section -Section 'Applications'
    if ($script:ActiveSection -ne 'Applications' -or
        $script:CardsHost.Children.Count -ne $script:ApplicationLinks.Count -or
        $script:ScriptTabsPanel.Visibility -ne 'Collapsed' -or
        $script:RunSelectedButton.Visibility -ne 'Visible' -or
        $script:NewInstallButton.Visibility -ne 'Collapsed' -or
        $script:SearchPanel.Visibility -ne 'Visible' -or
        $script:ApplicationSelectionControls.Count -ne $script:ApplicationLinks.Count -or
        $script:RunButtons.Count -ne 15) {
        throw 'Application Installer section validation failed.'
    }
    foreach ($application in $script:ApplicationLinks) {
        foreach ($action in $application.Actions) {
            $actionTokens = $null
            $actionErrors = $null
            $actionScript = New-ApplicationActionScript -Application $application -Action $action
            [void][Management.Automation.Language.Parser]::ParseInput($actionScript, [ref]$actionTokens, [ref]$actionErrors)
            if ($actionErrors.Count -gt 0) {
                throw "Application action payload does not parse: $($application.Name) / $($action.Text): $($actionErrors.Message -join '; ')"
            }
        }
    }
    $script:ApplicationSelectionControls[0].IsChecked = $true
    if ($script:SelectedApplicationIds.Count -ne 1 -or
        $script:RunSelectedButton.Content -ne 'INSTALL SELECTED (1)' -or
        -not $script:RunSelectedButton.IsHitTestVisible) {
        throw 'Application batch-selection validation failed.'
    }
    Clear-SelectedApplications
    Select-Section -Section 'Network Tools'
    if ($script:ActiveSection -ne 'Network Tools' -or
        $script:CardsHost.Children.Count -ne 4 -or
        $script:RunButtons.Count -ne 0 -or
        $script:ResultsLabel.Text -match '(?i)shortcut') {
        throw 'Network Tools section validation failed; expected exactly Ping, Traceroute, Latency Test, and Quick Network Actions cards with no Windows Shortcuts card.'
    }
    if ($null -eq $script:TaskManagerButton -or [string]$script:TaskManagerButton.Content -notmatch 'Task Manager') {
        throw 'Task Manager sidebar shortcut validation failed.'
    }
    Select-Section -Section 'Diagnostics'
    if ($script:ActiveSection -ne 'Diagnostics' -or
        $script:CardsHost.Children.Count -ne 4 -or
        $script:RunButtons.Count -ne 3 -or
        $script:SelectionControls.Count -ne 0 -or
        $script:SearchPanel.Visibility -ne 'Collapsed' -or
        $script:RunSelectedButton.Visibility -ne 'Collapsed') {
        throw 'Diagnostics section validation failed; expected the built-in Network Diagnostics card plus the three Diagnostics-category catalog cards without selection checkboxes.'
    }
    Select-Section -Section 'System Info'
    if ($script:ActiveSection -ne 'System Info' -or
        $script:CardsHost.Children.Count -ne 6 -or
        $null -ne $script:SystemInfoGather -or
        -not $script:SystemInfoLoaded) {
        throw 'System Info synchronous test-mode gather validation failed; expected five snapshot cards plus the refresh card.'
    }
    Select-Section -Section 'Scripts'
    if ($script:ActiveSection -ne 'Scripts' -or
        $script:ScriptTabsPanel.Visibility -ne 'Visible' -or
        $script:RunSelectedButton.Visibility -ne 'Visible' -or
        $script:NewInstallButton.Visibility -ne 'Visible') {
        throw 'Scripts section and top-tab validation failed.'
    }
    # Validate only the lookup side of the New Install preset; the queue itself
    # is never started here because its tasks change real system state.
    if ($script:NewInstallPresetIds.Count -ne 12) {
        throw 'New Install preset must list exactly 12 catalog tasks.'
    }
    foreach ($presetId in $script:NewInstallPresetIds) {
        if (@($script:Catalog | Where-Object Id -eq $presetId).Count -ne 1) {
            throw "New Install preset id does not resolve to one catalog item: $presetId"
        }
    }
    Set-ScriptBoxTheme -Theme 'Light'
    if ($script:IsDarkTheme -or $script:ThemeToggleButton.Content -ne 'DARK') {
        throw 'Light theme validation failed.'
    }
    Set-ScriptBoxTheme -Theme 'Dark'
    Set-TerminalMode -Mode 'Collapsed'
    if ($script:TerminalMode -ne 'Collapsed' -or $script:TerminalOutput.Visibility -ne 'Collapsed') {
        throw 'Collapsed terminal validation failed.'
    }
    Set-TerminalMode -Mode 'Expanded'
    if ($script:TerminalMode -ne 'Expanded' -or $script:TerminalOutput.Visibility -ne 'Visible') {
        throw 'Expanded terminal validation failed.'
    }
    Set-TerminalMode -Mode 'Normal'
    $cautionItems = @($script:Catalog | Where-Object Category -eq 'Warning - Use With Caution')
    $eraseItem = @($script:Catalog | Where-Object Id -eq 'erase-reinstall-windows')
    if ($cautionItems.Count -ne 2 -or @($cautionItems | Where-Object ShowInAllScripts).Count -ne 0 -or
        @($cautionItems | Where-Object Id -eq 'shutdown-windows').Count -ne 1 -or
        $eraseItem.Count -ne 1 -or $eraseItem[0].CanQueue -or $eraseItem[0].InputVariable -ne 'EraseConfirmation' -or
        $eraseItem[0].RequiredInputValue -cne 'ERASE ALL INTERNAL DATA') {
        throw 'Warning category and destructive-action safeguards validation failed.'
    }
    $allScriptsButton = @($script:CategoryHost.Children | Where-Object Tag -eq 'All scripts')[0]
    if ($script:CardsHost.Children.Count -ne 22 -or $allScriptsButton.Content -ne 'All scripts   22' -or
        @($script:CategoryHost.Children | Where-Object Tag -eq 'Diagnostics').Count -ne 0) {
        throw 'All scripts must exclude warning-only actions and Diagnostics-section cards.'
    }
    $fixesItems = @($script:Catalog | Where-Object Category -eq 'Fixes')
    $fixesButton = @($script:CategoryHost.Children | Where-Object Tag -eq 'Fixes')[0]
    if ($fixesItems.Count -ne 1 -or $fixesItems[0].Id -ne 'repair-power-menu-system-tray' -or
        $fixesItems[0].Name -ne 'Repair System Tray and Audio' -or
        $fixesButton.Content -ne 'Fixes   1') {
        throw 'Fixes category validation failed.'
    }
    $usbItem = @($script:Catalog | Where-Object Id -eq 'show-connected-usb-devices')
    $wolItem = @($script:Catalog | Where-Object Id -eq 'watch-wol-packets')
    if ($usbItem.Count -ne 1 -or $usbItem[0].RequiresAdmin -or $usbItem[0].CanQueue -or
        $usbItem[0].ResultMode -ne 'None' -or
        $wolItem.Count -ne 1 -or -not $wolItem[0].RequiresAdmin -or $wolItem[0].CanQueue -or
        $wolItem[0].ResultMode -ne 'None') {
        throw 'Interactive USB and Wake-on-LAN catalog validation failed.'
    }
    $hpG3G5Item = @($script:Catalog | Where-Object Id -eq 'configure-hp-g3-g5-mini-wol-kvm')
    if ($hpG3G5Item.Count -ne 1 -or -not $hpG3G5Item[0].RequiresAdmin -or $hpG3G5Item[0].CanQueue -or
        $hpG3G5Item[0].ResultMode -ne 'None' -or $hpG3G5Item[0].InputVariable -ne 'BIOSPassword' -or
        $hpG3G5Item[0].ConflictGroup -ne 'bios-vendor' -or
        $hpG3G5Item[0].Impact -notmatch 'restricted to HP EliteDesk 800 G3 and G5 Desktop Mini systems') {
        throw 'HP G3/G5 Mini WOL/KVM catalog validation failed.'
    }
    foreach ($catalogItem in @($script:Catalog | Where-Object ScriptPath)) {
        $catalogPath = Join-Path $PSScriptRoot (Join-Path 'scripts' $catalogItem.ScriptPath)
        if (-not (Test-Path -LiteralPath $catalogPath)) {
            throw "Catalog source file is missing: $($catalogItem.ScriptPath)"
        }
    }
    $lazyPayload = Get-CatalogPayload -Item ($script:Catalog | Where-Object Id -eq 'always-on-power')
    if ($lazyPayload -notmatch 'Configure-AlwaysOnPower.ps1' -or $lazyPayload -match 'powercfg.exe') {
        throw 'On-demand payload validation failed.'
    }

    $toolsButton = @($script:CategoryHost.Children | Where-Object Tag -eq 'Tools')[0]
    $toolsButton.RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Button]::ClickEvent)))
    if ($script:ActiveCategory -ne 'Tools' -or $script:CardsHost.Children.Count -ne 3) {
        throw 'Category navigation validation failed.'
    }

    Show-ScriptBoxDialog -Title 'Dialog validation' -Message 'Validates the custom ScriptBox popup.' -Buttons OK -Kind Info | Out-Null
    $testInput = Show-ScriptBoxInputDialog -Title 'Input validation' -Message 'Validates the matching ScriptBox input popup.'
    if (-not $testInput.Confirmed -or $testInput.Value -ne 'scriptbox-test') {
        throw 'Input dialog validation failed.'
    }
    $testSecret = Show-ScriptBoxInputDialog -Title 'Secret validation' -Message 'Validates a masked optional input.' -Optional $true -Secret $true
    if (-not $testSecret.Confirmed -or $testSecret.Value -ne 'scriptbox-test') {
        throw 'Secret input dialog validation failed.'
    }
    Show-ScriptInfo -Item $script:Catalog[0]
    $friendlyTest = New-FriendlyResult -Item $script:Catalog[0] -ExitCode 0 -Output '[SUCCESS] Good`n[WARNING] Review'
    if ($friendlyTest.GoodCount -ne 1 -or $friendlyTest.WarningCount -ne 1 -or $friendlyTest.State -ne 'Warning') {
        throw 'Friendly result interpretation failed.'
    }
    Show-ScriptBoxResult -Title 'Result validation' -Headline $friendlyTest.Headline -Summary $friendlyTest.Summary `
        -Output $friendlyTest.Output -GoodCount 1 -WarningCount 1 -State Warning

    if ($script:RunSelectedButton.IsHitTestVisible -or $script:ClearSelectionButton.IsHitTestVisible -or
        $script:RunSelectedButton.Opacity -ge 1 -or $script:RunSelectedButton.Background.GradientStops[0].Color.ToString() -ne '#FF6366F1') {
        throw 'Themed inactive selection control validation failed.'
    }
    $script:SelectionControls[0].IsChecked = $true
    if ($script:SelectedIds.Count -ne 1 -or $script:RunSelectedButton.Content -notmatch '\(1\)' -or
        $script:RunSelectedButton.IsHitTestVisible -or -not $script:ClearSelectionButton.IsHitTestVisible) {
        throw 'Multi-select control validation failed.'
    }
    $script:SelectionControls[1].IsChecked = $true
    if ($script:SelectedIds.Count -ne 2 -or $script:RunSelectedButton.Content -notmatch '\(2\)' -or
        -not $script:RunSelectedButton.IsHitTestVisible -or $script:RunSelectedButton.Opacity -ne 1) {
        throw 'Multi-select count validation failed.'
    }
    if (@($script:Catalog | Where-Object ConflictGroup -eq 'windows-update-mode').Count -ne 2 -or
        @($script:Catalog | Where-Object ConflictGroup -eq 'bios-vendor').Count -ne 4 -or
        @($script:Catalog | Where-Object ConflictGroup -eq 'power-menu-visibility').Count -ne 2) {
        throw 'Conflict group validation failed.'
    }
    Clear-SelectedItems
    if ($script:SelectedIds.Count -ne 0 -or $script:RunSelectedButton.IsHitTestVisible -or
        $script:ClearSelectionButton.IsHitTestVisible -or $script:ClearSelectionButton.Background.Color.ToString() -ne '#FF1A1A28') {
        throw 'Themed cleared selection control validation failed.'
    }

    # Reproduce a workspace disappearing while the UI remains open. The runner
    # must recover instead of allowing a WPF click handler exception to escape.
    $removedTestRoot = $script:TempRoot
    Remove-Item -LiteralPath $removedTestRoot -Recurse -Force

    $testItem = New-CatalogItem -Id 'validation' -Name 'Runner validation' -Category 'Test' `
        -Description 'Validates the output bridge.' -InputTitle 'Runner input' `
        -InputMessage 'Enter a runner validation value.' -InputVariable 'ValidationValue' `
        -RequiresConfirmation $false -InlineScript { Write-Output "SCRIPTBOX_RUNNER_OK:$ValidationValue" }
    Start-CatalogItem -Item $testItem
    if (-not $script:RunState.Process.WaitForExit(10000)) {
        throw 'Runner validation timed out.'
    }
    if (-not (Test-Path -LiteralPath $script:RunState.DonePath)) {
        throw 'Runner validation did not create its completion marker.'
    }
    $testLog = [IO.File]::ReadAllText($script:RunState.LogPath, [Text.Encoding]::UTF8)
    $testExitCode = [IO.File]::ReadAllText($script:RunState.DonePath).Trim()
    if ($testExitCode -ne '0' -or $testLog -notmatch 'SCRIPTBOX_RUNNER_OK:scriptbox-test') {
        throw 'Runner validation did not capture the expected output.'
    }
    Remove-Item -LiteralPath $script:RunState.LogPath, $script:RunState.DonePath -Force -ErrorAction SilentlyContinue
    $script:RunState = $null

    $queueTestOne = New-CatalogItem -Id 'queue-one' -Name 'Queue one' -Category 'Test' `
        -Description 'Validates queue item one.' -RequiresConfirmation $false `
        -InlineScript { Write-Output '[SUCCESS] SCRIPTBOX_QUEUE_ONE' }
    $queueTestTwo = New-CatalogItem -Id 'queue-two' -Name 'Queue two' -Category 'Test' `
        -Description 'Validates queue item two.' -RequiresConfirmation $false `
        -InlineScript { Write-Output '[WARNING] SCRIPTBOX_QUEUE_TWO' }
    $script:RunQueue.Clear()
    $script:QueueResults.Clear()
    $script:RunQueue.Enqueue($queueTestOne)
    $script:RunQueue.Enqueue($queueTestTwo)
    $script:IsQueueRunning = $true
    Start-NextQueuedItem
    $queueDeadline = [DateTime]::UtcNow.AddSeconds(15)
    while ($script:IsQueueRunning -and [DateTime]::UtcNow -lt $queueDeadline) {
        $frame = New-Object Windows.Threading.DispatcherFrame
        [Windows.Threading.Dispatcher]::CurrentDispatcher.BeginInvoke(
            [Windows.Threading.DispatcherPriority]::Background,
            [Action]{ $frame.Continue = $false }
        ) | Out-Null
        [Windows.Threading.Dispatcher]::PushFrame($frame)
        Start-Sleep -Milliseconds 50
    }
    if ($script:IsQueueRunning -or $script:RunState -or
        $script:TerminalOutput.Text -notmatch 'SCRIPTBOX_QUEUE_ONE' -or
        $script:TerminalOutput.Text -notmatch 'SCRIPTBOX_QUEUE_TWO') {
        throw 'Sequential queue validation failed.'
    }

    Write-Output "ScriptBox validation passed: InvokeX-style application actions, five shell sections, $($script:Catalog.Count) lazy catalog items, top-tab navigation, themes, selection controls, sequential queue, and output bridge."
    $script:OutputTimer.Stop()
    Remove-ScriptBoxTempRoot
    return
}

try {
    $script:Window.ShowDialog() | Out-Null
}
finally {
    $script:OutputTimer.Stop()
    Remove-ScriptBoxTempRoot
}
