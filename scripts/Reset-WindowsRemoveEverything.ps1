#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Confirmation,

    [switch]$ValidationOnly
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if ($Confirmation -cne 'ERASE ALL INTERNAL DATA') {
    throw 'Confirmation did not match. Type ERASE ALL INTERNAL DATA exactly; no wipe was scheduled.'
}

$probePayload = @'
$ErrorActionPreference = 'Stop'
$class = Get-CimClass -Namespace 'root\cimv2\mdm\dmmap' -ClassName 'MDM_RemoteWipe'
if (-not $class.CimClassMethods.ContainsKey('doWipeProtectedMethod')) { exit 12 }
exit 0
'@

$wipePayload = @'
$ErrorActionPreference = 'Stop'
$namespaceName = 'root\cimv2\mdm\dmmap'
$className = 'MDM_RemoteWipe'
$methodName = 'doWipeProtectedMethod'
$session = New-CimSession
$params = New-Object Microsoft.Management.Infrastructure.CimMethodParametersCollection
$param = [Microsoft.Management.Infrastructure.CimMethodParameter]::Create('param', '', 'String', 'In')
$params.Add($param)
$instance = Get-CimInstance -Namespace $namespaceName -ClassName $className -Filter "ParentID='./Vendor/MSFT' and InstanceID='RemoteWipe'"
$result = $session.InvokeMethod($namespaceName, $instance, $methodName, $params)
if ($null -ne $result.ReturnValue -and [int]$result.ReturnValue -ne 0) { exit [int]$result.ReturnValue }
exit 0
'@

[void][scriptblock]::Create($probePayload)
[void][scriptblock]::Create($wipePayload)
if ($ValidationOnly) {
    Write-Host '[SUCCESS] Unattended protected-wipe payloads passed validation. Nothing was scheduled.'
    return
}

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Administrator approval is required; no wipe was scheduled.'
}

$editionId = [string](Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name EditionID).EditionID
if ($editionId -match '^(Core|Home|Starter)') {
    throw "Windows edition '$editionId' does not support Microsoft RemoteWipe; no wipe was scheduled."
}

$reagentPath = Join-Path $env:SystemRoot 'System32\reagentc.exe'
if (-not (Test-Path -LiteralPath $reagentPath -PathType Leaf)) {
    throw 'Windows Recovery Environment tooling is unavailable; no wipe was scheduled.'
}

Write-Host '[INFO] Enabling and checking the Windows Recovery Environment.'
$reagentOutput = & $reagentPath /enable 2>&1
if ($LASTEXITCODE -ne 0) {
    $details = ($reagentOutput | Out-String).Trim()
    throw "Windows Recovery Environment could not be enabled. $details"
}

function ConvertTo-TaskEncodedCommand {
    param([Parameter(Mandatory)][string]$Text)
    [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Text))
}

function New-SystemTaskParts {
    param(
        [Parameter(Mandatory)][string]$Payload,
        [Parameter(Mandatory)][datetime]$At
    )
    $encoded = ConvertTo-TaskEncodedCommand -Text $Payload
    $powerShellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $action = New-ScheduledTaskAction -Execute $powerShellPath -Argument "-NoLogo -NoProfile -NonInteractive -EncodedCommand $encoded"
    $trigger = New-ScheduledTaskTrigger -Once -At $At
    $taskPrincipal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
    [pscustomobject]@{ Action = $action; Trigger = $trigger; Principal = $taskPrincipal; Settings = $settings }
}

$probeTaskName = 'ScriptBox-WipeProbe-{0}' -f [guid]::NewGuid().ToString('N')
$probeParts = New-SystemTaskParts -Payload $probePayload -At (Get-Date).AddHours(1)
try {
    Write-Host '[INFO] Testing Microsoft protected-wipe support as Local System.'
    Register-ScheduledTask -TaskName $probeTaskName -Action $probeParts.Action -Trigger $probeParts.Trigger `
        -Principal $probeParts.Principal -Settings $probeParts.Settings -Force | Out-Null
    $probeStarted = Get-Date
    Start-ScheduledTask -TaskName $probeTaskName
    $probeDeadline = $probeStarted.AddSeconds(30)
    do {
        Start-Sleep -Milliseconds 250
        $probeTask = Get-ScheduledTask -TaskName $probeTaskName
        $probeInfo = Get-ScheduledTaskInfo -TaskName $probeTaskName
        $probeFinished = $probeInfo.LastRunTime -ge $probeStarted.AddSeconds(-1) -and $probeTask.State -ne 'Running'
    } while (-not $probeFinished -and (Get-Date) -lt $probeDeadline)

    if (-not $probeFinished) { throw 'The Local System compatibility test timed out.' }
    if ([int]$probeInfo.LastTaskResult -ne 0) {
        throw "Microsoft protected wipe is unavailable (compatibility result $($probeInfo.LastTaskResult))."
    }
}
finally {
    Unregister-ScheduledTask -TaskName $probeTaskName -Confirm:$false -ErrorAction SilentlyContinue
}

$wipeTaskName = 'ScriptBox-ProtectedWipe-{0}' -f [guid]::NewGuid().ToString('N')
$wipeAt = (Get-Date).AddSeconds(60)
$wipeParts = New-SystemTaskParts -Payload $wipePayload -At $wipeAt
Register-ScheduledTask -TaskName $wipeTaskName -Action $wipeParts.Action -Trigger $wipeParts.Trigger `
    -Principal $wipeParts.Principal -Settings $wipeParts.Settings -Force | Out-Null

Write-Host '[WARNING] UNATTENDED PROTECTED WIPE SCHEDULED.'
Write-Host '[WARNING] Every partition on the internal Windows disk, including D: on that disk, will be permanently cleaned.'
Write-Host '[WARNING] Keep the PC connected to power. Do not interrupt it after recovery begins.'
Write-Host ("[WARNING] The wipe starts at {0}. To cancel before then, run as administrator:" -f $wipeAt.ToString('HH:mm:ss'))
Write-Host ("Stop-ScheduledTask -TaskName '{0}'; Unregister-ScheduledTask -TaskName '{0}' -Confirm:`$false" -f $wipeTaskName)
Write-Host '[SUCCESS] No further interaction is required until Windows reaches its first-run setup screen.'
