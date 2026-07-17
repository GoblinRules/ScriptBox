#requires -version 5.1
<#
.SYNOPSIS
  Configures common HP commercial BIOS settings across multiple HP models.
.DESCRIPTION
  - Must run elevated in 64-bit Windows PowerShell.
  - Installs HP Client Management Script Library (HPCMSL) from PowerShell Gallery if absent.
  - Detects the settings and values exposed by the current model.
  - Uses aliases/fallback values because wording varies between HP generations.
  - Logs unsupported settings without failing the entire script.
  - Optional ScriptBox/Action1 variable: $BIOSPassword
#>

[CmdletBinding()]
param(
    [string]$BIOSPassword
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$LogRoot = 'C:\ProgramData\ScriptBox\BIOS'
$LogFile = Join-Path $LogRoot ("HP-BIOS-{0:yyyyMMdd-HHmmss}.log" -f (Get-Date))
New-Item -Path $LogRoot -ItemType Directory -Force | Out-Null

function Write-Log {
    param([string]$Message, [ValidateSet('INFO','SUCCESS','WARN','ERROR','UNSUPPORTED')][string]$Level='INFO')
    $line = '[{0:yyyy-MM-dd HH:mm:ss}] [{1}] {2}' -f (Get-Date), $Level, $Message
    Write-Host $line
    Add-Content -Path $LogFile -Value $line -Encoding UTF8
}

function Test-Administrator {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = [Security.Principal.WindowsPrincipal]::new($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-HighestModuleVersion {
    param([Parameter(Mandatory)][string]$Name)

    $module = Get-Module -ListAvailable -Name $Name |
        Sort-Object Version -Descending |
        Select-Object -First 1
    if ($module) { return [version]$module.Version }
    return [version]'0.0'
}

function Initialize-PowerShellGalleryClient {
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

    if (-not (Get-PackageProvider -Name NuGet -ListAvailable -ErrorAction SilentlyContinue |
        Where-Object { [version]$_.Version -ge [version]'2.8.5.201' })) {
        Write-Log 'Installing the supported NuGet package provider.'
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope AllUsers | Out-Null
    }

    $gallery = Get-PSRepository -Name PSGallery -ErrorAction SilentlyContinue
    if (-not $gallery) {
        Write-Log 'Restoring the default PowerShell Gallery registration.'
        Register-PSRepository -Default
        $gallery = Get-PSRepository -Name PSGallery -ErrorAction Stop
    }
    if ($gallery.InstallationPolicy -ne 'Trusted') {
        Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
    }

    $powerShellGetVersion = Get-HighestModuleVersion -Name PowerShellGet
    if ($powerShellGetVersion -lt [version]'2.2.5') {
        Write-Log "PowerShellGet $powerShellGetVersion cannot read current HP module packages. Installing PowerShellGet 2.2.5."
        Install-Module -Name PowerShellGet -RequiredVersion 2.2.5 -Repository PSGallery `
            -Scope AllUsers -Force -AllowClobber
    } else {
        Write-Log "Compatible PowerShellGet $powerShellGetVersion is available."
    }

    $installedVersion = Get-HighestModuleVersion -Name PowerShellGet
    if ($installedVersion -lt [version]'2.2.5') {
        throw "PowerShellGet 2.2.5 was not installed successfully. Highest available version: $installedVersion"
    }
}

function Install-HPCMSLInFreshPowerShell {
    # PackageManagement assemblies cannot be safely replaced after the legacy
    # copy has loaded. A fresh child process imports the new modules by their
    # exact paths before it downloads HPCMSL and its HP.* dependencies.
    $installer = @'
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$packageManagement = Get-Module -ListAvailable -Name PackageManagement | Sort-Object Version -Descending | Select-Object -First 1
$powerShellGet = Get-Module -ListAvailable -Name PowerShellGet | Sort-Object Version -Descending | Select-Object -First 1
if (-not $packageManagement) { throw 'PackageManagement is not installed.' }
if (-not $powerShellGet -or [version]$powerShellGet.Version -lt [version]'2.2.5') {
    throw 'PowerShellGet 2.2.5 or later is not available in the fresh process.'
}

Import-Module $packageManagement.Path -Force
Import-Module $powerShellGet.Path -Force
if (-not (Get-PSRepository -Name PSGallery -ErrorAction SilentlyContinue)) { Register-PSRepository -Default }
Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
Install-Module -Name HPCMSL -Repository PSGallery -Scope AllUsers -Force -AllowClobber -AcceptLicense
'HPCMSL_INSTALL_OK'
'@

    $encodedInstaller = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($installer))
    $powerShellExe = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $installerOutput = @(& $powerShellExe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass `
        -EncodedCommand $encodedInstaller 2>&1)
    $installerExitCode = $LASTEXITCODE

    foreach ($line in $installerOutput) {
        $text = [string]$line
        if (-not [string]::IsNullOrWhiteSpace($text) -and $text -ne 'HPCMSL_INSTALL_OK') {
            Write-Log "HPCMSL installer: $text"
        }
    }
    if ($installerExitCode -ne 0 -or $installerOutput -notcontains 'HPCMSL_INSTALL_OK') {
        throw "The fresh PowerShell HPCMSL installer failed with exit code $installerExitCode."
    }
}

if (-not (Test-Administrator)) { Write-Log 'Run this script as Administrator/SYSTEM.' 'ERROR'; throw 'Administrator rights are required.' }
$cs = Get-CimInstance Win32_ComputerSystem
$model = (Get-CimInstance Win32_ComputerSystemProduct).Name
if ($cs.Manufacturer -notmatch 'HP|Hewlett') { Write-Log "Not an HP machine. Manufacturer: $($cs.Manufacturer)" 'ERROR'; throw 'This BIOS script only supports HP hardware.' }
Write-Log "Detected HP model: $model"

# Optional injected variable. Do not log it.
$SetupPassword = if ([string]::IsNullOrWhiteSpace($BIOSPassword)) { $null } else { $BIOSPassword }

try {
    $hpcmslReady = $false
    if (Get-Module -ListAvailable -Name HPCMSL) {
        try {
            Import-Module HPCMSL -Force -ErrorAction Stop
            $hpcmslReady = $true
        } catch {
            Write-Log "The existing HPCMSL installation is incomplete or incompatible and will be repaired: $($_.Exception.Message)" 'WARN'
        }
    }

    if (-not $hpcmslReady) {
        Write-Log 'Installing compatible prerequisites and HP Client Management Script Library.'
        Initialize-PowerShellGalleryClient
        Install-HPCMSLInFreshPowerShell
        if (-not (Get-Module -ListAvailable -Name HPCMSL)) {
            throw 'HPCMSL installation completed but the module is not visible in the system module path.'
        }
        Import-Module HPCMSL -Force -ErrorAction Stop
    }
    Write-Log 'HPCMSL loaded.' 'SUCCESS'
} catch {
    Write-Log "Unable to install/load HPCMSL: $($_.Exception.Message)" 'ERROR'
    throw
}

try {
    $script:HPSettings = @(Get-HPBIOSSettingsList -NoReadonly)
    Write-Log "Writable BIOS settings detected: $($script:HPSettings.Count)"
} catch {
    Write-Log "Unable to inventory HP BIOS settings: $($_.Exception.Message)" 'ERROR'
    throw
}

function Find-HPSetting {
    param([string[]]$Aliases)
    foreach ($alias in $Aliases) {
        $exact = $script:HPSettings | Where-Object { $_.Name -ieq $alias } | Select-Object -First 1
        if ($exact) { return $exact }
    }
    foreach ($alias in $Aliases) {
        $pattern = [regex]::Escape($alias).Replace('\ ','[\s\-_]*')
        $fuzzy = $script:HPSettings | Where-Object { $_.Name -match $pattern } | Select-Object -First 1
        if ($fuzzy) { return $fuzzy }
    }
    return $null
}

function Get-PossibleValues {
    param($Setting)
    foreach ($propertyName in @('PossibleValues','Values','ValueList','Options')) {
        if ($Setting.PSObject.Properties.Name -contains $propertyName) {
            $v = $Setting.$propertyName
            if ($v) { return @($v) }
        }
    }
    return @()
}

function Set-HPSettingSafe {
    param(
        [string]$FriendlyName,
        [string[]]$SettingAliases,
        [string[]]$DesiredValues,
        [switch]$Optional
    )
    $setting = Find-HPSetting -Aliases $SettingAliases
    if (-not $setting) {
        Write-Log "${FriendlyName}: setting not exposed by this model." 'UNSUPPORTED'
        return
    }

    $actualName = [string]$setting.Name
    $possible = Get-PossibleValues $setting
    $chosen = $null
    foreach ($candidate in $DesiredValues) {
        if (-not $possible -or $possible.Count -eq 0) { $chosen = $candidate; break }
        $match = $possible | Where-Object { [string]$_ -ieq $candidate } | Select-Object -First 1
        if ($match) { $chosen = [string]$match; break }
    }
    if (-not $chosen) {
        Write-Log "${FriendlyName}: '$actualName' exists, but none of the requested values are allowed. Allowed: $($possible -join ', ')" 'UNSUPPORTED'
        return
    }

    try {
        $current = Get-HPBIOSSettingValue -Name $actualName
        if ([string]$current -ieq $chosen) {
            Write-Log "${FriendlyName}: already '$chosen' ($actualName)." 'SUCCESS'
            return
        }
        $params = @{ Name=$actualName; Value=$chosen; ErrorAction='Stop' }
        if ($SetupPassword) { $params.Password = $SetupPassword }
        Set-HPBIOSSettingValue @params | Out-Null
        Start-Sleep -Milliseconds 300
        $verify = Get-HPBIOSSettingValue -Name $actualName
        if ([string]$verify -ieq $chosen) {
            Write-Log "${FriendlyName}: changed '$current' -> '$verify' ($actualName)." 'SUCCESS'
        } else {
            Write-Log "${FriendlyName}: command completed but verification returned '$verify' instead of '$chosen' ($actualName)." 'WARN'
        }
    } catch {
        $hint = if (-not $SetupPassword -and (Get-HPBIOSSetupPasswordIsSet -ErrorAction SilentlyContinue)) { ' A BIOS setup password is present; provide ScriptBox variable BIOSPassword.' } else { '' }
        Write-Log "${FriendlyName}: failed for '$actualName': $($_.Exception.Message)$hint" 'ERROR'
    }
}

$jobs = @(
    @{ Friendly='Wake on WLAN'; Aliases=@('Wake on WLAN','Wake On WLAN','Wake on Wireless LAN','Wake on WiFi'); Values=@('Enable','Enabled') },
    @{ Friendly='Power On from Keyboard Ports'; Aliases=@('Power On from Keyboard Ports','Power On From Keyboard Ports','Power On by Keyboard','Keyboard Power On','Power on from USB Keyboard'); Values=@('Enable','Enabled') },
    @{ Friendly='After Power Loss'; Aliases=@('After Power Loss','Power On After Power Failure','AC Power Recovery','State After Power Loss'); Values=@('Power On','On','Always On') },
    @{ Friendly='Wake on LAN Power-on Password Policy'; Aliases=@('Wake on LAN Power-on Password Policy','Wake On LAN Power-On Password Policy','WOL Power-On Password Policy'); Values=@('Require Password','Password Required') },
    @{ Friendly='Startup Delay'; Aliases=@('Startup Delay (sec.)','Startup Delay (sec)','Startup Delay','POST Delay (sec.)','POST Delay'); Values=@('30','30 seconds','30 Seconds') },
    @{ Friendly='Audio Alerts During Boot'; Aliases=@('Audio Alerts During Boot','Audio Alerts During Startup','POST Audio Alerts','Boot Audio Alerts'); Values=@('Disable','Disabled') },
    @{ Friendly='USB Always On / Charging While Off'; Aliases=@('USB Charging Port','USB Charging in S4/S5','USB Charging While Off','USB Power Delivery in Soft Off State (S5)','USB Ports Powered in S4/S5','Always On USB'); Values=@('Enable','Enabled','On') }
)

foreach ($job in $jobs) {
    Set-HPSettingSafe -FriendlyName $job.Friendly -SettingAliases $job.Aliases -DesiredValues $job.Values
}

Write-Log "Finished. BIOS changes normally take effect after restart. Log: $LogFile" 'SUCCESS'
return
