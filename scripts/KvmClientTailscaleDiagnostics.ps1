#requires -Version 5.1
<#
.SYNOPSIS
    ScriptBox KVM client-side Tailscale diagnostics.
.DESCRIPTION
    Run this on the computer being used to view/control a JetKVM.
    The script asks only for the KVM machine name, resolves it from
    `tailscale status --json`, tests the connection, and explains the results.

    No device names or target IP addresses are hardcoded.
.NOTES
    This script is read-only. It does not change Tailscale, Windows Firewall,
    routes, DNS, or the JetKVM.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$KvmName,

    [ValidateRange(3, 30)]
    [int]$PingCount = 10,

    [switch]$NoReportFile,

    [switch]$NonInteractive,

    [switch]$ValidationOnly
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:Results = New-Object System.Collections.Generic.List[object]

function Stop-Diagnostic {
    param([Parameter(Mandatory = $true)][string]$Message)

    if ($NonInteractive) { throw $Message }
    Read-Host 'Press Enter to close' | Out-Null
    exit 1
}

function Write-Title {
    param([string]$Text)
    Write-Host ''
    Write-Host ('=' * 76) -ForegroundColor DarkCyan
    Write-Host ('  ' + $Text) -ForegroundColor Cyan
    Write-Host ('=' * 76) -ForegroundColor DarkCyan
}

function Add-DiagnosticResult {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('GREEN', 'AMBER', 'RED', 'INFO')]
        [string]$Status,
        [Parameter(Mandatory = $true)]
        [string]$Test,
        [Parameter(Mandatory = $true)]
        [string]$Value,
        [Parameter(Mandatory = $true)]
        [string]$Message,
        [string]$Note = ''
    )

    $colour = switch ($Status) {
        'GREEN' { 'Green' }
        'AMBER' { 'Yellow' }
        'RED'   { 'Red' }
        default { 'Cyan' }
    }

    $label = switch ($Status) {
        'GREEN' { '[GOOD]' }
        'AMBER' { '[CHECK]' }
        'RED'   { '[BAD]' }
        default { '[INFO]' }
    }

    Write-Host ''
    Write-Host ($label.PadRight(8) + ' ' + $Test) -ForegroundColor $colour
    Write-Host ('         Result : ' + $Value) -ForegroundColor White
    Write-Host ('         Message: ' + $Message) -ForegroundColor Gray
    if (-not [string]::IsNullOrWhiteSpace($Note)) {
        Write-Host ('         Note   : ' + $Note) -ForegroundColor DarkGray
    }

    $script:Results.Add([pscustomobject]@{
        Status  = $Status
        Test    = $Test
        Value   = $Value
        Message = $Message
        Note    = $Note
    }) | Out-Null
}

function Get-TailscaleExecutable {
    $command = Get-Command 'tailscale.exe' -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }

    $knownPaths = @()
    if ($env:ProgramFiles) {
        $knownPaths += (Join-Path $env:ProgramFiles 'Tailscale\tailscale.exe')
    }
    if (${env:ProgramFiles(x86)}) {
        $knownPaths += (Join-Path ${env:ProgramFiles(x86)} 'Tailscale\tailscale.exe')
    }

    foreach ($path in $knownPaths) {
        if (Test-Path -LiteralPath $path) { return $path }
    }

    return $null
}

function Invoke-Tailscale {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,
        [int]$TimeoutSeconds = 45
    )

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $script:TailscaleExe
    $psi.Arguments = ($Arguments | ForEach-Object {
        if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ }
    }) -join ' '
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi
    [void]$process.Start()

    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
        try { $process.Kill() } catch { }
        return [pscustomobject]@{
            ExitCode = 124
            Output   = ''
            Error    = "Command timed out after $TimeoutSeconds seconds."
        }
    }

    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()

    return [pscustomobject]@{
        ExitCode = $process.ExitCode
        Output   = $stdout.Trim()
        Error    = $stderr.Trim()
    }
}

function Get-AllPeers {
    param([Parameter(Mandatory = $true)]$StatusObject)

    $items = @()
    if ($null -eq $StatusObject.Peer) { return $items }

    foreach ($property in $StatusObject.Peer.PSObject.Properties) {
        $peer = $property.Value
        $dnsShort = ''
        if ($peer.PSObject.Properties.Name -contains 'DNSName' -and $peer.DNSName) {
            $dnsShort = ([string]$peer.DNSName).TrimEnd('.').Split('.')[0]
        }

        $ips = @()
        if ($peer.PSObject.Properties.Name -contains 'TailscaleIPs') {
            $ips = @($peer.TailscaleIPs)
        }

        $hostName = if ($peer.PSObject.Properties.Name -contains 'HostName') { [string]$peer.HostName } else { '' }
        $dnsName = if ($peer.PSObject.Properties.Name -contains 'DNSName') { [string]$peer.DNSName } else { '' }

        $items += [pscustomobject]@{
            Key          = $property.Name
            HostName     = $hostName
            DNSName      = $dnsName
            DNSShortName = $dnsShort
            TailscaleIPs = $ips
            Online       = if ($peer.PSObject.Properties.Name -contains 'Online') { [bool]$peer.Online } else { $null }
            Active       = if ($peer.PSObject.Properties.Name -contains 'Active') { [bool]$peer.Active } else { $null }
            Relay        = if ($peer.PSObject.Properties.Name -contains 'Relay') { [string]$peer.Relay } else { '' }
            CurAddr      = if ($peer.PSObject.Properties.Name -contains 'CurAddr') { [string]$peer.CurAddr } else { '' }
            LastSeen     = if ($peer.PSObject.Properties.Name -contains 'LastSeen') { [string]$peer.LastSeen } else { '' }
            OS           = if ($peer.PSObject.Properties.Name -contains 'OS') { [string]$peer.OS } else { '' }
        }
    }

    return $items
}

function Resolve-KvmPeer {
    param(
        [Parameter(Mandatory = $true)][object[]]$Peers,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $clean = $Name.Trim().TrimEnd('.')
    if ([string]::IsNullOrWhiteSpace($clean)) { return $null }

    $exact = @($Peers | Where-Object {
        $_.HostName -ieq $clean -or
        $_.DNSName.TrimEnd('.') -ieq $clean -or
        $_.DNSShortName -ieq $clean
    })
    if ($exact.Count -eq 1) { return $exact[0] }

    $partial = @($Peers | Where-Object {
        $_.HostName -ilike "*$clean*" -or
        $_.DNSName -ilike "*$clean*"
    })
    if ($partial.Count -eq 1) { return $partial[0] }

    if ($exact.Count -gt 1) { return $exact }
    if ($partial.Count -gt 1) { return $partial }
    return $null
}

function Get-IPv4FromPeer {
    param([Parameter(Mandatory = $true)]$Peer)
    foreach ($ip in @($Peer.TailscaleIPs)) {
        if ([string]$ip -match '^\d{1,3}(\.\d{1,3}){3}$') { return [string]$ip }
    }
    if (@($Peer.TailscaleIPs).Count -gt 0) { return [string]$Peer.TailscaleIPs[0] }
    return $null
}

function Parse-NetcheckText {
    param([string]$Text)

    $data = [ordered]@{
        UDP                    = $null
        IPv4                  = ''
        IPv6                  = ''
        MappingVariesByDestIP = $null
        HairPinning           = $null
        PortMapping           = ''
        CaptivePortal         = $null
        NearestDERP           = ''
    }

    foreach ($line in ($Text -split "`r?`n")) {
        if ($line -match '^\s*\*\s*UDP:\s*(true|false)') {
            $data.UDP = [bool]::Parse($Matches[1])
        } elseif ($line -match '^\s*\*\s*IPv4:\s*(.+)$') {
            $data.IPv4 = $Matches[1].Trim()
        } elseif ($line -match '^\s*\*\s*IPv6:\s*(.+)$') {
            $data.IPv6 = $Matches[1].Trim()
        } elseif ($line -match '^\s*\*\s*MappingVariesByDestIP:\s*(true|false)') {
            $data.MappingVariesByDestIP = [bool]::Parse($Matches[1])
        } elseif ($line -match '^\s*\*\s*HairPinning:\s*(true|false)') {
            $data.HairPinning = [bool]::Parse($Matches[1])
        } elseif ($line -match '^\s*\*\s*PortMapping:\s*(.*)$') {
            $data.PortMapping = $Matches[1].Trim()
        } elseif ($line -match '^\s*\*\s*CaptivePortal:\s*(true|false)') {
            $data.CaptivePortal = [bool]::Parse($Matches[1])
        } elseif ($line -match '^\s*\*\s*Nearest DERP:\s*(.*)$') {
            $data.NearestDERP = $Matches[1].Trim()
        }
    }

    return [pscustomobject]$data
}

function Get-PingMeasurements {
    param([string]$Text)

    $values = New-Object System.Collections.Generic.List[double]
    foreach ($line in ($Text -split "`r?`n")) {
        if ($line -match '\bin\s+([0-9]+(?:\.[0-9]+)?)ms\b') {
            $values.Add([double]$Matches[1]) | Out-Null
        }
    }
    return @($values)
}

function Get-ConnectionTypeFromPing {
    param([string]$Text)

    # Tailscale can begin through DERP and then upgrade to direct during the
    # same command. Use the last classified pong line, which represents the
    # final path observed by this test.
    $last = [pscustomobject]@{ Type = 'Unknown'; Detail = '' }
    foreach ($line in ($Text -split "`r?`n")) {
        if ($line -match '\bvia\s+DERP\(([^\)]+)\)') {
            $last = [pscustomobject]@{ Type = 'DERP relay'; Detail = $Matches[1] }
        } elseif ($line -match '\bvia\s+peer-relay\b([^\r\n]*)') {
            $last = [pscustomobject]@{ Type = 'Peer relay'; Detail = $Matches[1].Trim() }
        } elseif ($line -match '\bvia\s+([\[\]0-9a-fA-F:\.]+:\d+)') {
            $last = [pscustomobject]@{ Type = 'Direct'; Detail = $Matches[1] }
        }
    }
    return $last
}

function Get-Stats {
    param([double[]]$Values)
    if ($null -eq $Values -or $Values.Count -eq 0) { return $null }

    $average = ($Values | Measure-Object -Average).Average
    $minimum = ($Values | Measure-Object -Minimum).Minimum
    $maximum = ($Values | Measure-Object -Maximum).Maximum

    $variance = 0.0
    foreach ($value in $Values) {
        $variance += [math]::Pow(($value - $average), 2)
    }
    $variance = $variance / $Values.Count
    $jitter = [math]::Sqrt($variance)

    return [pscustomobject]@{
        Average = [math]::Round($average, 1)
        Minimum = [math]::Round($minimum, 1)
        Maximum = [math]::Round($maximum, 1)
        Jitter  = [math]::Round($jitter, 1)
    }
}

function Test-TcpPort {
    param([string]$ComputerName, [int]$Port, [int]$TimeoutMilliseconds = 3000)

    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $async = $client.BeginConnect($ComputerName, $Port, $null, $null)
        if (-not $async.AsyncWaitHandle.WaitOne($TimeoutMilliseconds, $false)) {
            return $false
        }
        $client.EndConnect($async)
        return $true
    } catch {
        return $false
    } finally {
        $client.Close()
    }
}

function Save-PlainTextReport {
    param([string]$ResolvedName, [string]$TargetIP)

    $downloads = Join-Path $env:USERPROFILE 'Downloads'
    if (-not (Test-Path -LiteralPath $downloads)) { $downloads = $env:TEMP }

    $safeName = ($ResolvedName -replace '[^a-zA-Z0-9._-]', '_')
    $path = Join-Path $downloads ("ScriptBox-KVM-Client-{0}-{1}.txt" -f $safeName, (Get-Date -Format 'yyyyMMdd-HHmmss'))

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('ScriptBox KVM Client Diagnostics') | Out-Null
    $lines.Add(('Generated: {0}' -f (Get-Date))) | Out-Null
    $lines.Add(('KVM: {0}' -f $ResolvedName)) | Out-Null
    $lines.Add(('Target: {0}' -f $TargetIP)) | Out-Null
    $lines.Add('') | Out-Null

    foreach ($item in $script:Results) {
        $lines.Add(('[{0}] {1}' -f $item.Status, $item.Test)) | Out-Null
        $lines.Add(('  Result : {0}' -f $item.Value)) | Out-Null
        $lines.Add(('  Message: {0}' -f $item.Message)) | Out-Null
        if ($item.Note) { $lines.Add(('  Note   : {0}' -f $item.Note)) | Out-Null }
        $lines.Add('') | Out-Null
    }

    $lines | Set-Content -LiteralPath $path -Encoding UTF8
    return $path
}

if ($ValidationOnly) {
    Write-Output 'ScriptBox KVM client diagnostic validation passed.'
    return
}

if (-not $NonInteractive) { Clear-Host }
Write-Title 'ScriptBox - KVM Client Connection Diagnostics'
Write-Host 'Run this on the computer used to view the KVM.' -ForegroundColor Gray
Write-Host 'For a realistic load test, leave the KVM video stream open while this runs.' -ForegroundColor Gray

$script:TailscaleExe = Get-TailscaleExecutable
if (-not $script:TailscaleExe) {
    Add-DiagnosticResult -Status RED -Test 'Tailscale installation' -Value 'Not found' `
        -Message 'Tailscale must be installed on this computer before the KVM can be tested.' `
        -Note 'Install Tailscale or add tailscale.exe to PATH, then run this script again.'
    Stop-Diagnostic -Message 'Tailscale is not installed or tailscale.exe could not be found.'
}

Add-DiagnosticResult -Status GREEN -Test 'Tailscale installation' -Value $script:TailscaleExe `
    -Message 'The Tailscale command-line tool is available.'

try {
    $service = Get-Service -Name 'Tailscale' -ErrorAction SilentlyContinue
    if ($service -and $service.Status -eq 'Running') {
        Add-DiagnosticResult -Status GREEN -Test 'Tailscale service' -Value 'Running' `
            -Message 'The Windows Tailscale service is running.'
    } elseif ($service) {
        Add-DiagnosticResult -Status RED -Test 'Tailscale service' -Value ([string]$service.Status) `
            -Message 'The Tailscale service is installed but is not running.' `
            -Note 'Start the Tailscale service or open the Tailscale application.'
    } else {
        Add-DiagnosticResult -Status AMBER -Test 'Tailscale service' -Value 'Service not detected' `
            -Message 'The CLI was found, but the Windows service could not be identified.'
    }
} catch {
    Add-DiagnosticResult -Status AMBER -Test 'Tailscale service' -Value 'Unable to inspect' `
        -Message $_.Exception.Message
}

$statusRun = Invoke-Tailscale -Arguments @('status', '--json') -TimeoutSeconds 20
if ($statusRun.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($statusRun.Output)) {
    Add-DiagnosticResult -Status RED -Test 'Tailscale sign-in state' -Value 'Unavailable' `
        -Message 'Tailscale did not return its device list.' `
        -Note (($statusRun.Error + ' ' + $statusRun.Output).Trim())
    Stop-Diagnostic -Message 'Tailscale did not return its device list.'
}

try {
    $statusObject = $statusRun.Output | ConvertFrom-Json
} catch {
    Add-DiagnosticResult -Status RED -Test 'Tailscale status data' -Value 'Invalid JSON' `
        -Message 'The Tailscale status response could not be read.' `
        -Note $_.Exception.Message
    Stop-Diagnostic -Message 'Tailscale returned invalid status data.'
}

if ([string]$statusObject.BackendState -eq 'Running') {
    Add-DiagnosticResult -Status GREEN -Test 'Tailscale sign-in state' -Value 'Connected' `
        -Message 'This computer is connected to a tailnet.'
} else {
    Add-DiagnosticResult -Status RED -Test 'Tailscale sign-in state' -Value ([string]$statusObject.BackendState) `
        -Message 'This computer is not fully connected to Tailscale.' `
        -Note 'Open Tailscale and sign in before retrying.'
    Stop-Diagnostic -Message 'This computer is not connected to Tailscale.'
}

if ($statusObject.PSObject.Properties.Name -contains 'Health' -and @($statusObject.Health).Count -gt 0) {
    Add-DiagnosticResult -Status AMBER -Test 'Tailscale health warnings' -Value ((@($statusObject.Health) -join '; ')) `
        -Message 'Tailscale has reported one or more local health warnings.' `
        -Note 'A DNS warning does not normally explain poor performance when the KVM is opened by IP, but it should still be corrected.'
} else {
    Add-DiagnosticResult -Status GREEN -Test 'Tailscale health warnings' -Value 'None reported' `
        -Message 'Tailscale is not currently reporting a local health warning.'
}

$peers = @(Get-AllPeers -StatusObject $statusObject)
if ($peers.Count -eq 0) {
    Add-DiagnosticResult -Status RED -Test 'Tailnet device list' -Value 'No peers found' `
        -Message 'No other Tailscale devices were returned.'
    Stop-Diagnostic -Message 'No Tailscale peers were found.'
}

while ($true) {
    if ([string]::IsNullOrWhiteSpace($KvmName)) {
        if ($NonInteractive) { throw 'A KVM machine name is required.' }
        Write-Host ''
        $KvmName = Read-Host 'Enter the KVM machine name shown in Tailscale (example: kvm-site01)'
    }

    $resolved = Resolve-KvmPeer -Peers $peers -Name $KvmName
    if ($null -eq $resolved) {
        Write-Host ''
        Write-Host ('[BAD] No matching device was found for: ' + $KvmName) -ForegroundColor Red
        Write-Host 'Check the spelling and confirm the KVM is registered in the same tailnet.' -ForegroundColor Gray
        if ($NonInteractive) { throw "No Tailscale device matched '$KvmName'." }
        $KvmName = ''
        continue
    }

    if ($resolved -is [array]) {
        Write-Host ''
        Write-Host 'More than one device matched that name:' -ForegroundColor Yellow
        foreach ($candidate in $resolved) {
            Write-Host ('  - ' + $candidate.HostName + '  ' + ($candidate.TailscaleIPs -join ', ')) -ForegroundColor Gray
        }
        Write-Host 'Enter the complete unique KVM name.' -ForegroundColor Yellow
        if ($NonInteractive) { throw "More than one Tailscale device matched '$KvmName'. Enter the complete unique name." }
        $KvmName = ''
        continue
    }

    $peer = $resolved
    break
}

$targetIP = Get-IPv4FromPeer -Peer $peer
if ([string]::IsNullOrWhiteSpace($targetIP)) {
    Add-DiagnosticResult -Status RED -Test 'KVM address' -Value 'No address available' `
        -Message 'The selected peer has no usable Tailscale address.'
    Stop-Diagnostic -Message 'The selected KVM has no usable Tailscale address.'
}

Add-DiagnosticResult -Status GREEN -Test 'KVM name lookup' -Value ("{0} ({1})" -f $peer.HostName, $targetIP) `
    -Message 'The KVM name was resolved from the current Tailscale device list.' `
    -Note 'The address was discovered automatically and was not hardcoded in the script.'

if ($peer.Online -eq $true) {
    Add-DiagnosticResult -Status GREEN -Test 'KVM online state' -Value 'Online' `
        -Message 'Tailscale reports the KVM as online.'
} elseif ($peer.Online -eq $false) {
    Add-DiagnosticResult -Status RED -Test 'KVM online state' -Value 'Offline' `
        -Message 'Tailscale reports the KVM as offline.' `
        -Note ('Last seen: ' + $peer.LastSeen)
} else {
    Add-DiagnosticResult -Status AMBER -Test 'KVM online state' -Value 'Not reported' `
        -Message 'The installed Tailscale version did not return a definite online state.'
}

Write-Host ''
Write-Host 'Running Tailscale route and latency tests...' -ForegroundColor Cyan
$routePingRun = Invoke-Tailscale -Arguments @('ping', '--c=5', '--timeout=5s', '--until-direct=false', $targetIP) -TimeoutSeconds 35
$connection = Get-ConnectionTypeFromPing -Text ($routePingRun.Output + "`n" + $routePingRun.Error)

# Use ICMP-level Tailscale pings for the latency sample so the measurements
# travel through WireGuard rather than only checking discovery/path setup.
$latencyPingRun = Invoke-Tailscale -Arguments @('ping', '--icmp', "--c=$PingCount", '--timeout=5s', '--until-direct=false', $targetIP) -TimeoutSeconds ([math]::Max(35, $PingCount * 6))
$measurements = @(Get-PingMeasurements -Text ($latencyPingRun.Output + "`n" + $latencyPingRun.Error))
$measurementTarget = $PingCount
if ($measurements.Count -eq 0) {
    # Older clients or restrictive policies may prevent ICMP-level testing.
    # Fall back to the five route-ping measurements rather than returning nothing.
    $measurements = @(Get-PingMeasurements -Text ($routePingRun.Output + "`n" + $routePingRun.Error))
    $measurementTarget = 5
    Add-DiagnosticResult -Status AMBER -Test 'Latency test mode' -Value 'Route-ping fallback' `
        -Message 'ICMP-level Tailscale pings did not return measurements.' `
        -Note 'Latency is being estimated from Tailscale path-discovery pings instead.'
} else {
    Add-DiagnosticResult -Status GREEN -Test 'Latency test mode' -Value 'ICMP through WireGuard' `
        -Message 'Latency measurements traversed the encrypted Tailscale data path.'
}

switch ($connection.Type) {
    'Direct' {
        Add-DiagnosticResult -Status GREEN -Test 'Tailscale connection path' -Value ("Direct - {0}" -f $connection.Detail) `
            -Message 'KVM traffic is using a direct peer-to-peer UDP path.' `
            -Note 'DERP may still assist with discovery, but it is not carrying the active data path shown here.'
    }
    'Peer relay' {
        Add-DiagnosticResult -Status AMBER -Test 'Tailscale connection path' -Value ("Peer relay - {0}" -f $connection.Detail) `
            -Message 'Traffic is passing through another Tailscale device rather than directly to the KVM.' `
            -Note 'This can perform better than DERP but still adds a network hop.'
    }
    'DERP relay' {
        Add-DiagnosticResult -Status RED -Test 'Tailscale connection path' -Value ("DERP relay - {0}" -f $connection.Detail) `
            -Message 'The active KVM path is relayed and will usually be slower than a direct connection.' `
            -Note 'Check UDP availability, hard NAT, CGNAT/double NAT, firewall policy, and port-mapping support at both ends.'
    }
    default {
        Add-DiagnosticResult -Status AMBER -Test 'Tailscale connection path' -Value 'Could not classify' `
            -Message 'The ping output did not clearly identify direct or relayed transport.' `
            -Note (($routePingRun.Error + ' ' + $routePingRun.Output).Trim())
    }
}

if ($measurements.Count -eq 0) {
    Add-DiagnosticResult -Status RED -Test 'Tailscale ping replies' -Value '0 replies' `
        -Message 'The KVM did not return a Tailscale ping during the test.' `
        -Note 'Confirm ACL/grant permissions, KVM online state, and network reachability.'
} else {
    $successPercent = [math]::Round(($measurements.Count / [double]$measurementTarget) * 100, 0)
    if ($successPercent -ge 100) {
        Add-DiagnosticResult -Status GREEN -Test 'Tailscale ping replies' -Value ("{0}/{1} ({2}%)" -f $measurements.Count, $measurementTarget, $successPercent) `
            -Message 'All requested Tailscale pings returned.'
    } elseif ($successPercent -ge 80) {
        Add-DiagnosticResult -Status AMBER -Test 'Tailscale ping replies' -Value ("{0}/{1} ({2}%)" -f $measurements.Count, $measurementTarget, $successPercent) `
            -Message 'Some replies were missed or timed out.' `
            -Note 'Occasional loss can cause visible pauses and an expanding JetKVM playback buffer.'
    } else {
        Add-DiagnosticResult -Status RED -Test 'Tailscale ping replies' -Value ("{0}/{1} ({2}%)" -f $measurements.Count, $measurementTarget, $successPercent) `
            -Message 'The connection has severe loss or repeated timeouts.' `
            -Note 'Test another ISP/hotspot and inspect upload saturation or packet loss at the KVM site.'
    }

    $stats = Get-Stats -Values $measurements
    $latencyValue = "Average {0} ms; min {1} ms; max {2} ms" -f $stats.Average, $stats.Minimum, $stats.Maximum
    if ($stats.Average -lt 150) {
        Add-DiagnosticResult -Status GREEN -Test 'Round-trip latency' -Value $latencyValue `
            -Message 'Latency is suitable for responsive remote KVM use.'
    } elseif ($stats.Average -lt 300) {
        Add-DiagnosticResult -Status AMBER -Test 'Round-trip latency' -Value $latencyValue `
            -Message 'The KVM will be usable, but input and video will feel delayed.' `
            -Note 'Long-distance international routes may naturally fall into this range.'
    } else {
        Add-DiagnosticResult -Status RED -Test 'Round-trip latency' -Value $latencyValue `
            -Message 'Latency is poor for interactive KVM control.' `
            -Note 'Try a different ISP/path, reduce video quality, and check for upload congestion or bufferbloat.'
    }

    if ($stats.Jitter -lt 20) {
        Add-DiagnosticResult -Status GREEN -Test 'Latency variation (jitter)' -Value ("{0} ms" -f $stats.Jitter) `
            -Message 'Reply times are reasonably steady.'
    } elseif ($stats.Jitter -lt 75) {
        Add-DiagnosticResult -Status AMBER -Test 'Latency variation (jitter)' -Value ("{0} ms" -f $stats.Jitter) `
            -Message 'The route has noticeable variation.' `
            -Note 'JetKVM may add playback buffering to smooth uneven packet arrival.'
    } else {
        Add-DiagnosticResult -Status RED -Test 'Latency variation (jitter)' -Value ("{0} ms" -f $stats.Jitter) `
            -Message 'The connection is highly unstable.' `
            -Note 'Check Wi-Fi quality, ISP congestion, packet loss, and loaded latency at both locations.'
    }
}

Write-Host ''
Write-Host 'Checking the local network conditions reported by Tailscale...' -ForegroundColor Cyan
$netcheckRun = Invoke-Tailscale -Arguments @('netcheck') -TimeoutSeconds 45
if ($netcheckRun.ExitCode -eq 0 -and $netcheckRun.Output) {
    $netcheck = Parse-NetcheckText -Text $netcheckRun.Output

    if ($netcheck.UDP -eq $true) {
        Add-DiagnosticResult -Status GREEN -Test 'Local UDP support' -Value 'Available' `
            -Message 'This network can exchange UDP traffic, which is required for the best direct paths.'
    } elseif ($netcheck.UDP -eq $false) {
        Add-DiagnosticResult -Status RED -Test 'Local UDP support' -Value 'Unavailable' `
            -Message 'UDP appears blocked on this network.' `
            -Note 'Tailscale is likely to rely on relays until outbound and return UDP traffic is allowed.'
    } else {
        Add-DiagnosticResult -Status AMBER -Test 'Local UDP support' -Value 'Inconclusive' `
            -Message 'Tailscale could not determine whether UDP is available.'
    }

    if ($netcheck.MappingVariesByDestIP -eq $false) {
        Add-DiagnosticResult -Status GREEN -Test 'Local NAT behaviour' -Value 'Endpoint-independent/easier NAT' `
            -Message 'The local NAT mapping does not vary by destination.'
    } elseif ($netcheck.MappingVariesByDestIP -eq $true) {
        Add-DiagnosticResult -Status RED -Test 'Local NAT behaviour' -Value 'Hard NAT detected' `
            -Message 'The router changes mappings depending on the destination.' `
            -Note 'Hard NAT makes direct peer-to-peer connections harder and can cause DERP fallback.'
    } else {
        Add-DiagnosticResult -Status AMBER -Test 'Local NAT behaviour' -Value 'Not measured' `
            -Message 'The NAT mapping type could not be determined.'
    }

    if ([string]::IsNullOrWhiteSpace($netcheck.PortMapping)) {
        Add-DiagnosticResult -Status AMBER -Test 'Automatic port mapping' -Value 'None detected' `
            -Message 'UPnP, NAT-PMP, or PCP was not detected on this router.' `
            -Note 'Direct connections can still work, but automatic port mapping can make them more reliable.'
    } else {
        Add-DiagnosticResult -Status GREEN -Test 'Automatic port mapping' -Value $netcheck.PortMapping `
            -Message 'The router advertises at least one automatic port-mapping method.'
    }

    if ($netcheck.CaptivePortal -eq $true) {
        Add-DiagnosticResult -Status RED -Test 'Captive portal' -Value 'Detected' `
            -Message 'The network may require browser sign-in or interception.'
    } else {
        Add-DiagnosticResult -Status GREEN -Test 'Captive portal' -Value 'Not detected' `
            -Message 'No captive portal was detected.'
    }

    if ($netcheck.NearestDERP) {
        Add-DiagnosticResult -Status INFO -Test 'Nearest DERP region' -Value $netcheck.NearestDERP `
            -Message 'This is the closest measured fallback relay, not necessarily the active KVM path.'
    }
} else {
    Add-DiagnosticResult -Status AMBER -Test 'Tailscale netcheck' -Value 'Could not complete' `
        -Message 'Local NAT and UDP details were not available.' `
        -Note (($netcheckRun.Error + ' ' + $netcheckRun.Output).Trim())
}

Write-Host ''
Write-Host 'Checking JetKVM web reachability over the tailnet...' -ForegroundColor Cyan
$port80 = Test-TcpPort -ComputerName $targetIP -Port 80
$port443 = Test-TcpPort -ComputerName $targetIP -Port 443
if ($port80 -or $port443) {
    $openPorts = @()
    if ($port80) { $openPorts += '80' }
    if ($port443) { $openPorts += '443' }
    Add-DiagnosticResult -Status GREEN -Test 'KVM web interface reachability' -Value ('TCP ' + ($openPorts -join ', ')) `
        -Message 'At least one standard JetKVM web port is reachable over Tailscale.'
} else {
    Add-DiagnosticResult -Status RED -Test 'KVM web interface reachability' -Value 'TCP 80/443 unavailable' `
        -Message 'The standard web ports could not be reached.' `
        -Note 'The KVM may use a custom port, be offline, or be blocked by tailnet permissions or local firewall rules.'
}

Write-Title 'Summary'
$redCount = @($script:Results | Where-Object Status -eq 'RED').Count
$amberCount = @($script:Results | Where-Object Status -eq 'AMBER').Count
$greenCount = @($script:Results | Where-Object Status -eq 'GREEN').Count

if ($redCount -gt 0) {
    Write-Host ("Overall: RED - {0} serious issue(s), {1} warning(s), {2} good check(s)." -f $redCount, $amberCount, $greenCount) -ForegroundColor Red
    Write-Host 'Start with the RED results. They are the most likely causes of an unusable KVM session.' -ForegroundColor Gray
} elseif ($amberCount -gt 0) {
    Write-Host ("Overall: AMBER - no critical failure, but {0} warning(s) need review." -f $amberCount) -ForegroundColor Yellow
    Write-Host 'The route works, but one or more conditions may reduce responsiveness or reliability.' -ForegroundColor Gray
} else {
    Write-Host 'Overall: GREEN - no obvious connectivity fault was found.' -ForegroundColor Green
    Write-Host 'If video is still slow, compare ping results with the video closed and open to detect upload saturation or bufferbloat.' -ForegroundColor Gray
}

if (-not $NoReportFile) {
    try {
        $reportPath = Save-PlainTextReport -ResolvedName $peer.HostName -TargetIP $targetIP
        Write-Host ''
        Write-Host ('Report saved to: ' + $reportPath) -ForegroundColor Cyan
    } catch {
        Write-Host ''
        Write-Host ('The report could not be saved: ' + $_.Exception.Message) -ForegroundColor Yellow
    }
}

Write-Host ''
if (-not $NonInteractive) { Read-Host 'Press Enter to close' | Out-Null }
