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

$probePayloadTemplate = @'
$ErrorActionPreference = 'Stop'
$statusPath = '__PROBE_STATUS_PATH__'

function Complete-Probe {
    param(
        [Parameter(Mandatory)][int]$Code,
        [Parameter(Mandatory)][string]$Detail
    )
    try {
        $encodedDetail = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Detail))
        [IO.File]::WriteAllText($statusPath, ("{0}|{1}" -f $Code, $encodedDetail), [Text.Encoding]::ASCII)
    }
    catch {
        exit 17
    }
    exit $Code
}

try {
    $instance = Get-CimInstance -Namespace 'root\cimv2\mdm\dmmap' -ClassName 'MDM_RemoteWipe' `
        -Filter "ParentID='./Vendor/MSFT' and InstanceID='RemoteWipe'" -OperationTimeoutSec 45
    if ($null -eq $instance) { Complete-Probe -Code 13 -Detail 'The RemoteWipe instance was not returned.' }
}
catch [Microsoft.Management.Infrastructure.CimException] {
    $hresult = [uint32]([int64]$_.Exception.HResult -band 0xFFFFFFFFL)
    Complete-Probe -Code 14 -Detail ("{0} (0x{1}): {2}" -f $_.Exception.GetType().FullName, $hresult.ToString('X8'), $_.Exception.Message)
}
catch {
    $hresult = [uint32]([int64]$_.Exception.HResult -band 0xFFFFFFFFL)
    Complete-Probe -Code 15 -Detail ("{0} (0x{1}): {2}" -f $_.Exception.GetType().FullName, $hresult.ToString('X8'), $_.Exception.Message)
}

try {
    $protectedMethod = $instance.CimClass.CimClassMethods |
        Where-Object { $_.Name -eq 'doWipeProtectedMethod' } |
        Select-Object -First 1
    if ($null -eq $protectedMethod) {
        Complete-Probe -Code 12 -Detail 'The doWipeProtectedMethod method is not present in the RemoteWipe class metadata.'
    }
    Complete-Probe -Code 0 -Detail 'The RemoteWipe instance and doWipeProtectedMethod are available to Local System.'
}
catch {
    $hresult = [uint32]([int64]$_.Exception.HResult -band 0xFFFFFFFFL)
    Complete-Probe -Code 16 -Detail ("{0} (0x{1}): {2}" -f $_.Exception.GetType().FullName, $hresult.ToString('X8'), $_.Exception.Message)
}
'@

$wipePayloadTemplate = @'
$ErrorActionPreference = 'Stop'
$namespaceName = 'root\cimv2\mdm\dmmap'
$className = 'MDM_RemoteWipe'
$methodName = 'doWipeProtectedMethod'
$statusPath = '__WIPE_STATUS_PATH__'
$session = $null
$params = $null

function Write-WipeStatus {
    param(
        [Parameter(Mandatory)][string]$State,
        [Parameter(Mandatory)][string]$Detail
    )
    $singleLineDetail = $Detail -replace '[\r\n]+', ' '
    [IO.File]::WriteAllText(
        $statusPath,
        ("{0}|{1}|{2}" -f $State, [DateTime]::UtcNow.ToString('O'), $singleLineDetail),
        [Text.Encoding]::UTF8
    )
}

try {
    Write-WipeStatus -State 'STARTED' -Detail 'The Local System protected-wipe task started.'
    $session = New-CimSession
    $params = New-Object Microsoft.Management.Infrastructure.CimMethodParametersCollection
    $param = [Microsoft.Management.Infrastructure.CimMethodParameter]::Create('param', '', 'String', 'In')
    $params.Add($param)
    $instances = @(Get-CimInstance -Namespace $namespaceName -ClassName $className `
        -Filter "ParentID='./Vendor/MSFT' and InstanceID='RemoteWipe'" -OperationTimeoutSec 45)
    if ($instances.Count -ne 1) {
        Write-WipeStatus -State 'FAILED' -Detail ("Expected one RemoteWipe instance but received {0}." -f $instances.Count)
        exit 21
    }

    $result = $session.InvokeMethod($namespaceName, $instances[0], $methodName, $params)
    $returnValue = if ($null -eq $result.ReturnValue) { [uint32]0 } else { [uint32]$result.ReturnValue }
    if ($returnValue -ne 0) {
        Write-WipeStatus -State 'REJECTED' -Detail ("Microsoft returned 0x{0}." -f $returnValue.ToString('X8'))
        exit 22
    }

    Write-WipeStatus -State 'ACCEPTED' -Detail 'Microsoft accepted the protected-wipe request.'
    exit 0
}
catch {
    try {
        $hresult = [uint32]([int64]$_.Exception.HResult -band 0xFFFFFFFFL)
        Write-WipeStatus -State 'FAILED' -Detail ("{0} (0x{1}): {2}" -f $_.Exception.GetType().FullName, $hresult.ToString('X8'), $_.Exception.Message)
    }
    catch {}
    exit 23
}
finally {
    if ($null -ne $params) { try { $params.Dispose() } catch {} }
    if ($null -ne $session) { try { $session.Dispose() } catch {} }
}
'@

[void][scriptblock]::Create($probePayloadTemplate)
[void][scriptblock]::Create($wipePayloadTemplate)
if ($ValidationOnly) {
    Write-Host '[SUCCESS] Unattended protected-wipe payloads passed validation. Nothing was scheduled.'
    return
}

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Administrator approval is required; no wipe was scheduled.'
}

$windowsVersion = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
$editionId = [string]$windowsVersion.EditionID
if ($editionId -match '^(Core|Home|Starter)') {
    throw "Windows edition '$editionId' does not support Microsoft RemoteWipe; no wipe was scheduled."
}

$buildNumber = 0
if (-not [int]::TryParse([string]$windowsVersion.CurrentBuildNumber, [ref]$buildNumber) -or $buildNumber -lt 15063) {
    throw "Windows build '$($windowsVersion.CurrentBuildNumber)' does not support doWipeProtected; no wipe was scheduled."
}

$productType = [string](Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\ProductOptions' -Name ProductType).ProductType
if ($productType -ne 'WinNT') {
    throw "Microsoft RemoteWipe is not supported on Windows Server (product type '$productType'); no wipe was scheduled."
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

$reagentInfo = & $reagentPath /info 2>&1
if ($LASTEXITCODE -ne 0) {
    $details = ($reagentInfo | Out-String).Trim()
    throw "Windows Recovery Environment status could not be queried. $details"
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
    $arguments = "-NoLogo -NoProfile -NonInteractive -EncodedCommand $encoded"
    if ($arguments.Length -gt 30000) {
        throw "The scheduled-task command is too long ($($arguments.Length) characters); no wipe was scheduled."
    }
    $action = New-ScheduledTaskAction -Execute $powerShellPath -Argument $arguments
    $trigger = New-ScheduledTaskTrigger -Once -At $At
    $taskPrincipal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    # A missed destructive trigger must not run unexpectedly after a later boot or wake.
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
    [pscustomobject]@{ Action = $action; Trigger = $trigger; Principal = $taskPrincipal; Settings = $settings }
}

function Get-ProbeFailureText {
    param([Parameter(Mandatory)][int64]$Code)
    switch ($Code) {
        12 { 'the doWipeProtectedMethod method is missing' }
        13 { 'the RemoteWipe instance is unavailable' }
        14 { 'the MDM Bridge provider rejected or timed out the CIM request' }
        15 { 'the Local System CIM query failed unexpectedly' }
        16 { 'the RemoteWipe method metadata could not be inspected' }
        17 { 'the Local System probe could not write its status record' }
        default { "the probe process returned exit code $Code" }
    }
}

$statusDirectory = Join-Path $env:SystemRoot 'Temp'
if (-not (Test-Path -LiteralPath $statusDirectory -PathType Container)) {
    throw "The Local System status directory '$statusDirectory' is unavailable; no wipe was scheduled."
}

$probeTaskName = 'ScriptBox-WipeProbe-{0}' -f [guid]::NewGuid().ToString('N')
$probeStatusPath = Join-Path $statusDirectory ("$probeTaskName.status")
$escapedProbeStatusPath = $probeStatusPath.Replace("'", "''")
$probePayload = $probePayloadTemplate.Replace('__PROBE_STATUS_PATH__', $escapedProbeStatusPath)
[void][scriptblock]::Create($probePayload)
$probeParts = New-SystemTaskParts -Payload $probePayload -At (Get-Date).AddHours(1)
try {
    Write-Host '[INFO] Testing Microsoft protected-wipe support as Local System.'
    Register-ScheduledTask -TaskName $probeTaskName -Action $probeParts.Action -Trigger $probeParts.Trigger `
        -Principal $probeParts.Principal -Settings $probeParts.Settings -Force | Out-Null
    $probeInfoBefore = Get-ScheduledTaskInfo -TaskName $probeTaskName
    $probeStarted = Get-Date
    Start-ScheduledTask -TaskName $probeTaskName
    $probeDeadline = $probeStarted.AddSeconds(75)
    $probeStatusReady = $false
    $probeObservedRun = $false
    $probeFinished = $false
    do {
        Start-Sleep -Milliseconds 250
        $probeStatusReady = Test-Path -LiteralPath $probeStatusPath -PathType Leaf
        $probeTask = Get-ScheduledTask -TaskName $probeTaskName
        $probeInfo = Get-ScheduledTaskInfo -TaskName $probeTaskName
        $probeObservedRun = $probeInfo.LastRunTime -ne $probeInfoBefore.LastRunTime
        $probeFinished = $probeObservedRun -and $probeTask.State -ne 'Running'
    } while (-not $probeStatusReady -and -not $probeFinished -and (Get-Date) -lt $probeDeadline)

    if ($probeStatusReady) {
        $statusRecord = [IO.File]::ReadAllText($probeStatusPath, [Text.Encoding]::ASCII)
        $statusParts = @($statusRecord -split '\|', 2)
        $statusCode = 0
        if ($statusParts.Count -ne 2 -or -not [int]::TryParse($statusParts[0], [ref]$statusCode)) {
            throw 'The Local System compatibility test returned a malformed status record. No wipe was scheduled.'
        }
        try {
            $statusDetail = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($statusParts[1]))
        }
        catch {
            throw 'The Local System compatibility test returned an unreadable status record. No wipe was scheduled.'
        }
        if ($statusCode -ne 0) {
            $probeFailure = Get-ProbeFailureText -Code $statusCode
            throw "Microsoft protected wipe is unavailable: $probeFailure. Probe detail: $statusDetail No wipe was scheduled."
        }
        Write-Host "[INFO] $statusDetail"
    }
    elseif ($probeFinished) {
        $probeResult = [int64]$probeInfo.LastTaskResult
        $probeFailure = if ($probeResult -eq 0) {
            'the probe completed without producing its required status record'
        }
        else {
            Get-ProbeFailureText -Code $probeResult
        }
        throw "Microsoft protected wipe is unavailable: $probeFailure. No wipe was scheduled."
    }

    else {
        $probeState = [string]$probeTask.State
        $probeResult = [int64]$probeInfo.LastTaskResult
        $probeResultHex = [uint32]($probeResult -band 0xFFFFFFFFL)
        if ($probeTask.State -eq 'Running') {
            Stop-ScheduledTask -TaskName $probeTaskName -ErrorAction SilentlyContinue
        }
        throw ('The Local System compatibility test timed out after 75 seconds ' +
            "(task state $probeState, run observed $probeObservedRun, last result " +
            "0x$($probeResultHex.ToString('X8'))). No wipe was scheduled.")
    }
}
finally {
    Stop-ScheduledTask -TaskName $probeTaskName -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $probeTaskName -Confirm:$false -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $probeStatusPath -Force -ErrorAction SilentlyContinue
}

$wipeTaskName = 'ScriptBox-ProtectedWipe-{0}' -f [guid]::NewGuid().ToString('N')
$wipeStatusPath = Join-Path $statusDirectory ("$wipeTaskName.status")
$escapedWipeStatusPath = $wipeStatusPath.Replace("'", "''")
$wipePayload = $wipePayloadTemplate.Replace('__WIPE_STATUS_PATH__', $escapedWipeStatusPath)
[void][scriptblock]::Create($wipePayload)
$wipeAt = (Get-Date).AddSeconds(60)
$wipeParts = New-SystemTaskParts -Payload $wipePayload -At $wipeAt
Register-ScheduledTask -TaskName $wipeTaskName -Action $wipeParts.Action -Trigger $wipeParts.Trigger `
    -Principal $wipeParts.Principal -Settings $wipeParts.Settings -Force | Out-Null

$registeredWipeTask = Get-ScheduledTask -TaskName $wipeTaskName
if ($registeredWipeTask.State -eq 'Disabled') {
    Unregister-ScheduledTask -TaskName $wipeTaskName -Confirm:$false -ErrorAction SilentlyContinue
    throw 'The protected-wipe task was registered in a disabled state; no wipe was scheduled.'
}

Write-Host '[WARNING] UNATTENDED PROTECTED WIPE SCHEDULED.'
Write-Host '[WARNING] Every partition on the internal Windows disk, including D: on that disk, will be permanently cleaned.'
Write-Host '[WARNING] Keep the PC connected to power. Do not interrupt it after recovery begins.'
Write-Host ("[WARNING] The wipe starts at {0}. To cancel before then, run as administrator:" -f $wipeAt.ToString('HH:mm:ss'))
Write-Host ("Stop-ScheduledTask -TaskName '{0}' -ErrorAction SilentlyContinue; Unregister-ScheduledTask -TaskName '{0}' -Confirm:`$false" -f $wipeTaskName)
Write-Host ("[INFO] If Windows does not enter recovery, inspect the failure status at '{0}'." -f $wipeStatusPath)
Write-Host '[SUCCESS] No further interaction is required until Windows reaches its first-run setup screen.'
