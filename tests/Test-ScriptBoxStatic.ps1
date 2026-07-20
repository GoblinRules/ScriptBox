#requires -Version 5.1
[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$launcherPath = Join-Path $repositoryRoot 'ScriptBox.ps1'
$scriptsPath = Join-Path $repositoryRoot 'scripts'
$resetPath = Join-Path $scriptsPath 'Reset-WindowsRemoveEverything.ps1'
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

$methodCollectionType = [Microsoft.Management.Infrastructure.CimClass].GetProperty('CimClassMethods').PropertyType
if (-not [Collections.IEnumerable].IsAssignableFrom($methodCollectionType)) {
    throw 'CimClassMethods is not enumerable on this Windows PowerShell runtime.'
}

Write-Host "[PASS] Parsed $($files.Count) PowerShell files and both embedded payloads without executing them."
