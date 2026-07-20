#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Confirmation
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if ($Confirmation -cne 'ERASE THIS PC') {
    throw 'Confirmation did not match. Type ERASE THIS PC exactly; no reset action was started.'
}

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Administrator approval is required; no reset action was started.'
}

$reagentPath = Join-Path $env:SystemRoot 'System32\reagentc.exe'
if (-not (Test-Path -LiteralPath $reagentPath -PathType Leaf)) {
    throw 'Windows Recovery Environment tooling is unavailable; no reset action was started.'
}

Write-Host '[INFO] Checking the Windows Recovery Environment.'
$reagentOutput = & $reagentPath /enable 2>&1
if ($LASTEXITCODE -ne 0) {
    $details = ($reagentOutput | Out-String).Trim()
    throw "Windows Recovery Environment could not be enabled. $details"
}

Write-Host '[WARNING] The next screen controls an irreversible Windows reset.'
Write-Host '[WARNING] Choose Remove everything. Do not choose Keep my files.'
Write-Host '[WARNING] Choose Cloud download for a fresh Windows image.'
Write-Host '[WARNING] Under Change settings, enable Clean data to clean the Windows drive.'
Write-Host '[WARNING] Select all drives only if every attached internal drive must also be erased.'
Write-Host '[WARNING] Keep the PC connected to power and do not interrupt the reset after it begins.'

$systemResetPath = Join-Path $env:SystemRoot 'System32\SystemReset.exe'
if (Test-Path -LiteralPath $systemResetPath -PathType Leaf) {
    Write-Host '[INFO] Opening the Reset this PC wizard.'
    Start-Process -FilePath $systemResetPath -ArgumentList '-factoryreset'
}
else {
    Write-Host '[INFO] Opening Windows Recovery settings. Select Reset PC to continue.'
    Start-Process -FilePath 'ms-settings:recovery'
}

Write-Host '[SUCCESS] Windows Recovery was opened. No data is erased until the reset choices are reviewed and confirmed there.'
