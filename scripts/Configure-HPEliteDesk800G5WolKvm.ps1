#Requires -Version 5.1
<#
.SYNOPSIS
    Configures an HP EliteDesk 800 G3 or G5 Desktop Mini for JetKVM and
    Wake-on-LAN.

.DESCRIPTION
    Verifies the supported HP model family before making changes, configures
    the available BIOS settings by their exact HP names, disables Windows Fast
    Startup, enables supported Wake-on-LAN settings on physical wired
    adapters, arms the selected adapter with Powercfg, exports a detailed
    report, and shows the selected MAC address in colon notation.

    Supported models are HP EliteDesk 800 G3 and G5 Desktop Mini systems,
    including their 35W and 65W variants. A BIOS setting that is not exposed by
    a particular model is reported as a warning and is not guessed or forced.

    The script does not restart the computer or network adapters. Restart the
    computer once after completion so pending BIOS and driver settings apply.

.PARAMETER BiosPassword
    Optional HP BIOS administrator password. Leave blank when no BIOS password
    is configured.
#>

[CmdletBinding()]
param(
    [string]$BiosPassword = ''
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
        [Parameter(Mandatory = $true)]
        [string]$Title,

        [Parameter(Mandatory = $true)]
        [string]$Message,

        [ValidateSet('Information', 'Warning', 'Error')]
        [string]$Icon = 'Information'
    )

    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        $iconValue = switch ($Icon) {
            'Warning' { [Windows.Forms.MessageBoxIcon]::Warning }
            'Error'   { [Windows.Forms.MessageBoxIcon]::Error }
            default   { [Windows.Forms.MessageBoxIcon]::Information }
        }
        [void][Windows.Forms.MessageBox]::Show(
            $Message,
            $Title,
            [Windows.Forms.MessageBoxButtons]::OK,
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

function ConvertTo-ColonMac {
    param(
        [AllowNull()]
        [string]$MacAddress
    )

    if ([string]::IsNullOrWhiteSpace($MacAddress)) {
        return $null
    }

    $clean = ($MacAddress -replace '[^0-9A-Fa-f]', '').ToUpperInvariant()
    if ($clean.Length -ne 12) {
        return $MacAddress
    }

    return [regex]::Replace($clean, '(.{2})(?=.)', '$1:')
}

# Read-only preflight. A different model exits before creating a report folder
# or applying any BIOS, Windows, adapter, or Powercfg changes.
try {
    if (-not (Test-IsAdministrator)) {
        throw 'Run this script with administrator rights.'
    }

    $ComputerSystem = Get-CimInstance -ClassName Win32_ComputerSystem
    $ComputerBios = Get-CimInstance -ClassName Win32_BIOS
    $ComputerProduct = Get-CimInstance -ClassName Win32_ComputerSystemProduct
    $IsHp = [string]$ComputerSystem.Manufacturer -match '^(HP|Hewlett-Packard)'
    # HP uses both "Desktop Mini" and "DM" in G3/G5 model strings, and the
    # official product names can include a 35W or 65W marker. Require the exact
    # EliteDesk 800 family, a supported generation, and the Mini form factor.
    $SupportedModelPattern = '^HP\s+EliteDesk\s+800\b(?=.*\bG(?:3|5)\b)(?=.*\b(?:Desktop\s+Mini|DM)\b).*$'
    $IsSupportedModel = ([string]$ComputerSystem.Model).Trim() -match $SupportedModelPattern

    if (-not $IsHp -or -not $IsSupportedModel) {
        throw "This script is restricted to HP EliteDesk 800 G3 or G5 Desktop Mini systems (including 35W and 65W variants). Detected manufacturer/model: '$($ComputerSystem.Manufacturer) $($ComputerSystem.Model)'. No changes were made."
    }
}
catch {
    Show-ResultPopup `
        -Title 'HP G3/G5 Mini WOL/KVM preflight failed' `
        -Message $_.Exception.Message `
        -Icon Error
    Write-Host "[ERROR] $($_.Exception.Message)"
    throw
}

$TimeStamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$ReportFolder = Join-Path $env:ProgramData 'RevHooks\HP-WOL-KVM'
$ReportPath = Join-Path $ReportFolder "HP-WOL-KVM-$env:COMPUTERNAME-$TimeStamp.txt"
$Report = New-Object System.Collections.Generic.List[string]
$HadWarnings = $false
$FatalError = $false
$FatalException = $null
$MacForWol = $null
$DesktopReportPath = $null

function Add-ReportLine {
    param(
        [AllowEmptyString()]
        [string]$Text = ''
    )

    $script:Report.Add($Text)
    Write-Host $Text
}

function Add-Section {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Title
    )

    Add-ReportLine ''
    Add-ReportLine ('=' * 78)
    Add-ReportLine $Title
    Add-ReportLine ('=' * 78)
}

function Get-HpCurrentValue {
    param(
        [Parameter(Mandatory = $true)]
        $Setting
    )

    $rawValue = [string]$Setting.Value
    $selected = @($rawValue -split ',' | ForEach-Object {
        $_.Trim()
    } | Where-Object {
        $_.StartsWith('*')
    }) | Select-Object -First 1

    if ($selected) {
        return $selected.TrimStart('*').Trim()
    }

    return $rawValue
}

$HpReturnCodes = @{
    0 = 'Success'
    1 = 'Not supported'
    2 = 'Unspecified error'
    3 = 'Timeout'
    4 = 'Failed'
    5 = 'Invalid parameter'
    6 = 'Access denied'
}

try {
    New-Item -Path $ReportFolder -ItemType Directory -Force | Out-Null

    Add-Section 'HP WOL AND JETKVM CONFIGURATION REPORT'
    Add-ReportLine "Computer name : $env:COMPUTERNAME"
    Add-ReportLine "Run time      : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    Add-ReportLine "Run by        : $env:USERDOMAIN\$env:USERNAME"
    Add-ReportLine "Report path   : $ReportPath"

    Add-Section 'SYSTEM IDENTITY'
    Add-ReportLine "Manufacturer  : $($ComputerSystem.Manufacturer)"
    Add-ReportLine "Model         : $($ComputerSystem.Model)"
    Add-ReportLine "Serial number : $($ComputerBios.SerialNumber)"
    Add-ReportLine "BIOS version  : $($ComputerBios.SMBIOSBIOSVersion)"
    Add-ReportLine "System UUID   : $($ComputerProduct.UUID)"

    $BiosNamespace = 'root\HP\InstrumentedBIOS'
    $script:HpBiosSettings = @(
        Get-CimInstance -Namespace $BiosNamespace -ClassName HP_BIOSSetting
    )
    $HpBiosInterface = Get-CimInstance `
        -Namespace $BiosNamespace `
        -ClassName HP_BIOSSettingInterface
    $WmiPassword = if ([string]::IsNullOrEmpty($BiosPassword)) {
        ''
    }
    else {
        "<utf-16/>$BiosPassword"
    }

    Add-Section 'HP BIOS CHANGES'

    function Set-HpRequiredBiosSetting {
        param(
            [Parameter(Mandatory = $true)]
            [string]$Name,

            [Parameter(Mandatory = $true)]
            [string]$DesiredValue
        )

        $setting = $script:HpBiosSettings |
            Where-Object Name -EQ $Name |
            Select-Object -First 1

        if (-not $setting) {
            Add-ReportLine "[WARNING] BIOS setting is unavailable: $Name"
            $script:HadWarnings = $true
            return
        }

        $before = Get-HpCurrentValue -Setting $setting
        if ($before -eq $DesiredValue) {
            Add-ReportLine "[OK] $Name = $DesiredValue (already correct)"
            return
        }

        try {
            $result = Invoke-CimMethod `
                -InputObject $HpBiosInterface `
                -MethodName SetBIOSSetting `
                -Arguments @{
                    Name     = $Name
                    Value    = $DesiredValue
                    Password = $WmiPassword
                }

            $returnCode = $null
            foreach ($propertyName in @('ReturnValue', 'Return', 'return')) {
                if ($result.PSObject.Properties.Name -contains $propertyName) {
                    $returnCode = [int]$result.$propertyName
                    break
                }
            }

            $script:HpBiosSettings = @(
                Get-CimInstance -Namespace $BiosNamespace -ClassName HP_BIOSSetting
            )
            $afterSetting = $script:HpBiosSettings |
                Where-Object Name -EQ $Name |
                Select-Object -First 1
            $after = if ($afterSetting) {
                Get-HpCurrentValue -Setting $afterSetting
            }
            else {
                '<unable to read>'
            }
            $description = if (
                $null -ne $returnCode -and
                $HpReturnCodes.ContainsKey($returnCode)
            ) {
                $HpReturnCodes[$returnCode]
            }
            elseif ($null -ne $returnCode) {
                "Return code $returnCode"
            }
            else {
                'No return code supplied'
            }

            if (
                ($null -eq $returnCode -and $after -eq $DesiredValue) -or
                $returnCode -eq 0
            ) {
                Add-ReportLine "[CHANGED] $Name : '$before' -> '$after' ($description)"
            }
            else {
                Add-ReportLine "[FAILED] $Name : requested '$DesiredValue'; current '$after' ($description)"
                $script:HadWarnings = $true
            }
        }
        catch {
            Add-ReportLine "[FAILED] $Name : $($_.Exception.Message)"
            $script:HadWarnings = $true
        }
    }

    # These exact HP names and values come from the supplied EliteDesk 800 G5
    # Desktop Mini BIOS export. G3 settings that are unavailable are recorded
    # as warnings by Set-HpRequiredBiosSetting and are never guessed or forced.
    $RequiredBiosSettings = [ordered]@{
        'Fast Boot'                            = 'Disable'
        'Front USB Ports'                      = 'Enable'
        'Rear USB Ports'                       = 'Enable'
        'USB Legacy Port Charging'             = 'Enable'
        'Front USB Type-C Downstream Charging' = 'Enable'
        'Restrict USB Devices'                 = 'Allow all USB Devices'
        'Power On from Keyboard Ports'         = 'Enable'
        'Embedded LAN controller'              = 'Enable'
        'Wake On LAN'                          = 'Boot to Hard Drive'
        'Wake on LAN Power-on Password Policy' = 'Bypass Password'
        'S5 Maximum Power Savings'             = 'Disable'
        'After Power Loss'                     = 'Power On'
    }

    foreach ($entry in $RequiredBiosSettings.GetEnumerator()) {
        Set-HpRequiredBiosSetting -Name $entry.Key -DesiredValue $entry.Value
    }

    Add-Section 'WINDOWS FAST STARTUP'
    $PowerRegistryPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power'
    New-ItemProperty `
        -Path $PowerRegistryPath `
        -Name 'HiberbootEnabled' `
        -PropertyType DWord `
        -Value 0 `
        -Force | Out-Null
    $FastStartupValue = (
        Get-ItemProperty -Path $PowerRegistryPath -Name 'HiberbootEnabled'
    ).HiberbootEnabled
    if ($FastStartupValue -eq 0) {
        Add-ReportLine '[CHANGED/OK] Windows Fast Startup is disabled.'
    }
    else {
        Add-ReportLine '[FAILED] Windows Fast Startup could not be disabled.'
        $HadWarnings = $true
    }

    Add-Section 'WIRED ETHERNET ADAPTERS'
    $WiredAdapters = @(
        Get-NetAdapter -Physical |
            Where-Object {
                $adapterText = "$($_.Name) $($_.InterfaceDescription)"
                $_.HardwareInterface -and
                $adapterText -notmatch 'Wi-?Fi|Wireless|802\.11|Bluetooth|WWAN|Mobile Broadband'
            } |
            Sort-Object `
                @{ Expression = { if ($_.Status -eq 'Up') { 0 } else { 1 } } },
                ifIndex
    )

    if ($WiredAdapters.Count -eq 0) {
        Add-ReportLine '[FAILED] No physical wired Ethernet adapter was found.'
        $HadWarnings = $true
    }

    foreach ($adapter in $WiredAdapters) {
        $formattedMac = ConvertTo-ColonMac -MacAddress $adapter.MacAddress
        Add-ReportLine ''
        Add-ReportLine "Adapter       : $($adapter.Name)"
        Add-ReportLine "Description   : $($adapter.InterfaceDescription)"
        Add-ReportLine "Status        : $($adapter.Status)"
        Add-ReportLine "MAC address   : $formattedMac"
        Add-ReportLine "Interface ID  : $($adapter.ifIndex)"

        try {
            $powerManagement = Get-NetAdapterPowerManagement `
                -Name $adapter.Name `
                -ErrorAction Stop
            $powerParameters = @{
                Name        = $adapter.Name
                NoRestart   = $true
                ErrorAction = 'Stop'
            }
            if (
                $null -ne $powerManagement.WakeOnMagicPacket -and
                [string]$powerManagement.WakeOnMagicPacket -ne 'Unsupported'
            ) {
                $powerParameters.WakeOnMagicPacket = 'Enabled'
            }
            if (
                $null -ne $powerManagement.WakeOnPattern -and
                [string]$powerManagement.WakeOnPattern -ne 'Unsupported'
            ) {
                $powerParameters.WakeOnPattern = 'Disabled'
            }

            if ($powerParameters.Count -gt 3) {
                Set-NetAdapterPowerManagement @powerParameters
                Add-ReportLine '[CHANGED/OK] Windows adapter power management configured without restarting the adapter.'
            }
            else {
                Add-ReportLine '[WARNING] Adapter exposes no configurable WOL power-management options.'
                $HadWarnings = $true
            }
        }
        catch {
            Add-ReportLine "[WARNING] Adapter power-management cmdlet: $($_.Exception.Message)"
            $HadWarnings = $true
        }

        try {
            $advancedProperties = @(
                Get-NetAdapterAdvancedProperty `
                    -Name $adapter.Name `
                    -AllProperties `
                    -ErrorAction Stop
            )
            foreach ($property in $advancedProperties) {
                $displayName = [string]$property.DisplayName
                $keyword = [string]$property.RegistryKeyword
                $enableProperty = (
                    $displayName -match '(?i)wake.*magic|magic.*wake|shutdown.*wake.*lan|wake.*shutdown|wake.*from.*s5|s5.*wake.*lan|enable\s*pme|pme\s*enable' -or
                    $keyword -match '(?i)^\*?WakeOnMagicPacket$|EnablePME|ShutdownWakeOnLan|S5WakeOnLan'
                )
                $disableProperty = (
                    $displayName -match '(?i)wake.*pattern' -or
                    $keyword -match '(?i)^\*?WakeOnPattern$'
                )
                if (-not $enableProperty -and -not $disableProperty) {
                    continue
                }

                $validDisplayValues = @()
                if ($property.PSObject.Properties.Name -contains 'ValidDisplayValues') {
                    $validDisplayValues = @($property.ValidDisplayValues)
                }
                $desiredDisplayValue = if ($enableProperty) {
                    $validDisplayValues |
                        Where-Object { $_ -match '(?i)^(enabled|enable|on|yes)$' } |
                        Select-Object -First 1
                }
                else {
                    $validDisplayValues |
                        Where-Object { $_ -match '(?i)^(disabled|disable|off|no)$' } |
                        Select-Object -First 1
                }

                if ($desiredDisplayValue) {
                    Set-NetAdapterAdvancedProperty `
                        -Name $adapter.Name `
                        -RegistryKeyword $property.RegistryKeyword `
                        -DisplayValue $desiredDisplayValue `
                        -NoRestart `
                        -ErrorAction Stop
                    Add-ReportLine "[CHANGED/OK] Advanced property '$displayName' = '$desiredDisplayValue' without restarting the adapter."
                }
                elseif (-not [string]::IsNullOrWhiteSpace($property.RegistryKeyword)) {
                    $desiredRegistryValue = if ($enableProperty) { '1' } else { '0' }
                    Set-NetAdapterAdvancedProperty `
                        -Name $adapter.Name `
                        -RegistryKeyword $property.RegistryKeyword `
                        -RegistryValue $desiredRegistryValue `
                        -NoRestart `
                        -ErrorAction Stop
                    Add-ReportLine "[CHANGED/OK] Advanced property '$displayName' = registry value '$desiredRegistryValue' without restarting the adapter."
                }
            }
        }
        catch {
            Add-ReportLine "[WARNING] Advanced WOL properties: $($_.Exception.Message)"
            $HadWarnings = $true
        }

        $PowerCfgSucceeded = $false
        $powerCfgOutput = @()
        $WakeProgrammableNames = @(
            & powercfg.exe /devicequery wake_programmable 2>$null
        )
        $MatchedWakeNames = @(
            $WakeProgrammableNames | Where-Object {
                $_ -eq $adapter.InterfaceDescription -or
                $_ -like "*$($adapter.InterfaceDescription)*"
            }
        )
        $PowerCfgCandidates = @(
            $MatchedWakeNames
            $adapter.InterfaceDescription
            $adapter.Name
        ) | Where-Object {
            -not [string]::IsNullOrWhiteSpace($_)
        } | Select-Object -Unique

        foreach ($deviceName in $PowerCfgCandidates) {
            $powerCfgOutput = @(& powercfg.exe /deviceenablewake "$deviceName" 2>&1)
            if ($LASTEXITCODE -eq 0) {
                Add-ReportLine "[CHANGED/OK] POWERCFG armed '$deviceName' to wake Windows."
                $PowerCfgSucceeded = $true
                break
            }
        }
        if (-not $PowerCfgSucceeded) {
            Add-ReportLine '[WARNING] POWERCFG could not arm this adapter by its reported names.'
            if ($powerCfgOutput.Count -gt 0) {
                Add-ReportLine "          $($powerCfgOutput -join ' ')"
            }
            $HadWarnings = $true
        }
    }

    if ($WiredAdapters.Count -gt 0) {
        $PrimaryAdapter = $WiredAdapters |
            Sort-Object `
                @{ Expression = { if ($_.Status -eq 'Up') { 0 } else { 1 } } },
                ifIndex |
            Select-Object -First 1
        $MacForWol = ConvertTo-ColonMac -MacAddress $PrimaryAdapter.MacAddress

        Add-Section 'WAKE-ON-LAN MAC ADDRESS'
        Add-ReportLine 'Use this MAC address in JetKVM:'
        Add-ReportLine ''
        Add-ReportLine "    $MacForWol"
        Add-ReportLine ''
        Add-ReportLine "Selected adapter: $($PrimaryAdapter.InterfaceDescription)"
        Add-ReportLine "Adapter status  : $($PrimaryAdapter.Status)"
        try {
            Set-Clipboard -Value $MacForWol -ErrorAction Stop
            Add-ReportLine 'The MAC address was copied to the clipboard.'
        }
        catch {
            Add-ReportLine '[WARNING] The MAC address could not be copied to the clipboard.'
            $HadWarnings = $true
        }
    }

    Add-Section 'WINDOWS WOL VERIFICATION'
    foreach ($adapter in $WiredAdapters) {
        Add-ReportLine ''
        Add-ReportLine "Adapter: $($adapter.Name)"
        try {
            $powerAfter = Get-NetAdapterPowerManagement `
                -Name $adapter.Name `
                -ErrorAction Stop
            Add-ReportLine "WakeOnMagicPacket : $($powerAfter.WakeOnMagicPacket)"
            Add-ReportLine "WakeOnPattern     : $($powerAfter.WakeOnPattern)"
        }
        catch {
            Add-ReportLine "Power management readback failed: $($_.Exception.Message)"
        }

        try {
            $wolPropertiesAfter = @(
                Get-NetAdapterAdvancedProperty `
                    -Name $adapter.Name `
                    -AllProperties `
                    -ErrorAction Stop |
                    Where-Object {
                        $_.DisplayName -match '(?i)wake|magic|shutdown|pme' -or
                        $_.RegistryKeyword -match '(?i)wake|magic|pme'
                    }
            )
            foreach ($property in $wolPropertiesAfter) {
                Add-ReportLine (
                    'Advanced: {0} = {1} [{2}]' -f
                    $property.DisplayName,
                    $property.DisplayValue,
                    $property.RegistryKeyword
                )
            }
        }
        catch {
            Add-ReportLine "Advanced property readback failed: $($_.Exception.Message)"
        }
    }

    Add-ReportLine ''
    Add-ReportLine 'Devices currently armed to wake Windows:'
    $WakeArmedDevices = @(& powercfg.exe /devicequery wake_armed 2>&1)
    if ($WakeArmedDevices.Count -gt 0) {
        foreach ($device in $WakeArmedDevices) {
            Add-ReportLine "  $device"
        }
    }
    else {
        Add-ReportLine '  <none reported>'
    }

    Add-Section 'ALL HP BIOS SETTINGS AFTER CONFIGURATION'
    $AllBiosSettingsAfter = @(
        Get-CimInstance `
            -Namespace $BiosNamespace `
            -ClassName HP_BIOSSetting |
            Sort-Object Name
    )
    foreach ($setting in $AllBiosSettingsAfter) {
        Add-ReportLine ("{0}`t{1}" -f $setting.Name, $setting.Value)
    }

    Add-Section 'FINAL STATUS'
    if ($HadWarnings) {
        Add-ReportLine 'Completed with one or more warnings.'
    }
    else {
        Add-ReportLine 'Completed successfully.'
    }
    Add-ReportLine 'Restart the PC once before performing the final shutdown/WOL test.'
}
catch {
    $FatalError = $true
    $FatalException = $_.Exception
    Add-Section 'FATAL ERROR'
    Add-ReportLine ([string]$_.Exception.Message)
    Add-ReportLine ([string]$_.ScriptStackTrace)
}
finally {
    try {
        [IO.File]::WriteAllLines(
            $ReportPath,
            $Report,
            (New-Object Text.UTF8Encoding($false))
        )
    }
    catch {
        Write-Host "[WARNING] The report could not be written: $($_.Exception.Message)"
    }

    try {
        $DesktopFolder = [Environment]::GetFolderPath('Desktop')
        if (
            -not [string]::IsNullOrWhiteSpace($DesktopFolder) -and
            (Test-Path -LiteralPath $DesktopFolder)
        ) {
            $DesktopReportPath = Join-Path $DesktopFolder (Split-Path $ReportPath -Leaf)
            Copy-Item `
                -LiteralPath $ReportPath `
                -Destination $DesktopReportPath `
                -Force
        }
    }
    catch {
        $DesktopReportPath = $null
    }

    $DisplayedReportPath = if ($DesktopReportPath) {
        $DesktopReportPath
    }
    else {
        $ReportPath
    }
    if ($FatalError) {
        Show-ResultPopup `
            -Title 'HP WOL/KVM setup failed' `
            -Message "The script stopped before completing.`r`n`r`nSee the report for details:`r`n$DisplayedReportPath" `
            -Icon Error
    }
    elseif ($HadWarnings) {
        $MacText = if ($MacForWol) {
            "Wake-on-LAN MAC:`r`n$MacForWol`r`n`r`n"
        }
        else {
            ''
        }
        Show-ResultPopup `
            -Title 'HP WOL/KVM setup completed with warnings' `
            -Message "${MacText}Restart the PC once before testing WOL from shutdown.`r`n`r`nReport:`r`n$DisplayedReportPath" `
            -Icon Warning
    }
    else {
        Show-ResultPopup `
            -Title 'HP WOL/KVM setup complete' `
            -Message "Wake-on-LAN MAC:`r`n$MacForWol`r`n`r`nThe MAC address has been copied to the clipboard.`r`n`r`nRestart the PC once before testing WOL from shutdown.`r`n`r`nReport:`r`n$DisplayedReportPath" `
            -Icon Information
    }
}

if ($FatalError) {
    Write-Host "[ERROR] $($FatalException.Message)"
    throw $FatalException
}
elseif ($HadWarnings) {
    Write-Host "[WARNING] HP G3/G5 Mini WOL/KVM setup completed with warnings. Report: $ReportPath"
}
else {
    Write-Host "[SUCCESS] HP G3/G5 Mini WOL/KVM setup completed. Report: $ReportPath"
}
