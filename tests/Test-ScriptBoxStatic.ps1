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
$usbDevicesPath = Join-Path $scriptsPath 'Show-ConnectedUSBDevices.ps1'
$wolWatcherPath = Join-Path $scriptsPath 'Watch-WakeOnLanPackets.ps1'
$hpG3G5WolKvmPath = Join-Path $scriptsPath 'Configure-HPEliteDesk800G5WolKvm.ps1'
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
    'ConvertTo-ColonMac'
)) {
    if ($hpG3G5WolKvmSource -notmatch [regex]::Escape($requiredHpG3G5Text)) {
        throw "The HP G3/G5 Mini workflow is missing required behavior: $requiredHpG3G5Text"
    }
}
if ($hpG3G5WolKvmSource -match '\[\(\]\(%28\)|\[\{\]\(%7B\)|\[powerParameters\]\(powerParameters\)') {
    throw 'The HP G3/G5 Mini workflow still contains URL/Markdown-corrupted PowerShell tokens.'
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

Write-Host "[PASS] Parsed $($files.Count) PowerShell files and both embedded payloads without executing them."
