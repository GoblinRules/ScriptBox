#requires -Version 5.1
[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$launcherPath = Join-Path $repositoryRoot 'ScriptBox.ps1'
$scriptsPath = Join-Path $repositoryRoot 'scripts'
$resetPath = Join-Path $scriptsPath 'Reset-WindowsRemoveEverything.ps1'
$hideShutdownPath = Join-Path $scriptsPath 'Hide-ShutdownOptions.ps1'
$repairShellPath = Join-Path $scriptsPath 'Repair-PowerMenuAndSystemTray.ps1'
$disableAudioPath = Join-Path $scriptsPath 'Disable-MachineAudio.ps1'
$usbDevicesPath = Join-Path $scriptsPath 'Show-ConnectedUSBDevices.ps1'
$wolWatcherPath = Join-Path $scriptsPath 'Watch-WakeOnLanPackets.ps1'
$hpBiosPath = Join-Path $scriptsPath 'Configure-HPBIOS.ps1'
$hpG3G5WolKvmPath = Join-Path $scriptsPath 'Configure-HPEliteDesk800G5WolKvm.ps1'
$lenovoBiosPath = Join-Path $scriptsPath 'Configure-LenovoBIOS.ps1'
$files = @($launcherPath) + @(Get-ChildItem -LiteralPath $scriptsPath -Filter '*.ps1' -File | Select-Object -ExpandProperty FullName)

$parseFailures = New-Object System.Collections.Generic.List[string]
foreach ($file in $files) {
    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($file, [ref]$tokens, [ref]$errors)
    foreach ($errorItem in $errors) {
        $parseFailures.Add("$file`: $($errorItem.Message)")
    }
}
if ($parseFailures.Count -gt 0) {
    throw "PowerShell parse failures:`n$($parseFailures -join "`n")"
}

$resetTokens = $null
$resetErrors = $null
$resetAst = [System.Management.Automation.Language.Parser]::ParseFile($resetPath, [ref]$resetTokens, [ref]$resetErrors)
$payloadCases = @(
    [pscustomobject]@{ Variable = 'probePayloadTemplate'; Token = '__PROBE_STATUS_PATH__' },
    [pscustomobject]@{ Variable = 'wipePayloadTemplate'; Token = '__WIPE_STATUS_PATH__' }
)

foreach ($payloadCase in $payloadCases) {
    $assignment = $resetAst.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
        $node.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
        $node.Left.VariablePath.UserPath -eq $payloadCase.Variable
    }, $true) | Select-Object -First 1
    if ($null -eq $assignment) {
        throw "Could not find the literal $($payloadCase.Variable) payload template."
    }

    $payloadExpression = $assignment.Right
    if ($payloadExpression -is [System.Management.Automation.Language.CommandExpressionAst]) {
        $payloadExpression = $payloadExpression.Expression
    }
    if ($payloadExpression -isnot [System.Management.Automation.Language.StringConstantExpressionAst]) {
        throw "$($payloadCase.Variable) is not a literal string payload template."
    }

    $template = [string]$payloadExpression.Value
    if (($template.Split([string[]]@($payloadCase.Token), [StringSplitOptions]::None).Count - 1) -ne 1) {
        throw "$($payloadCase.Variable) must contain exactly one $($payloadCase.Token) token."
    }
    $resolvedPayload = $template.Replace($payloadCase.Token, 'C:\Windows\Temp\ScriptBox-StaticValidation.status')
    $payloadTokens = $null
    $payloadErrors = $null
    [void][System.Management.Automation.Language.Parser]::ParseInput($resolvedPayload, [ref]$payloadTokens, [ref]$payloadErrors)
    if ($payloadErrors.Count -gt 0) {
        throw "$($payloadCase.Variable) does not parse: $($payloadErrors.Message -join '; ')"
    }

    $encodedPayload = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($resolvedPayload))
    $arguments = "-NoLogo -NoProfile -NonInteractive -EncodedCommand $encodedPayload"
    if ($arguments.Length -gt 30000) {
        throw "$($payloadCase.Variable) produces a $($arguments.Length)-character task command."
    }
}

$resetSource = Get-Content -Raw -LiteralPath $resetPath
if ($resetSource -match 'CimClassMethods\.ContainsKey') {
    throw 'CimClassMethods is not a dictionary; enumerate it or use its string indexer.'
}
if ($resetSource -match '-StartWhenAvailable') {
    throw 'A missed protected-wipe trigger must not be allowed to run later.'
}

$launcherSource = Get-Content -Raw -LiteralPath $launcherPath
if ($launcherSource -notmatch "-RequiredInputValue 'ERASE ALL INTERNAL DATA'") {
    throw 'The erase workflow must validate its exact confirmation phrase inside the launcher.'
}
if ($launcherSource -notmatch "-Name 'Repair System Tray and Audio'" -or
    $launcherSource -match "-Id 'restore-machine-audio'") {
    throw 'Fixes must expose one combined Repair System Tray and Audio card.'
}
foreach ($requiredShellText in @(
    "`$script:ActiveSection = 'Scripts'",
    'x:Name="SectionHost"',
    'x:Name="ScriptTabsPanel"',
    "@('Applications', 'Scripts', 'Network Tools', 'Diagnostics', 'System Info')",
    'function Select-Section',
    'function Render-Applications',
    'function Render-NetworkTools',
    'function Render-Diagnostics',
    'function Render-SystemInfo',
    'function Set-ScriptBoxTheme',
    'function Set-TerminalMode',
    'function Get-ApplicationStatus',
    'function New-ApplicationActionScript',
    'function Start-ApplicationAction',
    'function Start-SelectedApplications',
    'INSTALL SELECTED',
    "'D1' { Select-Section -Section 'Applications'",
    "'D5' { Select-Section -Section 'System Info'"
)) {
    if ($launcherSource -notmatch [regex]::Escape($requiredShellText)) {
        throw "The lightweight multi-section shell is missing: $requiredShellText"
    }
}
foreach ($requiredApplicationText in @(
    "Id='trip'",
    "Text='Download Portable'; Type='Portable'",
    "Text='Download Installer'; Type='Exe'",
    "Id='pyautoclicker'",
    "Type='RemoteScript'",
    "Type='RemoteWindow'",
    "Type='Msi'",
    'Get-AuthenticodeSignature',
    'Start-Process -FilePath `$downloadPath -Wait -PassThru',
    'ScriptBox itself remains portable',
    'downloads and installs run only when selected'
)) {
    if ($launcherSource -notmatch [regex]::Escape($requiredApplicationText)) {
        throw "The portable Application Installer is missing: $requiredApplicationText"
    }
}
if ($launcherSource -notmatch "if \(-not \(Show-ScriptBoxDialog -Title.+-Buttons YesNo") {
    throw 'Each single application action must require explicit confirmation.'
}

$launcherTokens = $null
$launcherErrors = $null
$launcherAst = [System.Management.Automation.Language.Parser]::ParseFile(
    $launcherPath,
    [ref]$launcherTokens,
    [ref]$launcherErrors
)
$runnerAssignment = $launcherAst.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
    $node.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
    $node.Left.VariablePath.UserPath -eq 'runnerTemplate'
}, $true) | Select-Object -First 1
if ($null -eq $runnerAssignment) {
    throw 'Could not find the launcher runnerTemplate payload.'
}
$runnerExpression = $runnerAssignment.Right
if ($runnerExpression -is [System.Management.Automation.Language.CommandExpressionAst]) {
    $runnerExpression = $runnerExpression.Expression
}
if ($runnerExpression -isnot [System.Management.Automation.Language.StringConstantExpressionAst]) {
    throw 'The launcher runnerTemplate is not a literal string payload.'
}
$resolvedRunner = [string]$runnerExpression.Value
$resolvedRunner = $resolvedRunner.Replace(
    '__LOG_PATH__',
    'C:\Windows\Temp\ScriptBox-Runner-StaticValidation.log'
)
$resolvedRunner = $resolvedRunner.Replace('__TASK_NAME__', 'Static validation')
$resolvedRunner = $resolvedRunner.Replace('__PAYLOAD__', "Write-Output 'payload'")
$runnerTokens = $null
$runnerErrors = $null
[void][System.Management.Automation.Language.Parser]::ParseInput(
    $resolvedRunner,
    [ref]$runnerTokens,
    [ref]$runnerErrors
)
if ($runnerErrors.Count -gt 0) {
    throw "The launcher runnerTemplate does not parse: $($runnerErrors.Message -join '; ')"
}

foreach ($requiredSharedLogText in @(
    'function Read-SharedTextFile',
    '[IO.FileShare]::ReadWrite',
    'catch [IO.IOException]',
    '$attempt -le 8'
)) {
    if ($launcherSource -notmatch [regex]::Escape($requiredSharedLogText)) {
        throw "The launcher is missing shared-log protection: $requiredSharedLogText"
    }
}

$hideShutdownSource = Get-Content -Raw -LiteralPath $hideShutdownPath
if ($hideShutdownSource -match 'PolicyManager\\default') {
    throw 'Hide Shutdown Options must not modify the Windows PolicyManager default store.'
}
if ($hideShutdownSource -notmatch "Name 'NoClose'") {
    throw 'Hide Shutdown Options must retain the documented NoClose user policy.'
}

$repairShellSource = Get-Content -Raw -LiteralPath $repairShellPath
if ($repairShellSource -notmatch 'PolicyManager\\default' -or
    $repairShellSource -notmatch "Remove-ItemProperty.+Name 'NoClose'") {
    throw 'The Windows shell repair must reverse both legacy ScriptBox policy changes.'
}
foreach ($requiredRepairAudioText in @(
    "@('AudioEndpointBuilder', 'Audiosrv')",
    "-Name 'fDisableCam'",
    'Set-Service -Name $serviceName -StartupType Automatic',
    'Start-Service -Name $serviceName',
    "StartMode -ne 'Auto'",
    "State -ne 'Running'"
)) {
    if ($repairShellSource -notmatch [regex]::Escape($requiredRepairAudioText)) {
        throw "The system-tray repair is missing required audio restoration behavior: $requiredRepairAudioText"
    }
}

$disableAudioSource = Get-Content -Raw -LiteralPath $disableAudioPath
foreach ($requiredDisableAudioText in @(
    "`$disabledAudioServiceName = 'Audiosrv'",
    "`$endpointServiceName = 'AudioEndpointBuilder'",
    'Set-Service -Name $endpointServiceName -StartupType Automatic',
    'Start-Service -Name $endpointServiceName',
    'Set-Service -Name $disabledAudioServiceName -StartupType Disabled',
    'Stop-Service -Name $disabledAudioServiceName'
)) {
    if ($disableAudioSource -notmatch [regex]::Escape($requiredDisableAudioText)) {
        throw "Disable Machine Audio is missing tray-safe behavior: $requiredDisableAudioText"
    }
}
if ($disableAudioSource -match [regex]::Escape("Set-Service -Name 'AudioEndpointBuilder' -StartupType Disabled") -or
    $disableAudioSource -match [regex]::Escape("Stop-Service -Name 'AudioEndpointBuilder'")) {
    throw 'Disable Machine Audio must not disable or stop Audio Endpoint Builder.'
}

$usbDevicesSource = Get-Content -Raw -LiteralPath $usbDevicesPath
if ($usbDevicesSource -notmatch 'Get-PnpDevice -PresentOnly' -or
    $usbDevicesSource -notmatch 'DEVPKEY_Device_LocationInfo' -or
    $usbDevicesSource -notmatch 'DEVPKEY_Device_LocationPaths' -or
    $usbDevicesSource -notmatch 'ShowDialog') {
    throw 'The USB device viewer must query present USB devices and show its formatted popup.'
}

$wolWatcherSource = Get-Content -Raw -LiteralPath $wolWatcherPath
foreach ($requiredWolText in @(
    'filter add WOL-Port-7 -t UDP -p 7',
    'filter add WOL-Port-9 -t UDP -p 9',
    'start --capture --comp nics --pkt-size 0 --log-mode real-time',
    "Arguments 'stop'",
    "Arguments 'filter remove'"
)) {
    if ($wolWatcherSource -notmatch [regex]::Escape($requiredWolText)) {
        throw "The Wake-on-LAN watcher is missing required Pktmon behavior: $requiredWolText"
    }
}
if ($wolWatcherSource -notmatch 'DispatcherTimer' -or $wolWatcherSource -notmatch 'ShowDialog') {
    throw 'The Wake-on-LAN watcher must poll real-time output in a popup.'
}

$hpBiosSource = Get-Content -Raw -LiteralPath $hpBiosPath
foreach ($requiredHpBiosText in @(
    'Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope AllUsers',
    'Install-Module -Name PackageManagement -MinimumVersion 1.4.8.1 -Repository PSGallery',
    'Install-Module -Name HPCMSL -Repository PSGallery -Scope AllUsers -Force -AllowClobber -AcceptLicense',
    'Import-Module HPCMSL -Force -ErrorAction Stop',
    'Get-HPBIOSSettingsList -NoReadonly',
    'function Restore-PowerShellGalleryPolicy',
    '$script:PSGalleryOriginalState',
    'Set-PSRepository -Name PSGallery -InstallationPolicy $originalPolicy',
    'Unregister-PSRepository -Name PSGallery',
    "Get-Command -Name 'pwsh.exe'",
    'PowerShell 7 fallback',
    'finally {',
    'Restore-PowerShellGalleryPolicy'
)) {
    if ($hpBiosSource -notmatch [regex]::Escape($requiredHpBiosText)) {
        throw "The general HP BIOS workflow is missing prerequisite or PSGallery restoration behavior: $requiredHpBiosText"
    }
}

$hpG3G5WolKvmSource = Get-Content -Raw -LiteralPath $hpG3G5WolKvmPath
$supportedHpMiniPattern = '^HP\s+EliteDesk\s+800\b(?=.*\bG(?:3|5)\b)(?=.*\b(?:Desktop\s+Mini|DM)\b).*$'
foreach ($requiredHpG3G5Text in @(
    $supportedHpMiniPattern,
    'including 35W and 65W variants',
    "'USB Legacy Port Charging'",
    "'Wake On LAN'",
    "'S5 Maximum Power Savings'",
    "Name 'HiberbootEnabled'",
    'Set-NetAdapterPowerManagement @powerParameters',
    '/deviceenablewake',
    'ALL HP BIOS SETTINGS AFTER CONFIGURATION',
    'ConvertTo-ColonMac',
    '$WorkflowState.Report',
    '$WorkflowState.HadWarnings',
    '$WorkflowState.Completed',
    '$WorkflowState.MacCopied',
    'Get-NetAdapter -IncludeHidden',
    'No physical wired Ethernet adapter was found',
    'Error:`r`n{0}'
)) {
    if ($hpG3G5WolKvmSource -notmatch [regex]::Escape($requiredHpG3G5Text)) {
        throw "The HP G3/G5 Mini workflow is missing required behavior: $requiredHpG3G5Text"
    }
}
if ($hpG3G5WolKvmSource -match '\[\(\]\(%28\)|\[\{\]\(%7B\)|\[powerParameters\]\(powerParameters\)') {
    throw 'The HP G3/G5 Mini workflow still contains URL/Markdown-corrupted PowerShell tokens.'
}
if ($hpG3G5WolKvmSource -match '\$script:(?:Report|HadWarnings|HpBiosSettings)') {
    throw 'The HP G3/G5 Mini workflow must not use runner-level script scope for its mutable workflow state.'
}

$lenovoBiosSource = Get-Content -Raw -LiteralPath $lenovoBiosPath
foreach ($requiredLenovoText in @(
    'ThinkCentre M710q Tiny WOL/KVM profile',
    "@('10MQ', '10MR', '10MS', '10MT', '10N3', '10QR', '10YC')",
    'function Find-LenovoSettingExact',
    "[StringComparison]::OrdinalIgnoreCase",
    "Lenovo_BiosPasswordSettings",
    'PasswordState -band 2',
    'Lenovo_WmiOpcodeInterface',
    'WmiOpcodePasswordAdmin:',
    'Lenovo_SetBiosSetting',
    'Lenovo_SaveBiosSettings',
    'Lenovo_DiscardBiosSettings',
    "'Onboard Ethernet Controller'",
    "'Wake on LAN'",
    "'Enhanced Power Saving Mode'",
    "'Smart Power On'",
    "'After Power Loss'",
    "'USB Support'",
    "'USB Legacy Support'",
    "'Front USB Ports'",
    "'Rear USB Ports'",
    'ALL LENOVO BIOS SETTINGS AFTER CONFIGURATION',
    'Show-ResultPopup',
    'Saved $($WorkflowState.ChangedCount) staged Lenovo BIOS change(s) in one operation.'
)) {
    if ($lenovoBiosSource -notmatch [regex]::Escape($requiredLenovoText)) {
        throw "The Lenovo M710q BIOS workflow is missing required behavior: $requiredLenovoText"
    }
}
foreach ($unsafeLegacyLenovoText in @(
    'Wake on WLAN',
    'Wake-on-LAN password policy',
    'Startup/POST delay',
    'Boot audio alerts disabled'
)) {
    if ($lenovoBiosSource -match [regex]::Escape($unsafeLegacyLenovoText)) {
        throw "The Lenovo BIOS workflow still contains the unsafe legacy target: $unsafeLegacyLenovoText"
    }
}
if ($lenovoBiosSource -match '\$script:(?:Report|HadWarnings|Results)') {
    throw 'The Lenovo BIOS workflow must not use runner-level script scope for mutable workflow state.'
}
foreach ($supportedModel in @(
    'HP EliteDesk 800 G3 Desktop Mini',
    'HP EliteDesk 800 35W G3 Desktop Mini PC',
    'HP EliteDesk 800 G3 DM 35W',
    'HP EliteDesk 800 G5 Desktop Mini',
    'HP EliteDesk 800 65W G5 Desktop Mini PC'
)) {
    if ($supportedModel -notmatch $supportedHpMiniPattern) {
        throw "The HP G3/G5 Mini model gate rejected a supported model: $supportedModel"
    }
}
foreach ($unsupportedModel in @(
    'HP EliteDesk 800 G4 Desktop Mini',
    'HP EliteDesk 800 G3 Small Form Factor',
    'HP ProDesk 600 G3 Desktop Mini',
    'HP EliteDesk 705 G3 Desktop Mini'
)) {
    if ($unsupportedModel -match $supportedHpMiniPattern) {
        throw "The HP G3/G5 Mini model gate accepted an unsupported model: $unsupportedModel"
    }
}

$methodCollectionType = [Microsoft.Management.Infrastructure.CimClass].GetProperty('CimClassMethods').PropertyType
if (-not [Collections.IEnumerable].IsAssignableFrom($methodCollectionType)) {
    throw 'CimClassMethods is not enumerable on this Windows PowerShell runtime.'
}

Write-Host "[PASS] Parsed $($files.Count) PowerShell files, the launcher runner, and both embedded payloads without executing them."
