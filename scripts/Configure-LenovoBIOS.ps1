#requires -Version 5.1
<#
.SYNOPSIS
    Configures supported Lenovo BIOS settings, with an explicit profile for the
    ThinkCentre M710q Tiny.

.DESCRIPTION
    Uses Lenovo's built-in WMI BIOS interface; no Lenovo module is installed.
    The M710q profile enables the onboard Ethernet controller, Wake-on-LAN,
    Smart Power On, USB and USB legacy support, and front/rear USB ports. It
    disables Enhanced Power Saving Mode so wake functions remain available and
    configures the system to power on after AC power is restored.

    Other Lenovo systems receive only settings whose names are exposed exactly
    by their firmware. Unsupported settings are reported and skipped.

    Lenovo's current opcode password interface is used when available. The
    legacy password format remains as a compatibility fallback. BIOS changes
    are staged first and saved once, as recommended by Lenovo.

    No restart is performed automatically. A detailed TXT report is written to
    ProgramData and copied to the current user's Desktop when possible.

.PARAMETER BIOSPassword
    Optional Lenovo BIOS supervisor/administrator password. It is used only
    when the firmware reports that authentication is required (or password
    state cannot be read).
#>
[CmdletBinding()]
param(
    [string]$BIOSPassword = ''
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Show-ResultPopup {
    param(
        [Parameter(Mandatory = $true)][string]$Title,
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet('Information', 'Warning', 'Error')][string]$Icon = 'Information'
    )

    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        $iconValue = switch ($Icon) {
            'Warning' { [System.Windows.Forms.MessageBoxIcon]::Warning }
            'Error' { [System.Windows.Forms.MessageBoxIcon]::Error }
            default { [System.Windows.Forms.MessageBoxIcon]::Information }
        }
        [void][System.Windows.Forms.MessageBox]::Show(
            $Message,
            $Title,
            [System.Windows.Forms.MessageBoxButtons]::OK,
            $iconValue
        )
    }
    catch {
        try {
            & msg.exe * "$Title`r`n`r`n$Message" 2>$null
        }
        catch {
            Write-Host "$Title`n$Message"
        }
    }
}

if (-not (Test-IsAdministrator)) {
    Show-ResultPopup -Title 'Administrator rights required' `
        -Message 'Restart ScriptBox as administrator, then run Configure Lenovo BIOS again.' `
        -Icon Error
    throw 'Administrator rights are required.'
}

$timeStamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$reportFolder = Join-Path $env:ProgramData 'ScriptBox\BIOS'
$reportPath = Join-Path $reportFolder "Lenovo-BIOS-$env:COMPUTERNAME-$timeStamp.txt"
New-Item -Path $reportFolder -ItemType Directory -Force | Out-Null

$WorkflowState = [pscustomobject]@{
    Report = New-Object 'System.Collections.Generic.List[string]'
    Results = New-Object 'System.Collections.Generic.List[object]'
    HadWarnings = $false
    FatalError = $false
    Completed = $false
    ProfileName = 'Lenovo exact-match compatibility profile'
    ChangedCount = 0
    AlreadyCorrectCount = 0
    DisplayedReportPath = $reportPath
}

function Add-ReportLine {
    param([AllowEmptyString()][string]$Text = '')

    $WorkflowState.Report.Add($Text)
    Write-Host $Text
}

function Add-Section {
    param([Parameter(Mandatory = $true)][string]$Title)

    Add-ReportLine ''
    Add-ReportLine ('=' * 78)
    Add-ReportLine $Title
    Add-ReportLine ('=' * 78)
}

function Get-LenovoMethodReturn {
    param([AllowNull()]$Result)

    if ($null -eq $Result) {
        return 'No return value'
    }

    foreach ($propertyName in @('return', 'Return', 'ReturnValue')) {
        $property = $Result.PSObject.Properties |
            Where-Object { $_.Name -ieq $propertyName } |
            Select-Object -First 1
        if ($property) {
            return [string]$property.Value
        }
    }

    return 'No return value'
}

function Get-LenovoSettings {
    return @(
        Get-CimInstance -Namespace 'root\wmi' -ClassName 'Lenovo_BiosSetting' -ErrorAction Stop
    )
}

function ConvertTo-LenovoSettingMap {
    param([Parameter(Mandatory = $true)][object[]]$Settings)

    $map = @{}
    foreach ($setting in $Settings) {
        $currentSetting = [string]$setting.CurrentSetting
        if ([string]::IsNullOrWhiteSpace($currentSetting)) {
            continue
        }

        $pair = $currentSetting.Split(',', 2)
        $name = $pair[0].Trim()
        $value = if ($pair.Count -gt 1) { $pair[1].Trim() } else { '' }
        if (-not [string]::IsNullOrWhiteSpace($name)) {
            $map[$name] = $value
        }
    }
    return $map
}

function Find-LenovoSettingExact {
    param(
        [Parameter(Mandatory = $true)][hashtable]$SettingMap,
        [Parameter(Mandatory = $true)][string[]]$Aliases
    )

    foreach ($alias in $Aliases) {
        $match = $SettingMap.Keys |
            Where-Object { [string]::Equals([string]$_, $alias, [StringComparison]::OrdinalIgnoreCase) } |
            Select-Object -First 1
        if ($match) {
            return [string]$match
        }
    }
    return $null
}

function New-LenovoSettingPlan {
    param(
        [Parameter(Mandatory = $true)][string]$Label,
        [Parameter(Mandatory = $true)][string[]]$Aliases,
        [Parameter(Mandatory = $true)][string[]]$Values,
        [bool]$Required = $true
    )

    return [pscustomobject]@{
        Label = $Label
        Aliases = $Aliases
        Values = $Values
        Required = $Required
    }
}

function Add-SettingResult {
    param(
        [Parameter(Mandatory = $true)][string]$Label,
        [AllowNull()][string]$Name,
        [AllowNull()][string]$Before,
        [AllowNull()][string]$Desired,
        [Parameter(Mandatory = $true)][string]$Status
    )

    $WorkflowState.Results.Add([pscustomobject]@{
        Label = $Label
        Name = $Name
        Before = $Before
        Desired = $Desired
        Status = $Status
    })
}

$ComputerSystem = $null
$ComputerProduct = $null
$ComputerBios = $null
$SettingsBefore = @()
$SettingMapBefore = @{}
$SetInterface = $null
$SaveInterface = $null
$OpcodeInterface = $null
$DiscardInterface = $null
$UseOpcodePassword = $false
$AuthenticateForSave = $false
$PasswordState = $null
$SupervisorPasswordSet = $false

function Stage-LenovoSetting {
    param([Parameter(Mandatory = $true)]$Plan)

    $settingName = Find-LenovoSettingExact -SettingMap $SettingMapBefore -Aliases $Plan.Aliases
    if (-not $settingName) {
        $message = "$($Plan.Label): none of the exact firmware setting names were exposed."
        if ($Plan.Required) {
            Add-ReportLine "[WARNING] $message"
            $WorkflowState.HadWarnings = $true
        }
        else {
            Add-ReportLine "[SKIPPED] $message"
        }
        Add-SettingResult -Label $Plan.Label -Name $null -Before $null -Desired $null -Status 'Unavailable'
        return
    }

    $before = [string]$SettingMapBefore[$settingName]
    foreach ($desiredValue in $Plan.Values) {
        if ([string]::Equals($before, $desiredValue, [StringComparison]::OrdinalIgnoreCase)) {
            Add-ReportLine "[OK] $settingName = $before (already correct)"
            Add-SettingResult -Label $Plan.Label -Name $settingName -Before $before `
                -Desired $desiredValue -Status 'AlreadyCorrect'
            $WorkflowState.AlreadyCorrectCount++
            return
        }
    }

    foreach ($desiredValue in $Plan.Values) {
        $command = "$settingName,$desiredValue"
        if (-not $UseOpcodePassword -and $AuthenticateForSave) {
            $command = "$command,$BIOSPassword,ascii,us"
        }

        try {
            $methodResult = Invoke-CimMethod -InputObject $SetInterface `
                -MethodName 'SetBiosSetting' -Arguments @{ parameter = $command } -ErrorAction Stop
            $returnText = Get-LenovoMethodReturn -Result $methodResult
            if ($returnText -ieq 'Success') {
                Add-ReportLine "[STAGED] $settingName : '$before' -> '$desiredValue'"
                Add-SettingResult -Label $Plan.Label -Name $settingName -Before $before `
                    -Desired $desiredValue -Status 'Staged'
                $WorkflowState.ChangedCount++
                return
            }
            if ($returnText -ieq 'Invalid Parameter') {
                continue
            }

            Add-ReportLine "[WARNING] $settingName = '$desiredValue' returned '$returnText'."
            $WorkflowState.HadWarnings = $true
            Add-SettingResult -Label $Plan.Label -Name $settingName -Before $before `
                -Desired $desiredValue -Status "Failed: $returnText"
            return
        }
        catch {
            Add-ReportLine "[WARNING] $settingName = '$desiredValue' failed: $($_.Exception.Message)"
            $WorkflowState.HadWarnings = $true
            Add-SettingResult -Label $Plan.Label -Name $settingName -Before $before `
                -Desired $desiredValue -Status "Failed: $($_.Exception.Message)"
            return
        }
    }

    Add-ReportLine "[WARNING] $settingName exists, but none of the profile values were accepted."
    $WorkflowState.HadWarnings = $true
    Add-SettingResult -Label $Plan.Label -Name $settingName -Before $before `
        -Desired ($Plan.Values -join ' / ') -Status 'No accepted value'
}

function Invoke-LenovoDiscardBestEffort {
    if ($null -eq $DiscardInterface) {
        return
    }

    try {
        if (-not $UseOpcodePassword -and $AuthenticateForSave) {
            [void](Invoke-CimMethod -InputObject $DiscardInterface -MethodName 'DiscardBiosSettings' `
                -Arguments @{ parameter = "$BIOSPassword,ascii,us" } -ErrorAction Stop)
        }
        else {
            [void](Invoke-CimMethod -InputObject $DiscardInterface -MethodName 'DiscardBiosSettings' `
                -ErrorAction Stop)
        }
        Add-ReportLine '[INFO] Staged BIOS changes were discarded after the save failure.'
    }
    catch {
        Add-ReportLine "[WARNING] Staged BIOS changes could not be discarded automatically: $($_.Exception.Message)"
        $WorkflowState.HadWarnings = $true
    }
}

try {
    Add-Section 'LENOVO BIOS CONFIGURATION REPORT'
    Add-ReportLine "Computer name : $env:COMPUTERNAME"
    Add-ReportLine "Run time      : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    Add-ReportLine "Run by        : $env:USERDOMAIN\$env:USERNAME"
    Add-ReportLine "Report path   : $reportPath"

    $ComputerSystem = Get-CimInstance -ClassName 'Win32_ComputerSystem' -ErrorAction Stop
    $ComputerProduct = Get-CimInstance -ClassName 'Win32_ComputerSystemProduct' -ErrorAction Stop
    $ComputerBios = Get-CimInstance -ClassName 'Win32_BIOS' -ErrorAction Stop

    Add-Section 'SYSTEM IDENTITY'
    Add-ReportLine "Manufacturer  : $($ComputerSystem.Manufacturer)"
    Add-ReportLine "Model         : $($ComputerSystem.Model)"
    Add-ReportLine "System family : $($ComputerSystem.SystemFamily)"
    Add-ReportLine "Product name  : $($ComputerProduct.Name)"
    Add-ReportLine "Product ver.  : $($ComputerProduct.Version)"
    Add-ReportLine "Serial number : $($ComputerBios.SerialNumber)"
    Add-ReportLine "BIOS version  : $($ComputerBios.SMBIOSBIOSVersion)"

    if ([string]$ComputerSystem.Manufacturer -notmatch '(?i)Lenovo') {
        throw "This script only changes Lenovo firmware. Detected manufacturer: '$($ComputerSystem.Manufacturer)'."
    }

    $identityText = @(
        [string]$ComputerSystem.Model,
        [string]$ComputerSystem.SystemFamily,
        [string]$ComputerProduct.Name,
        [string]$ComputerProduct.Version
    ) -join ' '
    $m710qMachineTypes = @('10MQ', '10MR', '10MS', '10MT', '10N3', '10QR', '10YC')
    $IsM710q = $identityText -match '(?i)\bM710q\b'
    if (-not $IsM710q) {
        foreach ($machineType in $m710qMachineTypes) {
            if ($identityText -match "(?i)\b$machineType[A-Z0-9]*\b") {
                $IsM710q = $true
                break
            }
        }
    }

    if ($IsM710q) {
        $WorkflowState.ProfileName = 'ThinkCentre M710q Tiny WOL/KVM profile'
        Add-ReportLine '[OK] ThinkCentre M710q Tiny detected; the verified M710q profile will be used.'
    }
    else {
        Add-ReportLine '[INFO] This is not an M710q. Only exact setting names exposed by this Lenovo firmware will be used.'
    }

    Add-Section 'LENOVO WMI CAPABILITIES AND PASSWORD STATE'
    $SettingsBefore = Get-LenovoSettings
    if ($SettingsBefore.Count -eq 0) {
        throw 'Lenovo_BiosSetting returned no firmware settings. Update the BIOS and verify Lenovo WMI support.'
    }
    $SettingMapBefore = ConvertTo-LenovoSettingMap -Settings $SettingsBefore
    Add-ReportLine "[OK] Read $($SettingMapBefore.Count) Lenovo BIOS settings from root\wmi."

    $SetInterface = Get-CimInstance -Namespace 'root\wmi' -ClassName 'Lenovo_SetBiosSetting' -ErrorAction Stop
    $SaveInterface = Get-CimInstance -Namespace 'root\wmi' -ClassName 'Lenovo_SaveBiosSettings' -ErrorAction Stop
    $DiscardInterface = Get-CimInstance -Namespace 'root\wmi' `
        -ClassName 'Lenovo_DiscardBiosSettings' -ErrorAction SilentlyContinue
    $OpcodeInterface = Get-CimInstance -Namespace 'root\wmi' `
        -ClassName 'Lenovo_WmiOpcodeInterface' -ErrorAction SilentlyContinue
    $UseOpcodePassword = $null -ne $OpcodeInterface

    try {
        $passwordSettings = Get-CimInstance -Namespace 'root\wmi' `
            -ClassName 'Lenovo_BiosPasswordSettings' -ErrorAction Stop |
            Select-Object -First 1
        $PasswordState = [int]$passwordSettings.PasswordState
        $SupervisorPasswordSet = (($PasswordState -band 2) -ne 0)
        Add-ReportLine "Password state : $PasswordState"
        Add-ReportLine "Supervisor pwd : $(if ($SupervisorPasswordSet) { 'Configured' } else { 'Not reported as configured' })"
    }
    catch {
        $PasswordState = $null
        Add-ReportLine "[WARNING] Lenovo password state could not be read: $($_.Exception.Message)"
        $WorkflowState.HadWarnings = $true
    }

    if ($SupervisorPasswordSet -and [string]::IsNullOrWhiteSpace($BIOSPassword)) {
        throw 'A Lenovo supervisor password is configured. Run the card again and enter that BIOS setup password.'
    }

    $AuthenticateForSave = $SupervisorPasswordSet -or
        (($null -eq $PasswordState) -and -not [string]::IsNullOrWhiteSpace($BIOSPassword))

    if ($UseOpcodePassword) {
        Add-ReportLine '[OK] Lenovo_WmiOpcodeInterface is available; current Lenovo password handling will be used if needed.'
    }
    else {
        Add-ReportLine '[INFO] Lenovo_WmiOpcodeInterface is unavailable; legacy ASCII password handling will be used if needed.'
    }
    if (-not $AuthenticateForSave -and -not [string]::IsNullOrWhiteSpace($BIOSPassword)) {
        Add-ReportLine '[INFO] A password was supplied, but firmware reports no supervisor password; the supplied value will not be sent.'
    }

    Add-Section "SETTINGS PROFILE: $($WorkflowState.ProfileName)"
    $settingPlan = @(
        (New-LenovoSettingPlan -Label 'Onboard wired Ethernet' `
            -Aliases @('Onboard Ethernet Controller', 'Ethernet LAN', 'Internal Network Device') `
            -Values @('Enabled', 'Enable')),
        (New-LenovoSettingPlan -Label 'Wake-on-LAN' `
            -Aliases @('Wake on LAN', 'WakeOnLAN') `
            -Values @('Primary', 'Automatic', 'Enabled', 'Enable')),
        (New-LenovoSettingPlan -Label 'Enhanced Power Saving Mode' `
            -Aliases @('Enhanced Power Saving Mode') `
            -Values @('Disabled', 'Disable')),
        (New-LenovoSettingPlan -Label 'Smart Power On from USB keyboard' `
            -Aliases @('Smart Power On', 'PowerOnFromKeyboard', 'KeyboardPowerOn') `
            -Values @('Enabled', 'Enable')),
        (New-LenovoSettingPlan -Label 'Power on after AC power is restored' `
            -Aliases @('After Power Loss', 'AfterPowerLoss', 'ACPowerRecovery', 'RestoreOnACPowerLoss') `
            -Values @('Power On', 'PowerOn', 'On')),
        (New-LenovoSettingPlan -Label 'USB controller support' `
            -Aliases @('USB Support') `
            -Values @('Enabled', 'Enable')),
        (New-LenovoSettingPlan -Label 'USB keyboard/mouse legacy support' `
            -Aliases @('USB Legacy Support', 'USBLegacySupport') `
            -Values @('Enabled', 'Enable')),
        (New-LenovoSettingPlan -Label 'Front USB ports' `
            -Aliases @('Front USB Ports') `
            -Values @('Enabled', 'Enable') -Required $IsM710q),
        (New-LenovoSettingPlan -Label 'Rear USB ports' `
            -Aliases @('Rear USB Ports') `
            -Values @('Enabled', 'Enable') -Required $IsM710q)
    )

    foreach ($planItem in $settingPlan) {
        Stage-LenovoSetting -Plan $planItem
    }

    if ($WorkflowState.ChangedCount -gt 0) {
        Add-Section 'SAVE LENOVO BIOS SETTINGS'
        try {
            if ($UseOpcodePassword -and $AuthenticateForSave) {
                $opcodeResult = Invoke-CimMethod -InputObject $OpcodeInterface `
                    -MethodName 'WmiOpcodeInterface' `
                    -Arguments @{ Parameter = "WmiOpcodePasswordAdmin:$BIOSPassword;" } `
                    -ErrorAction Stop
                $opcodeReturn = Get-LenovoMethodReturn -Result $opcodeResult
                if ($opcodeReturn -notin @('Success', 'No return value')) {
                    throw "Lenovo password authentication returned '$opcodeReturn'."
                }
                Add-ReportLine '[OK] Lenovo accepted the supervisor-password authentication request.'
            }

            if (-not $UseOpcodePassword -and $AuthenticateForSave) {
                $saveResult = Invoke-CimMethod -InputObject $SaveInterface `
                    -MethodName 'SaveBiosSettings' `
                    -Arguments @{ parameter = "$BIOSPassword,ascii,us" } -ErrorAction Stop
            }
            else {
                $saveResult = Invoke-CimMethod -InputObject $SaveInterface `
                    -MethodName 'SaveBiosSettings' -ErrorAction Stop
            }

            $saveReturn = Get-LenovoMethodReturn -Result $saveResult
            if ($saveReturn -ine 'Success') {
                throw "SaveBiosSettings returned '$saveReturn'."
            }
            Add-ReportLine "[SUCCESS] Saved $($WorkflowState.ChangedCount) staged Lenovo BIOS change(s) in one operation."
        }
        catch {
            Add-ReportLine "[ERROR] Lenovo BIOS changes could not be saved: $($_.Exception.Message)"
            Invoke-LenovoDiscardBestEffort
            throw
        }
    }
    else {
        Add-ReportLine '[OK] No BIOS save was needed because every available target was already correct or unsupported.'
    }

    Add-Section 'READBACK VERIFICATION'
    $settingsAfter = Get-LenovoSettings
    $settingMapAfter = ConvertTo-LenovoSettingMap -Settings $settingsAfter
    foreach ($resultItem in $WorkflowState.Results) {
        if ($resultItem.Status -notin @('Staged', 'AlreadyCorrect') -or
            [string]::IsNullOrWhiteSpace([string]$resultItem.Name)) {
            continue
        }

        $afterName = Find-LenovoSettingExact -SettingMap $settingMapAfter -Aliases @([string]$resultItem.Name)
        $afterValue = if ($afterName) { [string]$settingMapAfter[$afterName] } else { '<not returned>' }
        if ([string]::Equals($afterValue, [string]$resultItem.Desired, [StringComparison]::OrdinalIgnoreCase)) {
            Add-ReportLine "[VERIFIED] $($resultItem.Name) = $afterValue"
        }
        elseif ($resultItem.Status -eq 'Staged') {
            Add-ReportLine "[WARNING] $($resultItem.Name) readback is '$afterValue'; requested '$($resultItem.Desired)'. A restart may be required before firmware reports the new value."
            $WorkflowState.HadWarnings = $true
        }
        else {
            Add-ReportLine "[WARNING] $($resultItem.Name) readback is '$afterValue'; expected '$($resultItem.Desired)'."
            $WorkflowState.HadWarnings = $true
        }
    }

    Add-Section 'ALL LENOVO BIOS SETTINGS AFTER CONFIGURATION'
    foreach ($settingName in @($settingMapAfter.Keys | Sort-Object)) {
        Add-ReportLine ("{0}`t{1}" -f $settingName, $settingMapAfter[$settingName])
    }

    Add-Section 'FINAL STATUS'
    Add-ReportLine "Profile        : $($WorkflowState.ProfileName)"
    Add-ReportLine "Staged/saved   : $($WorkflowState.ChangedCount)"
    Add-ReportLine "Already correct: $($WorkflowState.AlreadyCorrectCount)"
    if ($WorkflowState.HadWarnings) {
        Add-ReportLine 'Completed with one or more warnings. Review the report before relying on WOL or USB power-on.'
    }
    else {
        Add-ReportLine 'Completed successfully.'
    }
    Add-ReportLine 'Restart the PC once before testing Wake-on-LAN or Smart Power On.'
    $WorkflowState.Completed = $true
}
catch {
    $WorkflowState.FatalError = $true
    Add-Section 'FATAL ERROR'
    Add-ReportLine ([string]$_.Exception.Message)
    if (-not [string]::IsNullOrWhiteSpace([string]$_.ScriptStackTrace)) {
        Add-ReportLine ([string]$_.ScriptStackTrace)
    }
}
finally {
    try {
        [IO.File]::WriteAllLines(
            $reportPath,
            $WorkflowState.Report,
            (New-Object Text.UTF8Encoding($false))
        )
    }
    catch {
        Write-Warning "The Lenovo BIOS report could not be written: $($_.Exception.Message)"
    }

    try {
        $desktopFolder = [Environment]::GetFolderPath('Desktop')
        if (-not [string]::IsNullOrWhiteSpace($desktopFolder) -and (Test-Path -LiteralPath $desktopFolder)) {
            $desktopReportPath = Join-Path $desktopFolder (Split-Path -Leaf $reportPath)
            Copy-Item -LiteralPath $reportPath -Destination $desktopReportPath -Force
            $WorkflowState.DisplayedReportPath = $desktopReportPath
        }
    }
    catch {
        $WorkflowState.DisplayedReportPath = $reportPath
    }

    if ($WorkflowState.FatalError) {
        Show-ResultPopup -Title 'Lenovo BIOS setup failed' `
            -Message ("The script stopped before completing.`r`n`r`nReport:`r`n$($WorkflowState.DisplayedReportPath)") `
            -Icon Error
    }
    elseif ($WorkflowState.HadWarnings) {
        Show-ResultPopup -Title 'Lenovo BIOS setup completed with warnings' `
            -Message (
                "Profile: $($WorkflowState.ProfileName)`r`n" +
                "Saved changes: $($WorkflowState.ChangedCount)`r`n`r`n" +
                "Restart the PC once, then review any warnings before testing WOL.`r`n`r`n" +
                "Report:`r`n$($WorkflowState.DisplayedReportPath)"
            ) -Icon Warning
    }
    else {
        Show-ResultPopup -Title 'Lenovo BIOS setup complete' `
            -Message (
                "Profile: $($WorkflowState.ProfileName)`r`n" +
                "Saved changes: $($WorkflowState.ChangedCount)`r`n" +
                "Already correct: $($WorkflowState.AlreadyCorrectCount)`r`n`r`n" +
                "Restart the PC once before testing WOL or Smart Power On.`r`n`r`n" +
                "Report:`r`n$($WorkflowState.DisplayedReportPath)"
            ) -Icon Information
    }
}

if ($WorkflowState.FatalError) {
    throw 'Lenovo BIOS setup failed. See the generated report for details.'
}
