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
$script:Version = '3.0.0'
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
$script:InstalledApplicationNames = $null
$script:TerminalMode = 'Normal'
$script:SectionButtons = @{}
$script:RunState = $null
$script:RunButtons = New-Object System.Collections.Generic.List[object]
$script:SelectionControls = New-Object System.Collections.Generic.List[object]
$script:SelectedIds = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
$script:RunQueue = New-Object 'System.Collections.Generic.Queue[object]'
$script:QueueResults = New-Object System.Collections.Generic.List[object]
$script:IsQueueRunning = $false

# PowerShell 7 normally starts in MTA. WPF needs an STA thread, so hand off to
# Windows PowerShell without writing the launcher itself to disk.
if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
    $handoff = "& { Invoke-RestMethod -UseBasicParsing '$($script:SelfSource)' | Invoke-Expression }"
    $encodedHandoff = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($handoff))
    Start-Process -FilePath 'powershell.exe' -ArgumentList @(
        '-NoLogo', '-NoProfile', '-STA', '-EncodedCommand', $encodedHandoff
    ) -WindowStyle Hidden
    return
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
        [string]$Accent = '#22D3EE'
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
    New-CatalogItem -Id 'restart-windows' -Name 'Restart Windows' -Category 'Power' -Description 'Restarts this computer after a 10-second warning.' -ScriptPath 'Restart-Windows.ps1' -Impact 'Open work may be lost. Windows displays a 10-second countdown before restarting.' -ConflictGroup 'power-action' -RunOrder 900 -Accent '#F472B6' -SuccessMessage 'Windows accepted the restart request and started the 10-second countdown.'
    New-CatalogItem -Id 'shutdown-windows' -Name 'Shut Down Windows' -Category 'Warning - Use With Caution' -Description 'Shuts down this computer after a 30-second warning.' -ScriptPath 'Shutdown-Windows.ps1' -Impact 'Open work may be lost. Windows displays a 30-second countdown before shutting down.' -ConflictGroup 'power-action' -ShowInAllScripts $false -RunOrder 900 -Accent '#A855F7' -SuccessMessage 'Windows accepted the shutdown request and started the 30-second countdown.'
    New-CatalogItem -Id 'erase-reinstall-windows' -Name 'Unattended Erase and Reinstall' -Category 'Warning - Use With Caution' -Description 'Fully cleans the internal Windows disk and reinstalls Windows without further reset prompts.' -ScriptPath 'Reset-WindowsRemoveEverything.ps1' -ScriptArguments '-Confirmation $EraseConfirmation' -Impact 'PERMANENT DATA LOSS: after a 60-second cancellation window, Microsoft protected wipe removes every user profile, application, setting, and partition from the internal Windows disk, including a D: partition on that same disk. Microsoft warns that some device configurations may become unbootable if recovery fails. This cannot be undone.' -RequiresAdmin $true -InputTitle 'Type ERASE ALL INTERNAL DATA' -InputMessage 'This unattended action is irreversible. Back up anything required, connect AC power, and have the BitLocker recovery key available. Type ERASE ALL INTERNAL DATA exactly to schedule the protected wipe of C: and any D: partition on the same disk.' -InputVariable 'EraseConfirmation' -RequiredInputValue 'ERASE ALL INTERNAL DATA' -ConflictGroup 'power-action' -CanQueue $false -ShowInAllScripts $false -ResultMode 'Terminal' -RunOrder 999 -Accent '#EF4444' -SuccessMessage 'The unattended protected wipe was scheduled with a 60-second cancellation window.'
    New-CatalogItem -Id 'always-on-power' -Name 'Keep PC Awake' -Category 'Power' -Description 'Keeps the display, computer, and laptop active for reliable remote access.' -ScriptPath 'Configure-AlwaysOnPower.ps1' -Impact 'Changes the active power plan, disables sleep and hibernation, and makes lid-close and power-button actions do nothing.' -RequiresAdmin $true -Accent '#22D3EE' -SuccessMessage 'The active power plan now keeps the computer awake on AC and battery.'
    New-CatalogItem -Id 'keep-network-active' -Name 'Keep Network Active' -Category 'Power' -Description 'Reduces adapter and power-plan sleep behavior so networking remains available while locked.' -ScriptPath 'Keep-NetworkActive.ps1' -Impact 'Disables several network, PCIe, and USB power-saving features and writes a log under C:\Tools\Logs.' -RequiresAdmin $true -Accent '#2DD4BF' -SuccessMessage 'Supported network power-saving settings were disabled to improve locked-session connectivity.'
    New-CatalogItem -Id 'hide-shutdown-options' -Name 'Hide Shutdown Options' -Category 'Security' -Description 'Hides Shutdown, Restart, Sleep, and Hibernate for existing and future Windows users without changing notification-area policy.' -ScriptPath 'Hide-ShutdownOptions.ps1' -Impact 'Sets only the documented per-user NoClose policy, including offline and Default user registry hives. It does not alter Windows PolicyManager defaults or system-tray policy.' -RequiresAdmin $true -ConflictGroup 'power-menu-visibility' -Accent '#C084FC' -SuccessMessage 'Power commands are hidden for existing profiles and the Default user profile without changing notification-area policy.'
    New-CatalogItem -Id 'repair-power-menu-system-tray' -Name 'Repair System Tray and Audio' -Category 'Fixes' -Description 'Restores machine audio and reverses legacy ScriptBox policies that can disturb Windows 11 shell surfaces.' -ScriptPath 'Repair-PowerMenuAndSystemTray.ps1' -Impact 'Removes ScriptBox''s local fDisableCam policy, returns Windows Audio Endpoint Builder and Windows Audio to Automatic/Running, restores the four legacy PolicyManager Start defaults, and removes ScriptBox''s NoClose value from existing and future-user profiles. Sign out or restart afterward to reload the shell.' -RequiresAdmin $true -ConflictGroup 'power-menu-visibility' -Accent '#34D399' -SuccessMessage 'Machine audio and legacy ScriptBox shell policies were restored; sign out or restart Windows to reload the system tray.'
    New-CatalogItem -Id 'idle-lock-10-minutes' -Name 'Lock After 10 Minutes' -Category 'Security' -Description 'Locks signed-in Windows sessions after ten minutes without keyboard or mouse activity.' -ScriptPath 'Configure-IdleLock.ps1' -Impact 'Sets computer and user inactivity policies and refreshes Group Policy. A sign-out or restart may be needed.' -RequiresAdmin $true -Accent '#F472B6' -SuccessMessage 'Windows is configured to lock idle sessions after ten minutes.'
    New-CatalogItem -Id 'allow-password-signin' -Name 'Allow Password Sign-in' -Category 'Security' -Description 'Allows Microsoft-account users to choose password sign-in while keeping their existing PIN.' -ScriptPath 'Allow-PasswordSignIn.ps1' -Impact 'Sets the machine-wide DevicePasswordLessBuildVersion registry value to 0. Existing Windows Hello PINs are not removed.' -RequiresAdmin $true -Accent '#C084FC' -SuccessMessage 'Password sign-in is permitted and existing Windows Hello PINs remain available.'
    New-CatalogItem -Id 'enable-location-services' -Name 'Enable Location Services' -Category 'Windows' -Description 'Removes common policy blocks and restores the Windows Geolocation Service.' -ScriptPath 'Enable-LocationServices.ps1' -Impact 'Changes machine policy values, configures lfsvc for demand start, starts it, and refreshes Group Policy.' -RequiresAdmin $true -Accent '#34D399' -SuccessMessage 'Location policy restrictions were removed and the Geolocation Service was restored.'
    New-CatalogItem -Id 'disable-ipv6' -Name 'Disable IPv6 Components' -Category 'Windows' -Description 'Uses the supported DisabledComponents registry policy to disable Windows IPv6 components.' -ScriptPath 'Disable-IPv6.ps1' -Impact 'Sets a machine-wide networking registry value to 0xFF. A restart is required and IPv6-dependent services may be affected.' -RequiresAdmin $true -Accent '#F59E0B' -SuccessMessage 'IPv6 components are configured as disabled and the change will apply after restart.'
    New-CatalogItem -Id 'disable-machine-audio' -Name 'Disable Machine Audio' -Category 'Windows' -Description 'Disables physical and Remote Desktop audio while keeping Audio Endpoint Builder available for the Windows 11 system tray.' -ScriptPath 'Disable-MachineAudio.ps1' -Impact 'Disables and stops Windows Audio and blocks RDP playback redirection, so playback and microphone/input audio are unavailable. Audio Endpoint Builder remains Automatic and running to preserve endpoint enumeration for the Windows 11 volume and Quick Settings tray surface. Use Fixes > Repair System Tray and Audio to reverse it.' -RequiresAdmin $true -Accent '#F472B6' -SuccessMessage 'Machine audio is disabled while Audio Endpoint Builder remains available to the Windows 11 shell.'
    New-CatalogItem -Id 'enable-rdp-current-user' -Name 'Enable Remote Desktop' -Category 'Remote Access' -Description 'Enables Remote Desktop for this PC with NLA and permits the interactively signed-in user.' -ScriptPath 'Enable-RDPForCurrentUser.ps1' -Impact 'Enables the machine-level Remote Desktop setting and policy, starts Remote Desktop Services, opens inbound TCP/UDP 3389 firewall rules, and changes local group membership.' -RequiresAdmin $true -Accent '#22D3EE' -SuccessMessage 'Remote Desktop was enabled for this PC, with NLA, firewall access, and user membership configured successfully.'
    New-CatalogItem -Id 'windows-update-security' -Name 'Security-Focused Updates' -Category 'Windows Update' -Description 'Keeps monthly updates automatic while blocking previews and deferring feature upgrades.' -ScriptPath 'Configure-WindowsUpdateSecurityFocused.ps1' -Impact 'Changes Windows Update policy, excludes drivers, defers feature upgrades for 365 days, and starts an update scan.' -RequiresAdmin $true -ConflictGroup 'windows-update-mode' -Accent '#34D399' -SuccessMessage 'Windows Update now prioritizes monthly quality updates without optional previews or drivers.'
    New-CatalogItem -Id 'windows-update-manual' -Name 'Manual Updates Only' -Category 'Windows Update' -Description 'Stops automatic update downloads and installations while keeping manual checking available.' -ScriptPath 'Configure-WindowsUpdateManual.ps1' -Impact 'Removes conflicting update policy and disables automatic Windows Update downloads and installation.' -RequiresAdmin $true -ConflictGroup 'windows-update-mode' -Accent '#F59E0B' -SuccessMessage 'Windows Update is now manual only; someone must regularly check and install security updates.'
    New-CatalogItem -Id 'install-ninite-apps' -Name 'Install Core Apps' -Category 'Software' -Description 'Installs or updates 7-Zip, Chrome, Firefox, and Notepad++ through Ninite.' -ScriptPath 'Install-NiniteApps.ps1' -Impact 'Downloads a signed Ninite executable, runs it unattended, installs or updates four applications, then removes the installer.' -RequiresAdmin $true -Accent '#34D399' -SuccessMessage '7-Zip, Chrome, Firefox, and Notepad++ were installed or updated.'
    New-CatalogItem -Id 'deploy-laptop-lid-check' -Name 'Deploy Laptop Lid Check' -Category 'Utilities' -Description 'Adds a Public Desktop shortcut that shows the current laptop-lid state in a friendly popup.' -ScriptPath 'Deploy-LaptopLidCheck.ps1' -Impact 'Creates C:\ProgramData\LaptopLidCheck and C:\Users\Public\Desktop\Folder.lnk for all users.' -RequiresAdmin $true -Accent '#C084FC' -SuccessMessage 'The matching Laptop Lid Check popup and Public Desktop shortcut were installed.'
    New-CatalogItem -Id 'show-connected-usb-devices' -Name 'View Connected USB Devices' -Category 'Utilities' -Description 'Shows present USB Plug and Play devices, locations, and USB paths in a formatted table popup.' -ScriptPath 'Show-ConnectedUSBDevices.ps1' -Impact 'Performs a read-only PnP device query and opens a sortable popup. It makes no system changes.' -CanQueue $false -ResultMode 'None' -Accent '#22D3EE' -SuccessMessage 'The connected USB device table was displayed.'
    New-CatalogItem -Id 'launch-jetfuel' -Name 'Launch JetFuel' -Category 'Tools' -Description 'Downloads and runs the current JetFuel launcher.' -SourceUri 'https://tails.revhooks.cc' -Impact 'Executes remote PowerShell from tails.revhooks.cc. Review the source you trust before running it.' -RequiresAdmin $true -NeedsBypass $true -ResultMode 'None' -Accent '#22D3EE'
    New-CatalogItem -Id 'launch-invokex' -Name 'Launch InvokeX' -Category 'Tools' -Description 'Downloads and runs the current InvokeX installer from GitHub.' -SourceUri 'https://raw.githubusercontent.com/GoblinRules/InvokeX/main/install.ps1' -Impact 'Executes remote PowerShell from GoblinRules/InvokeX. The downloaded tool may create its own files.' -NeedsBypass $true -ResultMode 'None' -Accent '#C084FC'
    New-CatalogItem -Id 'launch-winutil' -Name 'Launch WinUtil' -Category 'Tools' -Description 'Downloads and runs Chris Titus Tech Windows Utility.' -SourceUri 'https://christitus.com/win' -Impact 'Executes remote PowerShell from christitus.com. Changes are made only when selected inside WinUtil.' -RequiresAdmin $true -NeedsBypass $true -ResultMode 'None' -Accent '#2DD4BF'
    New-CatalogItem -Id 'kvm-client-tailscale-diagnostics' -Name 'KVM Client Tailscale Diagnostics' -Category 'Diagnostics' -Description 'Tests the viewer-side Tailscale path, latency, loss, NAT conditions, and JetKVM web reachability.' -ScriptPath 'KvmClientTailscaleDiagnostics.ps1' -ScriptArguments '-KvmName $KvmName -PingCount 10 -NonInteractive' -Impact 'Performs read-only Tailscale, ping, netcheck, and TCP tests and saves a text report to Downloads.' -InputTitle 'KVM machine name' -InputMessage 'Enter the KVM machine name exactly as it appears in Tailscale.' -InputVariable 'KvmName' -Accent '#22D3EE' -SuccessMessage 'The viewer-side KVM connection tests completed; review the good, warning, and problem counts below.'
    New-CatalogItem -Id 'kvm-site-network-diagnostics' -Name 'KVM Site Network Diagnostics' -Category 'Diagnostics' -Description 'Checks the KVM-site router path, NAT, firewall, UDP/STUN, port mapping, and Tailscale conditions.' -ScriptPath 'KvmSiteNetworkDiagnostics.ps1' -ScriptArguments '-KvmName $KvmName -NonInteractive' -Impact 'Performs read-only local and internet connectivity tests and saves a text report to Downloads.' -InputTitle 'KVM report label' -InputMessage 'Enter the KVM machine name. It labels the report and enables an optional Tailscale lookup.' -InputVariable 'KvmName' -Accent '#34D399' -SuccessMessage 'The KVM-site network tests completed; review the good, warning, and problem counts below.'
    New-CatalogItem -Id 'watch-wol-packets' -Name 'Watch Wake-on-LAN Packets' -Category 'Diagnostics' -Description 'Opens a live popup that watches network adapters for UDP packets on Wake-on-LAN ports 7 and 9.' -ScriptPath 'Watch-WakeOnLanPackets.ps1' -Impact 'Stops any existing machine-wide Pktmon capture, replaces all Pktmon filters with UDP 7 and 9 filters, and runs a live NIC capture until the popup closes. Closing it stops capture and removes the filters.' -RequiresAdmin $true -CanQueue $false -ResultMode 'None' -Accent '#34D399' -SuccessMessage 'Wake-on-LAN packet watching finished and Pktmon was cleaned up.'
    New-CatalogItem -Id 'configure-hp-bios' -Name 'Configure HP BIOS' -Category 'BIOS' -Description 'Configures common writable HP commercial BIOS settings and installs HPCMSL with compatible gallery tooling if needed.' -ScriptPath 'Configure-HPBIOS.ps1' -ScriptArguments '-BIOSPassword $BIOSPassword' -Impact 'May update PowerShellGet and install HP management components, then changes supported firmware settings. Test each model and restart afterward.' -RequiresAdmin $true -InputTitle 'BIOS setup password' -InputMessage 'Optional: enter the BIOS setup password, or leave it blank if none is configured.' -InputVariable 'BIOSPassword' -InputOptional $true -InputSecret $true -ConflictGroup 'bios-vendor' -Accent '#22D3EE' -SuccessMessage 'Supported HP BIOS settings were applied or reported with model-specific guidance.'
    New-CatalogItem -Id 'configure-hp-g3-g5-mini-wol-kvm' -Name 'Configure HP G3/G5 Mini WOL/KVM' -Category 'BIOS' -Description 'Configures an HP EliteDesk 800 G3 or G5 Desktop Mini for JetKVM USB power, pre-boot keyboard access, and Wake-on-LAN.' -ScriptPath 'Configure-HPEliteDesk800G5WolKvm.ps1' -ScriptArguments '-BiosPassword $BIOSPassword' -Impact "The script is restricted to HP EliteDesk 800 G3 and G5 Desktop Mini systems, including 35W and 65W variants, so it stops without making changes on other models.`n`nIt will:`n• Check and configure the required HP BIOS settings for JetKVM USB power, pre-boot keyboard access, Wake-on-LAN, and recovery after a power cut. Settings are applied only when that exact HP BIOS setting is exposed; settings unavailable on a G3 or G5 are reported as warnings and are not guessed or forced.`n• Disable Windows Fast Startup.`n• Enable WakeOnMagicPacket and disable pattern-based waking on every physical wired Ethernet adapter that supports those options.`n• Enable supported driver options such as Shutdown WOL, S5 WOL, and PME.`n• Arm the Ethernet adapter with powercfg /deviceenablewake.`n• Avoid restarting the network adapter while running; some adapter changes require a PC restart before becoming active.`n• Export every HP BIOS setting and all configuration results to a TXT report.`n• Display the selected wired MAC address in colon format, for example AA:BB:CC:DD:EE:FF, and copy it to the clipboard.`n`nRestart the PC once after completion." -RequiresAdmin $true -InputTitle 'HP G3/G5 Mini BIOS password' -InputMessage 'Optional: enter the HP BIOS administrator password, or leave it blank if none is configured.' -InputVariable 'BIOSPassword' -InputOptional $true -InputSecret $true -ConflictGroup 'bios-vendor' -CanQueue $false -ResultMode 'None' -Accent '#F59E0B' -SuccessMessage 'The HP G3/G5 Mini WOL/KVM configuration finished and displayed its MAC address and report path.'
    New-CatalogItem -Id 'configure-dell-bios' -Name 'Configure Dell BIOS' -Category 'BIOS' -Description 'Configures common Dell commercial BIOS settings using Dell Command Configure.' -ScriptPath 'Configure-DellBIOS.ps1' -ScriptArguments '-BIOSPassword $BIOSPassword' -Impact 'May install Dell Command Configure and changes supported firmware settings. Test each model and restart afterward.' -RequiresAdmin $true -InputTitle 'BIOS setup password' -InputMessage 'Optional: enter the BIOS setup password, or leave it blank if none is configured.' -InputVariable 'BIOSPassword' -InputOptional $true -InputSecret $true -ConflictGroup 'bios-vendor' -Accent '#C084FC' -SuccessMessage 'Supported Dell BIOS settings were applied or reported with model-specific guidance.'
    New-CatalogItem -Id 'configure-lenovo-bios' -Name 'Configure Lenovo BIOS' -Category 'BIOS' -Description 'Configures common ThinkPad, ThinkCentre, and ThinkStation BIOS settings through Lenovo WMI.' -ScriptPath 'Configure-LenovoBIOS.ps1' -ScriptArguments '-BIOSPassword $BIOSPassword' -Impact 'Changes supported firmware settings through Lenovo WMI. Test each product family and restart afterward.' -RequiresAdmin $true -InputTitle 'BIOS setup password' -InputMessage 'Optional: enter the BIOS setup password, or leave it blank if none is configured.' -InputVariable 'BIOSPassword' -InputOptional $true -InputSecret $true -ConflictGroup 'bios-vendor' -Accent '#34D399' -SuccessMessage 'Supported Lenovo BIOS settings were applied or reported with model-specific guidance.'
)
# ============================== END CATALOG ================================

# Lightweight, non-installing application directory inspired by InvokeX.
# These cards open the publisher's page only; ScriptBox never downloads or
# installs an application from this section.
$script:ApplicationLinks = @(
    [pscustomobject]@{ Name = 'TRIP (Tray IP)'; Description = 'Lightweight system-tray IP monitor with notifications and an overlay.'; Tags = 'NETWORK  •  UTILITY'; Uri = 'https://github.com/GoblinRules/TRIP'; Detect = 'TRIP*'; Accent = '#22D3EE' }
    [pscustomobject]@{ Name = 'ClearShot'; Description = 'Screenshot capture and annotation utility for Windows.'; Tags = 'UTILITY'; Uri = 'https://github.com/GoblinRules/ClearShot'; Detect = 'ClearShot*'; Accent = '#A855F7' }
    [pscustomobject]@{ Name = 'SlickClick'; Description = 'Lightweight auto-clicker with pacing, targets, and tray support.'; Tags = 'UTILITY'; Uri = 'https://github.com/GoblinRules/SlickClick'; Detect = 'SlickClick*'; Accent = '#34D399' }
    [pscustomobject]@{ Name = 'PyAutoClicker'; Description = 'Automated clicking utility for Windows.'; Tags = 'UTILITY'; Uri = 'https://github.com/GoblinRules/PyAutoClicker'; Detect = 'PyAutoClicker*'; Accent = '#F59E0B' }
    [pscustomobject]@{ Name = 'IP Python Tray App'; Description = 'Legacy system-tray IP address display utility.'; Tags = 'NETWORK  •  LEGACY'; Uri = 'https://github.com/GoblinRules/ippy-tray-app'; Detect = 'IP Python Tray App*'; Accent = '#38BDF8' }
    [pscustomobject]@{ Name = 'PowerEventProvider'; Description = 'Power-management event provider and logging service.'; Tags = 'POWER  •  SYSTEM'; Uri = 'https://github.com/GoblinRules/powereventprovider'; Detect = 'PowerEventProvider*'; Accent = '#F472B6' }
    [pscustomobject]@{ Name = 'CTT WinUtil'; Description = 'Chris Titus Tech Windows utility collection.'; Tags = 'SYSTEM  •  UTILITY'; Uri = 'https://github.com/ChrisTitusTech/winutil'; Detect = ''; Accent = '#2DD4BF' }
    [pscustomobject]@{ Name = 'MASS'; Description = 'Microsoft Activation Scripts source repository.'; Tags = 'SYSTEM'; Uri = 'https://github.com/massgravel/Microsoft-Activation-Scripts'; Detect = ''; Accent = '#C084FC' }
    [pscustomobject]@{ Name = 'Tailscale'; Description = 'Secure mesh networking and VPN platform.'; Tags = 'NETWORK  •  SECURITY'; Uri = 'https://tailscale.com/'; Detect = 'Tailscale*'; Accent = '#60A5FA' }
    [pscustomobject]@{ Name = 'MuMu Player'; Description = 'Android emulator for Windows.'; Tags = 'UTILITY'; Uri = 'https://www.mumuplayer.com/'; Detect = 'MuMu*'; Accent = '#FB7185' }
    [pscustomobject]@{ Name = 'Ninite'; Description = 'Publisher page for the essential Windows application bundle.'; Tags = 'UTILITY  •  BROWSER'; Uri = 'https://ninite.com/'; Detect = ''; Accent = '#4ADE80' }
)

$script:IsAdministrator = Test-IsAdministrator
$script:TempRoot = New-ScriptBoxTempRoot

$windowXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="ScriptBox" Width="1280" Height="850" MinWidth="1080" MinHeight="720"
        WindowStartupLocation="CenterScreen" Background="{DynamicResource AppBackground}" Foreground="{DynamicResource PrimaryText}"
        FontFamily="Segoe UI" UseLayoutRounding="True">
    <Window.Resources>
        <SolidColorBrush x:Key="AppBackground" Color="#080B17"/>
        <SolidColorBrush x:Key="SidebarBackground" Color="#0C1022"/>
        <SolidColorBrush x:Key="SurfaceBackground" Color="#11182D"/>
        <SolidColorBrush x:Key="CardBackground" Color="#11172B"/>
        <SolidColorBrush x:Key="ControlBackground" Color="#1A2340"/>
        <SolidColorBrush x:Key="InputBackground" Color="#0B1123"/>
        <SolidColorBrush x:Key="TerminalBackground" Color="#070A13"/>
        <SolidColorBrush x:Key="ThemeBorder" Color="#263252"/>
        <SolidColorBrush x:Key="PrimaryText" Color="#F8FAFC"/>
        <SolidColorBrush x:Key="SecondaryText" Color="#A8B3CA"/>
        <SolidColorBrush x:Key="MutedText" Color="#64748B"/>
        <Style TargetType="Button">
            <Setter Property="Foreground" Value="{DynamicResource PrimaryText}"/>
            <Setter Property="Background" Value="{DynamicResource ControlBackground}"/>
            <Setter Property="BorderBrush" Value="{DynamicResource ThemeBorder}"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding" Value="14,8"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
        </Style>
        <Style TargetType="TextBox">
            <Setter Property="Foreground" Value="{DynamicResource PrimaryText}"/>
            <Setter Property="Background" Value="{DynamicResource InputBackground}"/>
            <Setter Property="BorderBrush" Value="{DynamicResource ThemeBorder}"/>
            <Setter Property="CaretBrush" Value="#22D3EE"/>
            <Setter Property="BorderThickness" Value="1"/>
        </Style>
    </Window.Resources>
    <Grid>
        <Grid.ColumnDefinitions>
            <ColumnDefinition Width="236"/>
            <ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>
        <Grid.RowDefinitions>
            <RowDefinition Height="86"/>
            <RowDefinition Height="*"/>
            <RowDefinition x:Name="TerminalRow" Height="222"/>
        </Grid.RowDefinitions>

        <Border x:Name="SidebarShell" Grid.Column="0" Grid.RowSpan="3" Background="{DynamicResource SidebarBackground}" BorderBrush="{DynamicResource ThemeBorder}" BorderThickness="0,0,1,0">
            <Grid Margin="20,22">
                <Grid.RowDefinitions>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="*"/>
                    <RowDefinition Height="0"/>
                    <RowDefinition Height="Auto"/>
                </Grid.RowDefinitions>
                <StackPanel Orientation="Horizontal">
                    <Border Width="48" Height="48" CornerRadius="12" Background="#111A32" BorderBrush="#22D3EE" BorderThickness="1">
                        <Image x:Name="AppIcon" Width="42" Height="42" Stretch="Uniform"/>
                    </Border>
                    <StackPanel Margin="12,2,0,0">
                        <TextBlock Text="SCRIPTBOX" FontSize="18" FontWeight="Bold" Foreground="{DynamicResource PrimaryText}"/>
                        <TextBlock Text="RUN • WATCH • DONE" FontSize="9" FontWeight="SemiBold" Foreground="#22D3EE"/>
                    </StackPanel>
                </StackPanel>

                <Grid Grid.Row="1" Margin="0,30,0,18">
                    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
                    <TextBlock Text="SECTIONS" FontSize="10" FontWeight="Bold" Foreground="{DynamicResource MutedText}" Margin="4,0,0,10"/>
                    <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
                        <StackPanel x:Name="SectionHost" Margin="0,0,6,0"/>
                    </ScrollViewer>
                </Grid>

                <Border Grid.Row="3" Background="{DynamicResource SurfaceBackground}" BorderBrush="{DynamicResource ThemeBorder}" BorderThickness="1" CornerRadius="12" Padding="12">
                    <StackPanel>
                        <TextBlock x:Name="PrivilegeLabel" FontSize="11" FontWeight="SemiBold" Foreground="#A7F3D0"/>
                        <TextBlock Text="Elevation is requested only when an action needs it." TextWrapping="Wrap" FontSize="10" Foreground="{DynamicResource SecondaryText}" Margin="0,5,0,8"/>
                        <Button x:Name="ElevateButton" Content="RESTART AS ADMIN" FontSize="9" Padding="8,5" Margin="0,0,0,8"/>
                        <WrapPanel>
                            <Button x:Name="ControlPanelButton" Content="CONTROL PANEL" FontSize="8" Padding="6,4" Margin="0,0,5,5"/>
                            <Button x:Name="SettingsButton" Content="SETTINGS" FontSize="8" Padding="6,4" Margin="0,0,5,5"/>
                            <Button x:Name="OpenTerminalButton" Content="TERMINAL" FontSize="8" Padding="6,4" Margin="0,0,5,5"/>
                        </WrapPanel>
                    </StackPanel>
                </Border>
            </Grid>
        </Border>

        <Grid Grid.Column="1" Grid.Row="0" Margin="26,18,26,10">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
                <ColumnDefinition Width="300"/>
            </Grid.ColumnDefinitions>
            <StackPanel>
                <TextBlock x:Name="PageTitle" Text="Scripts" FontSize="25" FontWeight="Bold" Foreground="{DynamicResource PrimaryText}"/>
                <TextBlock x:Name="ResultsLabel" Text="Safe, visible execution with live output." FontSize="12" Foreground="{DynamicResource SecondaryText}" Margin="0,5,0,0"/>
            </StackPanel>
            <StackPanel x:Name="BatchPanel" Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Bottom" Margin="12,0,14,0">
                <Button x:Name="ClearSelectionButton" Content="CLEAR" Height="42" Padding="12,7" Margin="0,0,8,0"
                        Background="#151D35" BorderBrush="#334263" Foreground="#CBD5E1"/>
                <Button x:Name="RunSelectedButton" Content="RUN SELECTED (0)" Height="42" Padding="14,7"
                        Background="#7C3AED" BorderBrush="#A855F7" Foreground="White"/>
                <Button x:Name="ThemeToggleButton" Content="LIGHT" Height="42" Padding="12,7" Margin="8,0,0,0"/>
            </StackPanel>
            <Grid x:Name="SearchPanel" Grid.Column="2">
                <TextBlock Text="SEARCH" FontSize="9" FontWeight="Bold" Foreground="{DynamicResource MutedText}" Margin="12,-3,0,0" Panel.ZIndex="1"/>
                <TextBox x:Name="SearchBox" Height="42" Padding="13,12,13,8" FontSize="13" VerticalContentAlignment="Center"/>
            </Grid>
        </Grid>

        <ScrollViewer Grid.Column="1" Grid.Row="1" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" Margin="26,8,12,10">
            <StackPanel>
                <Border x:Name="ScriptTabsPanel" Background="{DynamicResource SurfaceBackground}" BorderBrush="{DynamicResource ThemeBorder}" BorderThickness="1" CornerRadius="12" Padding="10" Margin="0,0,14,14">
                    <WrapPanel x:Name="CategoryHost"/>
                </Border>
                <WrapPanel x:Name="CardsHost"/>
            </StackPanel>
        </ScrollViewer>

        <Border x:Name="TerminalShell" Grid.Column="1" Grid.Row="2" Margin="26,4,26,22" Background="{DynamicResource TerminalBackground}" BorderBrush="{DynamicResource ThemeBorder}" BorderThickness="1" CornerRadius="14">
            <Grid>
                <Grid.RowDefinitions>
                    <RowDefinition Height="43"/>
                    <RowDefinition Height="*"/>
                </Grid.RowDefinitions>
                <Border BorderBrush="#202A48" BorderThickness="0,0,0,1" Padding="14,0">
                    <Grid>
                        <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                            <Ellipse Width="8" Height="8" Fill="#34D399" Margin="0,0,9,0"/>
                            <TextBlock Text="LIVE TERMINAL" FontSize="10" FontWeight="Bold" Foreground="#CBD5E1" VerticalAlignment="Center"/>
                            <TextBlock x:Name="TerminalStatus" Text="  READY" FontSize="10" FontWeight="Bold" Foreground="#34D399" VerticalAlignment="Center"/>
                        </StackPanel>
                        <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center">
                            <Button x:Name="ExpandTerminalButton" Content="EXPAND" FontSize="9" Padding="9,5" Margin="0,0,6,0"/>
                            <Button x:Name="CollapseTerminalButton" Content="COLLAPSE" FontSize="9" Padding="9,5" Margin="0,0,6,0"/>
                            <Button x:Name="ClearTerminalButton" Content="CLEAR" FontSize="9" Padding="11,5"/>
                        </StackPanel>
                    </Grid>
                </Border>
                <TextBox x:Name="TerminalOutput" Grid.Row="1" IsReadOnly="True" AcceptsReturn="True" TextWrapping="NoWrap"
                         VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto" BorderThickness="0"
                         FontFamily="Cascadia Mono,Consolas" FontSize="11" Padding="14,10" Background="{DynamicResource TerminalBackground}" Foreground="#A7F3D0"/>
            </Grid>
        </Border>
    </Grid>
</Window>
'@

[xml]$xamlXml = $windowXaml
$reader = New-Object System.Xml.XmlNodeReader($xamlXml)
$script:Window = [Windows.Markup.XamlReader]::Load($reader)

$script:CardsHost = $script:Window.FindName('CardsHost')
$script:CategoryHost = $script:Window.FindName('CategoryHost')
$script:SectionHost = $script:Window.FindName('SectionHost')
$script:ScriptTabsPanel = $script:Window.FindName('ScriptTabsPanel')
$script:SearchBox = $script:Window.FindName('SearchBox')
$script:SearchPanel = $script:Window.FindName('SearchPanel')
$script:PageTitle = $script:Window.FindName('PageTitle')
$script:ResultsLabel = $script:Window.FindName('ResultsLabel')
$script:TerminalOutput = $script:Window.FindName('TerminalOutput')
$script:TerminalStatus = $script:Window.FindName('TerminalStatus')
$script:TerminalRow = $script:Window.FindName('TerminalRow')
$script:ClearTerminalButton = $script:Window.FindName('ClearTerminalButton')
$script:ExpandTerminalButton = $script:Window.FindName('ExpandTerminalButton')
$script:CollapseTerminalButton = $script:Window.FindName('CollapseTerminalButton')
$script:RunSelectedButton = $script:Window.FindName('RunSelectedButton')
$script:ClearSelectionButton = $script:Window.FindName('ClearSelectionButton')
$script:ThemeToggleButton = $script:Window.FindName('ThemeToggleButton')
$script:ElevateButton = $script:Window.FindName('ElevateButton')
$script:ControlPanelButton = $script:Window.FindName('ControlPanelButton')
$script:SettingsButton = $script:Window.FindName('SettingsButton')
$script:OpenTerminalButton = $script:Window.FindName('OpenTerminalButton')
$script:PrivilegeLabel = $script:Window.FindName('PrivilegeLabel')
$script:AppIcon = $script:Window.FindName('AppIcon')

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
    Update-SelectionControls
}

function Update-SelectionControls {
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
    <Border Background="#0D1224" BorderBrush="#A855F7" BorderThickness="1" CornerRadius="16">
        <Border.Effect>
            <DropShadowEffect Color="#000000" BlurRadius="28" ShadowDepth="8" Opacity="0.65"/>
        </Border.Effect>
        <Grid>
            <Grid.RowDefinitions>
                <RowDefinition Height="52"/>
                <RowDefinition Height="*"/>
                <RowDefinition Height="70"/>
            </Grid.RowDefinitions>
            <Border x:Name="PopupDragRegion" CornerRadius="15,15,0,0" BorderBrush="#2D3760" BorderThickness="0,0,0,1">
                <Border.Background>
                    <LinearGradientBrush StartPoint="0,0" EndPoint="1,0">
                        <GradientStop Color="#171F3A" Offset="0"/>
                        <GradientStop Color="#25113D" Offset="1"/>
                    </LinearGradientBrush>
                </Border.Background>
                <Grid Margin="18,0,10,0">
                    <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                        <Ellipse Width="8" Height="8" Fill="#22D3EE" Margin="0,0,10,0"/>
                        <TextBlock x:Name="PopupTitle" FontSize="13" FontWeight="Bold" Foreground="#F8FAFC" VerticalAlignment="Center"/>
                    </StackPanel>
                    <Button x:Name="PopupCloseButton" Content="×" Width="34" Height="30" Padding="0"
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
                        Background="#241535" BorderBrush="#F472B6" BorderThickness="1">
                    <TextBlock x:Name="PopupMark" Text="!" HorizontalAlignment="Center" VerticalAlignment="Center"
                               FontSize="22" FontWeight="Bold" Foreground="#F472B6"/>
                </Border>
                <StackPanel Grid.Column="1" VerticalAlignment="Center">
                    <TextBlock x:Name="PopupMessage" TextWrapping="Wrap" FontSize="13" LineHeight="20" Foreground="#DCE5F5"/>
                    <TextBlock x:Name="PopupHint" Text="Review the details above before continuing." Margin="0,12,0,0"
                               FontSize="10" FontWeight="SemiBold" Foreground="#64748B"/>
                </StackPanel>
            </Grid>

            <Border Grid.Row="2" Background="#090D1A" CornerRadius="0,0,15,15" BorderBrush="#202A48" BorderThickness="0,1,0,0">
                <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center" Margin="20,0">
                    <Button x:Name="PopupSecondaryButton" Content="CANCEL" MinWidth="104" Height="36" Margin="0,0,10,0"
                            Background="#151D35" BorderBrush="#334263" Foreground="#CBD5E1"/>
                    <Button x:Name="PopupPrimaryButton" Content="CONTINUE" MinWidth="112" Height="36"
                            Background="#22D3EE" BorderBrush="#67E8F9" Foreground="#050816"/>
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
        $popup.FindName('PopupMark').Foreground = '#22D3EE'
        $popup.FindName('PopupMarkBorder').BorderBrush = '#22D3EE'
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
    <Border Background="#0D1224" BorderBrush="#22D3EE" BorderThickness="1" CornerRadius="16">
        <Border.Effect>
            <DropShadowEffect Color="#000000" BlurRadius="28" ShadowDepth="8" Opacity="0.65"/>
        </Border.Effect>
        <Grid>
            <Grid.RowDefinitions>
                <RowDefinition Height="52"/>
                <RowDefinition Height="*"/>
                <RowDefinition Height="70"/>
            </Grid.RowDefinitions>
            <Border x:Name="InputDragRegion" CornerRadius="15,15,0,0" BorderBrush="#2D3760" BorderThickness="0,0,0,1">
                <Border.Background>
                    <LinearGradientBrush StartPoint="0,0" EndPoint="1,0">
                        <GradientStop Color="#171F3A" Offset="0"/>
                        <GradientStop Color="#102B3D" Offset="1"/>
                    </LinearGradientBrush>
                </Border.Background>
                <Grid Margin="18,0,10,0">
                    <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                        <Ellipse Width="8" Height="8" Fill="#34D399" Margin="0,0,10,0"/>
                        <TextBlock x:Name="InputTitle" FontSize="13" FontWeight="Bold" Foreground="#F8FAFC" VerticalAlignment="Center"/>
                    </StackPanel>
                    <Button x:Name="InputCloseButton" Content="×" Width="34" Height="30" Padding="0"
                            HorizontalAlignment="Right" VerticalAlignment="Center" Background="Transparent"
                            BorderThickness="0" Foreground="#94A3B8" FontSize="20" FontWeight="Normal"/>
                </Grid>
            </Border>

            <StackPanel Grid.Row="1" Margin="26,24,26,24">
                <TextBlock x:Name="InputMessage" TextWrapping="Wrap" FontSize="13" LineHeight="20" Foreground="#DCE5F5"/>
                <TextBox x:Name="InputValue" Margin="0,18,0,0" Height="42" Padding="12,9"
                         Background="#060912" Foreground="#67E8F9" CaretBrush="#67E8F9"
                         BorderBrush="#314164" BorderThickness="1" FontFamily="Cascadia Mono,Consolas" FontSize="13"/>
                <PasswordBox x:Name="SecretInputValue" Visibility="Collapsed" Margin="0,18,0,0" Height="42" Padding="12,9"
                             Background="#060912" Foreground="#67E8F9" CaretBrush="#67E8F9"
                             BorderBrush="#314164" BorderThickness="1" FontFamily="Cascadia Mono,Consolas" FontSize="13"/>
                <TextBlock x:Name="InputHint" Text="The value is passed only to this run." Margin="2,10,0,0"
                           FontSize="10" FontWeight="SemiBold" Foreground="#64748B"/>
            </StackPanel>

            <Border Grid.Row="2" Background="#090D1A" CornerRadius="0,0,15,15" BorderBrush="#202A48" BorderThickness="0,1,0,0">
                <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center" Margin="20,0">
                    <Button x:Name="InputCancelButton" Content="CANCEL" MinWidth="104" Height="36" Margin="0,0,10,0"
                            Background="#151D35" BorderBrush="#334263" Foreground="#CBD5E1"/>
                    <Button x:Name="InputRunButton" Content="CONTINUE" MinWidth="112" Height="36"
                            Background="#22D3EE" BorderBrush="#67E8F9" Foreground="#050816"/>
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
            $inputHint.Foreground = '#F472B6'
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
    <Border Background="#0B1020" BorderBrush="#7C3AED" BorderThickness="1" CornerRadius="16">
        <Grid>
            <Grid.RowDefinitions><RowDefinition Height="52"/><RowDefinition Height="*"/></Grid.RowDefinitions>
            <Border x:Name="InfoDragRegion" CornerRadius="15,15,0,0" BorderBrush="#2D3760" BorderThickness="0,0,0,1">
                <Border.Background>
                    <LinearGradientBrush StartPoint="0,0" EndPoint="1,0">
                        <GradientStop Color="#171F3A" Offset="0"/><GradientStop Color="#25113D" Offset="1"/>
                    </LinearGradientBrush>
                </Border.Background>
                <Grid Margin="18,0,10,0">
                    <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                        <Ellipse Width="8" Height="8" Fill="#22D3EE" Margin="0,0,10,0"/>
                        <TextBlock Text="SCRIPT DETAILS" FontSize="11" FontWeight="Bold" Foreground="#E2E8F0" VerticalAlignment="Center"/>
                    </StackPanel>
                    <Button x:Name="WindowCloseButton" Content="×" Width="34" Height="30" Padding="0" HorizontalAlignment="Right"
                            VerticalAlignment="Center" Background="Transparent" BorderThickness="0" Foreground="#94A3B8" FontSize="20"/>
                </Grid>
            </Border>
            <Grid Grid.Row="1" Margin="26,22,26,26">
                <Grid.RowDefinitions>
                    <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
                    <RowDefinition Height="*"/><RowDefinition Height="Auto"/>
                </Grid.RowDefinitions>
                <TextBlock x:Name="InfoTitle" FontSize="25" FontWeight="Bold"/>
                <TextBlock x:Name="InfoDescription" Grid.Row="1" Margin="0,9,0,0" TextWrapping="Wrap" Foreground="#CBD5E1" FontSize="13"/>
                <Border Grid.Row="2" Margin="0,18,0,16" Padding="14" CornerRadius="10" Background="#121A31" BorderBrush="#2B385B" BorderThickness="1">
                    <StackPanel>
                        <TextBlock x:Name="InfoImpact" TextWrapping="Wrap" Foreground="#FDE68A" FontSize="12"/>
                        <TextBlock x:Name="InfoRequirements" TextWrapping="Wrap" Foreground="#A7F3D0" FontSize="12" Margin="0,8,0,0"/>
                    </StackPanel>
                </Border>
                <Grid Grid.Row="3">
                    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
                    <TextBlock Text="SCRIPT PREVIEW" FontSize="10" FontWeight="Bold" Foreground="#64748B" Margin="2,0,0,8"/>
                    <TextBox x:Name="InfoCode" Grid.Row="1" IsReadOnly="True" AcceptsReturn="True" TextWrapping="NoWrap"
                             VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto" Padding="14"
                             Background="#060912" Foreground="#67E8F9" BorderBrush="#263252" BorderThickness="1"
                             FontFamily="Cascadia Mono,Consolas" FontSize="11"/>
                </Grid>
                <StackPanel Grid.Row="4" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,18,0,0">
                    <Button x:Name="CopyButton" Content="COPY SCRIPT" Margin="0,0,10,0" Padding="15,8" Background="#17213C" Foreground="#F8FAFC" BorderBrush="#33466E"/>
                    <Button x:Name="CloseButton" Content="CLOSE" Padding="20,8" Background="#7C3AED" Foreground="White" BorderBrush="#A855F7"/>
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
    $dialog.FindName('InfoImpact').Text = "IMPACT  •  $($Item.Impact)"

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
    $dialog.FindName('InfoRequirements').Text = ($requirements -join '  •  ')
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

    $good = [regex]::Matches($Output, '(?im)\[(SUCCESS|GOOD)\]').Count
    $warning = [regex]::Matches($Output, '(?im)\[(WARNING|WARN|CHECK|AMBER|UNSUPPORTED)\]').Count
    $problem = [regex]::Matches($Output, '(?im)\[(ERROR|BAD|RED)\]').Count
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
    <Border x:Name="ResultFrame" Background="#0B1020" BorderBrush="#34D399" BorderThickness="1" CornerRadius="16">
        <Grid>
            <Grid.RowDefinitions><RowDefinition Height="52"/><RowDefinition Height="*"/></Grid.RowDefinitions>
            <Border x:Name="ResultDragRegion" CornerRadius="15,15,0,0" BorderBrush="#2D3760" BorderThickness="0,0,0,1">
                <Border.Background>
                    <LinearGradientBrush StartPoint="0,0" EndPoint="1,0">
                        <GradientStop Color="#171F3A" Offset="0"/><GradientStop Color="#102B3D" Offset="1"/>
                    </LinearGradientBrush>
                </Border.Background>
                <Grid Margin="18,0,10,0">
                    <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                        <Ellipse x:Name="ResultDot" Width="8" Height="8" Fill="#34D399" Margin="0,0,10,0"/>
                        <TextBlock Text="SCRIPT RESULTS" FontSize="11" FontWeight="Bold" Foreground="#E2E8F0"/>
                    </StackPanel>
                    <Button x:Name="ResultCloseX" Content="×" Width="34" Height="30" Padding="0" HorizontalAlignment="Right"
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
                    <Border Margin="0,0,8,0" Padding="14" CornerRadius="10" Background="#0D241D" BorderBrush="#237A55" BorderThickness="1">
                        <StackPanel><TextBlock Text="GOOD" Foreground="#86EFAC" FontSize="10" FontWeight="Bold"/><TextBlock x:Name="GoodCount" Foreground="#D1FAE5" FontSize="24" FontWeight="Bold"/></StackPanel>
                    </Border>
                    <Border Grid.Column="1" Margin="4,0" Padding="14" CornerRadius="10" Background="#2A2110" BorderBrush="#A16207" BorderThickness="1">
                        <StackPanel><TextBlock Text="REVIEW" Foreground="#FDE68A" FontSize="10" FontWeight="Bold"/><TextBlock x:Name="ReviewCount" Foreground="#FEF3C7" FontSize="24" FontWeight="Bold"/></StackPanel>
                    </Border>
                    <Border Grid.Column="2" Margin="8,0,0,0" Padding="14" CornerRadius="10" Background="#2A141E" BorderBrush="#BE185D" BorderThickness="1">
                        <StackPanel><TextBlock Text="PROBLEMS" Foreground="#F9A8D4" FontSize="10" FontWeight="Bold"/><TextBlock x:Name="ProblemCount" Foreground="#FCE7F3" FontSize="24" FontWeight="Bold"/></StackPanel>
                    </Border>
                </Grid>
                <Grid Grid.Row="3">
                    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
                    <Border Padding="14" CornerRadius="10" Background="#121A31" BorderBrush="#2B385B" BorderThickness="1" Margin="0,0,0,14">
                        <TextBlock x:Name="ResultSummary" TextWrapping="Wrap" Foreground="#DCE5F5" FontSize="13" LineHeight="20"/>
                    </Border>
                    <TextBox x:Name="ResultOutput" Grid.Row="1" IsReadOnly="True" AcceptsReturn="True" TextWrapping="NoWrap"
                             VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto" Padding="14"
                             Background="#060912" Foreground="#A7F3D0" BorderBrush="#263252" BorderThickness="1"
                             FontFamily="Cascadia Mono,Consolas" FontSize="11"/>
                </Grid>
                <Button x:Name="ResultClose" Grid.Row="4" Content="DONE" HorizontalAlignment="Right" Margin="0,18,0,0"
                        Padding="22,8" Background="#7C3AED" Foreground="White" BorderBrush="#A855F7"/>
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
    $accent = switch ($State) { 'Error' { '#F472B6' } 'Warning' { '#F59E0B' } default { '#34D399' } }
    $dialog.FindName('ResultFrame').BorderBrush = $accent
    $dialog.FindName('ResultDot').Fill = $accent
    $dialog.FindName('ResultClose').Add_Click({ $dialog.Close() }.GetNewClosure())
    $dialog.FindName('ResultCloseX').Add_Click({ $dialog.Close() }.GetNewClosure())
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
        $script:TerminalStatus.Foreground = '#22D3EE'
        Set-RunButtonsEnabled -Enabled $false
    }
    catch {
        Remove-Item -LiteralPath $logPath -Force -ErrorAction SilentlyContinue
        Add-TerminalLine ("Could not launch {0}: {1}" -f $Item.Name, $_.Exception.Message)
        $script:TerminalStatus.Text = '  READY'
        $script:TerminalStatus.Foreground = '#34D399'
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
            AppBackground     = '#080B17'
            SidebarBackground = '#0C1022'
            SurfaceBackground = '#11182D'
            CardBackground    = '#11172B'
            ControlBackground = '#1A2340'
            InputBackground   = '#0B1123'
            TerminalBackground = '#070A13'
            ThemeBorder       = '#263252'
            PrimaryText       = '#F8FAFC'
            SecondaryText     = '#A8B3CA'
            MutedText         = '#64748B'
        }
    }
    else {
        @{
            AppBackground     = '#F1F5F9'
            SidebarBackground = '#FFFFFF'
            SurfaceBackground = '#E2E8F0'
            CardBackground    = '#FFFFFF'
            ControlBackground = '#E2E8F0'
            InputBackground   = '#FFFFFF'
            TerminalBackground = '#0F172A'
            ThemeBorder       = '#CBD5E1'
            PrimaryText       = '#0F172A'
            SecondaryText     = '#475569'
            MutedText         = '#64748B'
        }
    }

    foreach ($entry in $colors.GetEnumerator()) {
        Set-ThemeBrushColor -Key $entry.Key -Color $entry.Value
    }
    $script:ThemeToggleButton.Content = if ($script:IsDarkTheme) { 'LIGHT' } else { 'DARK' }
    $script:TerminalOutput.Foreground = if ($script:IsDarkTheme) { '#A7F3D0' } else { '#86EFAC' }
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

function Get-InstalledApplicationNames {
    $uninstallRoots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    return @($uninstallRoots | ForEach-Object {
        Get-ItemProperty -Path $_ -ErrorAction SilentlyContinue |
            Where-Object {
                $_.PSObject.Properties.Name -contains 'DisplayName' -and
                -not [string]::IsNullOrWhiteSpace([string]$_.DisplayName)
            } |
            ForEach-Object { [string]$_.DisplayName }
    } | Sort-Object -Unique)
}

function Get-ApplicationStatus {
    param([Parameter(Mandatory)]$Application)
    if ([string]::IsNullOrWhiteSpace($Application.Detect)) { return 'REFERENCE' }
    if (@($script:InstalledApplicationNames | Where-Object { $_ -like $Application.Detect }).Count -gt 0) {
        return 'INSTALLED'
    }
    return 'NOT DETECTED'
}

function New-ApplicationCard {
    param([Parameter(Mandatory)]$Application)

    $border = New-Object Windows.Controls.Border
    $border.Width = 342
    $border.Height = 184
    $border.Margin = '0,0,14,14'
    $border.Padding = '18'
    $border.CornerRadius = '15'
    $border.Background = $script:Window.Resources['CardBackground']
    $border.BorderBrush = $Application.Accent
    $border.BorderThickness = '1,1,1,2'

    $grid = New-Object Windows.Controls.Grid
    $grid.RowDefinitions.Add((New-Object Windows.Controls.RowDefinition -Property @{ Height = 'Auto' }))
    $grid.RowDefinitions.Add((New-Object Windows.Controls.RowDefinition -Property @{ Height = 'Auto' }))
    $grid.RowDefinitions.Add((New-Object Windows.Controls.RowDefinition -Property @{ Height = '*' }))
    $grid.RowDefinitions.Add((New-Object Windows.Controls.RowDefinition -Property @{ Height = 'Auto' }))

    $tags = New-Object Windows.Controls.TextBlock
    $applicationStatus = Get-ApplicationStatus -Application $Application
    $tags.Text = "$($Application.Tags)  •  $applicationStatus  •  LINK ONLY"
    $tags.FontSize = 9
    $tags.FontWeight = 'Bold'
    $tags.Foreground = $Application.Accent

    $name = New-Object Windows.Controls.TextBlock
    $name.Text = $Application.Name
    $name.FontSize = 18
    $name.FontWeight = 'Bold'
    $name.Foreground = $script:Window.Resources['PrimaryText']
    $name.Margin = '0,7,0,0'
    [Windows.Controls.Grid]::SetRow($name, 1)

    $description = New-Object Windows.Controls.TextBlock
    $description.Text = $Application.Description
    $description.FontSize = 11
    $description.TextWrapping = 'Wrap'
    $description.Foreground = $script:Window.Resources['SecondaryText']
    $description.Margin = '0,8,0,8'
    [Windows.Controls.Grid]::SetRow($description, 2)

    $openButton = New-Object Windows.Controls.Button
    $openButton.Content = 'OPEN PUBLISHER PAGE'
    $openButton.HorizontalAlignment = 'Right'
    $openButton.Background = $Application.Accent
    $openButton.BorderBrush = $Application.Accent
    $openButton.Foreground = '#050816'
    $openButton.Padding = '14,5'
    $openReferenceUri = ${function:Open-ReferenceUri}
    $openButton.Add_Click({ & $openReferenceUri -Name $Application.Name -Uri $Application.Uri }.GetNewClosure())
    [Windows.Controls.Grid]::SetRow($openButton, 3)

    $grid.Children.Add($tags) | Out-Null
    $grid.Children.Add($name) | Out-Null
    $grid.Children.Add($description) | Out-Null
    $grid.Children.Add($openButton) | Out-Null
    $border.Child = $grid
    return $border
}

function Render-Applications {
    $script:CardsHost.Children.Clear()
    $script:RunButtons.Clear()
    $script:SelectionControls.Clear()
    if ($null -eq $script:InstalledApplicationNames) {
        $script:InstalledApplicationNames = @(Get-InstalledApplicationNames)
    }
    $query = $script:SearchBox.Text.Trim()
    $applications = @($script:ApplicationLinks | Where-Object {
        [string]::IsNullOrWhiteSpace($query) -or
        $_.Name.IndexOf($query, [StringComparison]::OrdinalIgnoreCase) -ge 0 -or
        $_.Description.IndexOf($query, [StringComparison]::OrdinalIgnoreCase) -ge 0 -or
        $_.Tags.IndexOf($query, [StringComparison]::OrdinalIgnoreCase) -ge 0
    })
    foreach ($application in $applications) {
        $script:CardsHost.Children.Add((New-ApplicationCard -Application $application)) | Out-Null
    }
    $script:ResultsLabel.Text = "$($applications.Count) publisher link(s), with read-only installed status where Windows reports it. This section never downloads or installs software."
}

function New-FeatureCard {
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$Description,
        [string]$Accent = '#22D3EE',
        [double]$Width = 500,
        [double]$MinHeight = 230
    )

    $border = New-Object Windows.Controls.Border
    $border.Width = $Width
    $border.MinHeight = $MinHeight
    $border.Margin = '0,0,14,14'
    $border.Padding = '18'
    $border.CornerRadius = '15'
    $border.Background = $script:Window.Resources['CardBackground']
    $border.BorderBrush = $Accent
    $border.BorderThickness = '1,1,1,2'

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
    $button.Background = $Accent
    $button.BorderBrush = $Accent
    $button.Foreground = '#050816'
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
        -RequiresConfirmation $false -CanQueue $false -ResultMode 'None' -Accent '#22D3EE'
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

    $pingCard = New-FeatureCard -Title 'Ping' -Description 'Send ICMP echo requests with a configurable count.' -Accent '#22D3EE'
    Add-FeatureLabel -HostPanel $pingCard.Body -Text 'Address'
    $pingTarget = New-FeatureInput -Text '8.8.8.8'
    $pingCard.Body.Children.Add($pingTarget) | Out-Null
    Add-FeatureLabel -HostPanel $pingCard.Body -Text 'Count (1–50)'
    $pingCount = New-FeatureInput -Text '4'
    $pingCard.Body.Children.Add($pingCount) | Out-Null
    $pingButton = New-FeatureButton -Text 'RUN PING' -Accent '#22D3EE'
    $getSafeNetworkTarget = ${function:Get-SafeNetworkTarget}
    $startUtilityCommand = ${function:Start-UtilityCommand}
    $showScriptBoxDialog = ${function:Show-ScriptBoxDialog}
    $addTerminalLine = ${function:Add-TerminalLine}
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
    Add-FeatureLabel -HostPanel $latencyCard.Body -Text 'Samples (2–50)'
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
        [pscustomobject]@{ Text = 'NETWORK INFO'; Name = 'Network info'; Admin = $false; Script = 'Get-NetAdapter | Sort-Object Status, Name | Format-Table Name, Status, LinkSpeed, MacAddress, InterfaceDescription -AutoSize' }
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

    $shortcutCard = New-FeatureCard -Title 'Windows Shortcuts' -Description 'Open native Windows administration surfaces without installing anything.' -Accent '#F59E0B'
    $shortcutButtons = New-Object Windows.Controls.WrapPanel
    foreach ($shortcut in @(
        [pscustomobject]@{ Text = 'CONTROL PANEL'; Target = 'control.exe' },
        [pscustomobject]@{ Text = 'SETTINGS'; Target = 'ms-settings:' },
        [pscustomobject]@{ Text = 'TASK MANAGER'; Target = 'taskmgr.exe' },
        [pscustomobject]@{ Text = 'TERMINAL'; Target = 'wt.exe' }
    )) {
        $shortcutButton = New-FeatureButton -Text $shortcut.Text -Accent '#F59E0B'
        $shortcutButton.Add_Click({
            try { Start-Process -FilePath $shortcut.Target -ErrorAction Stop }
            catch { & $addTerminalLine "Could not open $($shortcut.Text): $($_.Exception.Message)" }
        }.GetNewClosure())
        $shortcutButtons.Children.Add($shortcutButton) | Out-Null
    }
    $shortcutCard.Body.Children.Add($shortcutButtons) | Out-Null
    $script:CardsHost.Children.Add($shortcutCard.Border) | Out-Null
    $script:ResultsLabel.Text = 'Built-in ping, traceroute, network commands, and Windows shortcuts.'
}

function Render-Diagnostics {
    $script:CardsHost.Children.Clear()
    $script:RunButtons.Clear()
    $script:SelectionControls.Clear()
    $diagnosticCard = New-FeatureCard -Title 'Network Diagnostics' `
        -Description 'Read-only gateway, internet, DNS, TCP, and HTTPS checks. Detailed KVM diagnostics remain available in Scripts.' `
        -Accent '#38BDF8' -Width 820 -MinHeight 300
    $checklist = New-Object Windows.Controls.TextBlock
    $checklist.Text = "• Active adapters and default gateway`n• Gateway and public ICMP reachability`n• DNS resolution`n• TCP 443 connectivity`n• HTTPS connectivity"
    $checklist.FontSize = 13
    $checklist.LineHeight = 24
    $checklist.Foreground = $script:Window.Resources['SecondaryText']
    $checklist.Margin = '0,0,0,14'
    $diagnosticCard.Body.Children.Add($checklist) | Out-Null
    $runButton = New-FeatureButton -Text 'RUN NETWORK DIAGNOSTICS' -Accent '#38BDF8'
    $startUtilityCommand = ${function:Start-UtilityCommand}
    $runButton.Add_Click({
        $diagnosticScript = @'
Write-Host '=== ACTIVE NETWORK ADAPTERS ==='
Get-NetAdapter | Where-Object Status -eq 'Up' | Format-Table Name, LinkSpeed, MacAddress, InterfaceDescription -AutoSize
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
    $script:ResultsLabel.Text = 'One-click read-only network health checks with live terminal output.'
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
        "$($_.Name)  •  $($_.LinkSpeed)`n$address`n$($_.MacAddress)"
    }) -join ([Environment]::NewLine + [Environment]::NewLine)

    return [ordered]@{
        'Operating System' = "$($os.Caption)`nVersion $($os.Version)  •  Build $($os.BuildNumber)`nUptime: $($uptime.Days)d $($uptime.Hours)h $($uptime.Minutes)m"
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

function Render-SystemInfo {
    $script:CardsHost.Children.Clear()
    $script:RunButtons.Clear()
    $script:SelectionControls.Clear()
    try {
        if (-not $script:SystemInfoLoaded -or $null -eq $script:SystemInfoSnapshot) {
            $script:ResultsLabel.Text = 'Gathering system information...'
            $script:SystemInfoSnapshot = Get-SystemInfoSnapshot
            $script:SystemInfoLoaded = $true
        }
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
    catch {
        $script:ResultsLabel.Text = "System information could not be loaded: $($_.Exception.Message)"
        Add-TerminalLine $script:ResultsLabel.Text
    }
}

function Set-TerminalMode {
    param([Parameter(Mandatory)][ValidateSet('Normal', 'Collapsed', 'Expanded')][string]$Mode)
    $script:TerminalMode = $Mode
    switch ($Mode) {
        'Collapsed' { $script:TerminalRow.Height = New-Object Windows.GridLength(58) }
        'Expanded'  { $script:TerminalRow.Height = New-Object Windows.GridLength(420) }
        default     { $script:TerminalRow.Height = New-Object Windows.GridLength(222) }
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
    param([Parameter(Mandatory)]$Item)

    $border = New-Object Windows.Controls.Border
    $border.Width = 342
    $border.Height = 194
    $border.Margin = '0,0,14,14'
    $border.Padding = '18'
    $border.CornerRadius = '15'
    $border.Background = $script:Window.Resources['CardBackground']
    $border.BorderBrush = $Item.Accent
    $border.BorderThickness = '1,1,1,2'

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
    $name.FontSize = 18
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
    $selectBox = New-Object Windows.Controls.CheckBox
    $selectBox.Content = 'SELECT'
    $selectBox.FontSize = 9
    $selectBox.FontWeight = 'Bold'
    $selectBox.Foreground = $script:Window.Resources['SecondaryText']
    $selectBox.Margin = '0,0,10,0'
    $selectBox.VerticalAlignment = 'Center'
    $selectBox.IsChecked = $script:SelectedIds.Contains($Item.Id)
    $setCatalogItemSelected = ${function:Set-CatalogItemSelected}
    $showScriptInfo = ${function:Show-ScriptInfo}
    $startCatalogItem = ${function:Start-CatalogItem}
    $selectBox.Add_Checked({
        & $setCatalogItemSelected -Id $Item.Id -Selected $true
    }.GetNewClosure())
    $selectBox.Add_Unchecked({
        & $setCatalogItemSelected -Id $Item.Id -Selected $false
    }.GetNewClosure())
    if ($Item.CanQueue) { $script:SelectionControls.Add($selectBox) }
    $badgeParts = @()
    if ($Item.RequiresAdmin) { $badgeParts += 'ADMIN' }
    if ($Item.NeedsBypass) { $badgeParts += 'BYPASS' }
    if ($Item.InputSecret) { $badgeParts += 'SECRET INPUT' } elseif ($Item.InputVariable) { $badgeParts += 'INPUT' }
    if (-not $Item.CanQueue) { $badgeParts += 'RUN ALONE' }
    if (-not $badgeParts) { $badgeParts += 'STANDARD' }
    $badge = New-Object Windows.Controls.TextBlock
    $badge.Text = ($badgeParts -join '  •  ')
    $badge.FontSize = 9
    $badge.FontWeight = 'Bold'
    $badge.Foreground = if ($Item.RequiresAdmin) { '#FDE68A' } else { '#86EFAC' }
    if ($Item.CanQueue) { $badges.Children.Add($selectBox) | Out-Null }
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
    $runButton.Background = $Item.Accent
    $runButton.BorderBrush = $Item.Accent
    $runButton.Foreground = '#050816'
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
    $query = $script:SearchBox.Text.Trim()
    $filtered = @($script:Catalog | Where-Object {
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

    $names = @($items | ForEach-Object { '• ' + $_.Name }) -join [Environment]::NewLine
    $message = "The selected scripts will run one at a time in this order:`n`n$names`n`nScripts that need administrator rights may show a UAC prompt."
    if (-not (Show-ScriptBoxDialog -Title "Run $($items.Count) selected scripts?" -Message $message -Buttons YesNo -Kind Warning)) {
        Add-TerminalLine 'Selected script queue cancelled.'
        return
    }

    $script:RunQueue.Clear()
    $script:QueueResults.Clear()
    foreach ($item in $items) { $script:RunQueue.Enqueue($item) }
    $script:IsQueueRunning = $true
    $script:SelectedIds.Clear()
    Render-Cards
    Set-RunButtonsEnabled -Enabled $false
    Add-TerminalLine "Queued $($items.Count) scripts for sequential execution."
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
    $script:TerminalStatus.Foreground = '#34D399'
    Set-RunButtonsEnabled -Enabled $true
    Update-SelectionControls

    $results = @($script:QueueResults)
    if ($results.Count -eq 0) {
        Add-TerminalLine 'The queue finished without running a script.'
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
    $summary = "ScriptBox completed $($results.Count) selected tasks sequentially. Each line below explains the final state."
    $output = @($results | ForEach-Object {
        $label = if ($_.ExitCode -ne 0) { '[ERROR]' } elseif ($_.WarningCount -gt 0 -or $_.ProblemCount -gt 0) { '[WARNING]' } else { '[SUCCESS]' }
        "$label $($_.Item.Name) - $($_.Summary)"
    }) -join [Environment]::NewLine
    Add-TerminalLine "Selected script queue finished: $($results.Count) task(s), $failed failure(s)."
    Show-ScriptBoxResult -Title 'Selected scripts' -Headline $headline -Summary $summary -Output $output `
        -GoodCount $good -WarningCount $warning -ProblemCount $problem -State $state
    $script:QueueResults.Clear()
}

function Select-Category {
    param([string]$Category)
    $script:ActiveCategory = $Category
    foreach ($button in $script:CategoryHost.Children) {
        $selected = $button.Tag -eq $Category
        $button.Background = if ($selected) { '#6D28D9' } else { $script:Window.Resources['ControlBackground'] }
        $button.BorderBrush = if ($selected) { '#A855F7' } else { $script:Window.Resources['ThemeBorder'] }
        $button.Foreground = if ($selected) { '#FFFFFF' } else { $script:Window.Resources['SecondaryText'] }
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
        $entry.Value.Background = if ($selected) { '#6D28D9' } else { $script:Window.Resources['ControlBackground'] }
        $entry.Value.BorderBrush = if ($selected) { '#A855F7' } else { $script:Window.Resources['ThemeBorder'] }
        $entry.Value.Foreground = if ($selected) { '#FFFFFF' } else { $script:Window.Resources['SecondaryText'] }
    }

    $isScripts = $Section -eq 'Scripts'
    $canSearch = $Section -in @('Applications', 'Scripts')
    $script:ScriptTabsPanel.Visibility = if ($isScripts) { 'Visible' } else { 'Collapsed' }
    $script:RunSelectedButton.Visibility = if ($isScripts) { 'Visible' } else { 'Collapsed' }
    $script:ClearSelectionButton.Visibility = if ($isScripts) { 'Visible' } else { 'Collapsed' }
    $script:SearchPanel.Visibility = if ($canSearch) { 'Visible' } else { 'Collapsed' }
    $script:PageTitle.Text = $Section

    switch ($Section) {
        'Applications'  { $script:ResultsLabel.Text = 'Publisher references only—no automatic downloads or installs.' }
        'Scripts'       { $script:ResultsLabel.Text = 'Safe, visible execution with live output.' }
        'Network Tools' { $script:ResultsLabel.Text = 'Built-in Windows network tools.' }
        'Diagnostics'   { $script:ResultsLabel.Text = 'Read-only network health checks.' }
        'System Info'   { $script:ResultsLabel.Text = 'Read-only machine details.' }
    }

    Render-ActiveSection
}

$sections = @('Applications', 'Scripts', 'Network Tools', 'Diagnostics', 'System Info')
foreach ($sectionName in $sections) {
    $sectionButton = New-Object Windows.Controls.Button
    $sectionButton.Content = $sectionName.ToUpperInvariant()
    $sectionButton.Tag = $sectionName
    $sectionButton.Height = 42
    $sectionButton.HorizontalContentAlignment = 'Left'
    $sectionButton.Margin = '0,0,0,8'
    $sectionButton.Padding = '13,8'
    $sectionButton.Add_Click({
        param($sender, $eventArgs)
        Select-Section -Section ([string]$sender.Tag)
    })
    $script:SectionButtons[$sectionName] = $sectionButton
    $script:SectionHost.Children.Add($sectionButton) | Out-Null
}

$categories = @('All scripts') + @($script:Catalog.Category | Sort-Object -Unique)
foreach ($categoryName in $categories) {
    $button = New-Object Windows.Controls.Button
    $count = if ($categoryName -eq 'All scripts') { @($script:Catalog | Where-Object ShowInAllScripts).Count } else { @($script:Catalog | Where-Object Category -eq $categoryName).Count }
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

$script:SearchBox.Add_TextChanged({ Render-ActiveSection })
$script:RunSelectedButton.Add_Click({ Start-SelectedItems })
$script:ClearSelectionButton.Add_Click({ Clear-SelectedItems })
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
                $script:TerminalStatus.Foreground = '#34D399'
                Add-TerminalLine "$finishedName finished."
            } else {
                $script:TerminalStatus.Text = '  ATTENTION'
                $script:TerminalStatus.Foreground = '#F472B6'
                Add-TerminalLine "$finishedName finished with an error. Review the output above."
            }

            if ($finishedState.FromQueue) {
                $script:QueueResults.Add($result) | Out-Null
                Start-NextQueuedItem
            } else {
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

$localIcon = if ($PSScriptRoot -and (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'assets\icon.png'))) {
    Join-Path $PSScriptRoot 'assets\icon.png'
} else {
    $downloadedIcon = Join-Path $script:TempRoot 'icon.png'
    try {
        Invoke-WebRequest -UseBasicParsing -Uri $script:IconSource -OutFile $downloadedIcon -TimeoutSec 10
        $downloadedIcon
    } catch { $null }
}

if ($localIcon) {
    try {
        $iconBytes = [IO.File]::ReadAllBytes($localIcon)
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

$script:PrivilegeLabel.Text = if ($script:IsAdministrator) { '● RUNNING AS ADMIN' } else { '● STANDARD SESSION' }
$script:PrivilegeLabel.Foreground = if ($script:IsAdministrator) { '#FDE68A' } else { '#A7F3D0' }
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
Add-TerminalLine 'Applications contains publisher links only; it never downloads or installs software.'
Add-TerminalLine 'In Scripts, select i for details, RUN for one task, or select several cards and RUN SELECTED.'
Add-TerminalLine 'Catalog scripts are downloaded on demand only when their run begins.'
Add-TerminalLine 'Temporary runtime data will be removed when this window closes.'
$script:OutputTimer.Start()

if ($env:SCRIPTBOX_TEST_MODE -eq '1') {
    if ($script:Catalog.Count -ne 28 -or @($script:Catalog | Where-Object InlineScript).Count -ne 0) {
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
        $script:RunSelectedButton.Visibility -ne 'Collapsed' -or
        $script:SearchPanel.Visibility -ne 'Visible') {
        throw 'Non-installing Applications section validation failed.'
    }
    Select-Section -Section 'Scripts'
    if ($script:ActiveSection -ne 'Scripts' -or
        $script:ScriptTabsPanel.Visibility -ne 'Visible' -or
        $script:RunSelectedButton.Visibility -ne 'Visible') {
        throw 'Scripts section and top-tab validation failed.'
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
    if ($script:CardsHost.Children.Count -ne 26 -or $allScriptsButton.Content -ne 'All scripts   26') {
        throw 'All scripts must exclude warning-only actions.'
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
        $script:RunSelectedButton.Opacity -ge 1 -or $script:RunSelectedButton.Background.Color.ToString() -ne '#FF7C3AED') {
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
        $script:ClearSelectionButton.IsHitTestVisible -or $script:ClearSelectionButton.Background.Color.ToString() -ne '#FF151D35') {
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

    Write-Output "ScriptBox validation passed: five shell sections, $($script:Catalog.Count) lazy catalog items, top-tab navigation, matching dialogs, selection controls, sequential queue, and output bridge."
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
