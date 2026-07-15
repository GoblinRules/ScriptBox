#requires -Version 5.1
<#
.SYNOPSIS
    ScriptBox KVM-site network, NAT, firewall, and port-path diagnostics.
.DESCRIPTION
    Run this on a Windows PC connected to the same router/network as the KVM.
    The script asks for the KVM name only as a report label and, when Tailscale
    is present, attempts to resolve that device automatically.

    It checks:
      - Default gateway and local adapter
      - Public IP discovery
      - Likely double NAT or CGNAT
      - UPnP Internet Gateway Device WAN address, when available
      - Outbound TCP 80/443
      - UDP/STUN on port 3478
      - Tailscale netcheck NAT characteristics, when Tailscale is installed
      - Automatic port mapping support (UPnP/NAT-PMP/PCP)
      - Windows Firewall outbound policy
      - Extra private/CGNAT hops near the start of the internet route

    Important: a script running inside the LAN cannot prove that unsolicited
    inbound UDP reaches the KVM. It can verify the conditions Tailscale uses
    for NAT traversal and identify likely blockers.
.NOTES
    This script is read-only and makes no network, firewall, or router changes.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$KvmName,

    [switch]$NoReportFile,

    [switch]$NonInteractive,

    [switch]$ValidationOnly
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$script:Results = New-Object System.Collections.Generic.List[object]

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
        [Parameter(Mandatory = $true)][string]$Test,
        [Parameter(Mandatory = $true)][string]$Value,
        [Parameter(Mandatory = $true)][string]$Message,
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
    if ($Note) { Write-Host ('         Note   : ' + $Note) -ForegroundColor DarkGray }

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

    $paths = @()
    if ($env:ProgramFiles) {
        $paths += (Join-Path $env:ProgramFiles 'Tailscale\tailscale.exe')
    }
    if (${env:ProgramFiles(x86)}) {
        $paths += (Join-Path ${env:ProgramFiles(x86)} 'Tailscale\tailscale.exe')
    }

    foreach ($path in $paths) {
        if (Test-Path -LiteralPath $path) { return $path }
    }
    return $null
}

function Invoke-ExternalProcess {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [int]$TimeoutSeconds = 45
    )

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
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
        return [pscustomobject]@{ ExitCode = 124; Output = ''; Error = "Timed out after $TimeoutSeconds seconds." }
    }

    return [pscustomobject]@{
        ExitCode = $process.ExitCode
        Output   = $process.StandardOutput.ReadToEnd().Trim()
        Error    = $process.StandardError.ReadToEnd().Trim()
    }
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

function Test-TcpPort {
    param([string]$ComputerName, [int]$Port, [int]$TimeoutMilliseconds = 4000)

    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $async = $client.BeginConnect($ComputerName, $Port, $null, $null)
        if (-not $async.AsyncWaitHandle.WaitOne($TimeoutMilliseconds, $false)) { return $false }
        $client.EndConnect($async)
        return $true
    } catch {
        return $false
    } finally {
        $client.Close()
    }
}

function Get-IPv4Category {
    param([string]$Address)

    try {
        $parsed = [System.Net.IPAddress]::Parse($Address)
    } catch {
        return 'Invalid'
    }
    $bytes = $parsed.GetAddressBytes()
    if ($bytes.Length -ne 4) { return 'IPv6' }

    if ($bytes[0] -eq 10) { return 'RFC1918' }
    if ($bytes[0] -eq 172 -and $bytes[1] -ge 16 -and $bytes[1] -le 31) { return 'RFC1918' }
    if ($bytes[0] -eq 192 -and $bytes[1] -eq 168) { return 'RFC1918' }
    if ($bytes[0] -eq 100 -and $bytes[1] -ge 64 -and $bytes[1] -le 127) { return 'CGNAT' }
    if ($bytes[0] -eq 169 -and $bytes[1] -eq 254) { return 'LinkLocal' }
    if ($bytes[0] -eq 127) { return 'Loopback' }
    if ($bytes[0] -eq 0 -or $bytes[0] -ge 224) { return 'Reserved' }
    return 'Public'
}

function Get-PublicIPv4 {
    $providers = @(
        [pscustomobject]@{
            Name = 'Cloudflare'
            Uri  = 'https://www.cloudflare.com/cdn-cgi/trace'
            Parse = 'Trace'
        },
        [pscustomobject]@{
            Name = 'ipify'
            Uri  = 'https://api.ipify.org'
            Parse = 'Plain'
        }
    )

    foreach ($provider in $providers) {
        try {
            $response = Invoke-WebRequest -UseBasicParsing -Uri $provider.Uri -TimeoutSec 8
            $candidate = ''
            if ($provider.Parse -eq 'Trace') {
                $match = [regex]::Match([string]$response.Content, '(?m)^ip=(.+)$')
                if ($match.Success) { $candidate = $match.Groups[1].Value.Trim() }
            } else {
                $candidate = ([string]$response.Content).Trim()
            }

            if ((Get-IPv4Category -Address $candidate) -eq 'Public') {
                return [pscustomobject]@{ Address = $candidate; Provider = $provider.Name }
            }
        } catch { }
    }
    return $null
}

function Invoke-StunBindingTest {
    param(
        [string]$Server = 'stun.cloudflare.com',
        [int]$Port = 3478,
        [int]$TimeoutMilliseconds = 5000
    )

    $udp = $null
    try {
        $addresses = [System.Net.Dns]::GetHostAddresses($Server) | Where-Object AddressFamily -eq ([System.Net.Sockets.AddressFamily]::InterNetwork)
        if (@($addresses).Count -eq 0) { throw 'The STUN host did not resolve to IPv4.' }
        $endpoint = New-Object -TypeName System.Net.IPEndPoint -ArgumentList $addresses[0], $Port

        $transactionId = New-Object byte[] 12
        $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
        $rng.GetBytes($transactionId)
        $rng.Dispose()

        $request = New-Object byte[] 20
        $request[0] = 0x00; $request[1] = 0x01
        $request[2] = 0x00; $request[3] = 0x00
        $request[4] = 0x21; $request[5] = 0x12; $request[6] = 0xA4; $request[7] = 0x42
        [Array]::Copy($transactionId, 0, $request, 8, 12)

        $udp = New-Object System.Net.Sockets.UdpClient
        $udp.Client.ReceiveTimeout = $TimeoutMilliseconds
        [void]$udp.Send($request, $request.Length, $endpoint)

        $remote = New-Object -TypeName System.Net.IPEndPoint -ArgumentList ([System.Net.IPAddress]::Any), 0
        $response = $udp.Receive([ref]$remote)
        if ($response.Length -lt 20) { throw 'The STUN response was too short.' }
        if ($response[0] -ne 0x01 -or $response[1] -ne 0x01) { throw 'The STUN server did not return a binding success response.' }

        $offset = 20
        while ($offset + 4 -le $response.Length) {
            $type = ($response[$offset] -shl 8) -bor $response[$offset + 1]
            $length = ($response[$offset + 2] -shl 8) -bor $response[$offset + 3]
            $valueStart = $offset + 4
            if ($valueStart + $length -gt $response.Length) { break }

            if (($type -eq 0x0020 -or $type -eq 0x0001) -and $length -ge 8) {
                $family = $response[$valueStart + 1]
                if ($family -eq 0x01) {
                    $portValue = ($response[$valueStart + 2] -shl 8) -bor $response[$valueStart + 3]
                    $ipBytes = New-Object byte[] 4
                    [Array]::Copy($response, $valueStart + 4, $ipBytes, 0, 4)

                    if ($type -eq 0x0020) {
                        $portValue = $portValue -bxor 0x2112
                        $cookie = [byte[]](0x21, 0x12, 0xA4, 0x42)
                        for ($i = 0; $i -lt 4; $i++) { $ipBytes[$i] = $ipBytes[$i] -bxor $cookie[$i] }
                    }

                    return [pscustomobject]@{
                        Success       = $true
                        PublicAddress = (New-Object -TypeName System.Net.IPAddress -ArgumentList (,$ipBytes)).ToString()
                        PublicPort    = $portValue
                        Server        = $Server
                    }
                }
            }

            $paddedLength = [math]::Ceiling($length / 4.0) * 4
            $offset = $valueStart + [int]$paddedLength
        }

        throw 'No IPv4 mapped-address attribute was present in the STUN response.'
    } catch {
        return [pscustomobject]@{
            Success       = $false
            PublicAddress = ''
            PublicPort    = 0
            Server        = $Server
            Error         = $_.Exception.Message
        }
    } finally {
        if ($udp) { $udp.Close() }
    }
}

function Find-UpnpGatewayService {
    param([int]$TimeoutMilliseconds = 3000)

    $udp = $null
    try {
        $request = @"
M-SEARCH * HTTP/1.1`r
HOST: 239.255.255.250:1900`r
MAN: "ssdp:discover"`r
MX: 2`r
ST: urn:schemas-upnp-org:device:InternetGatewayDevice:1`r
`r

"@
        $bytes = [System.Text.Encoding]::ASCII.GetBytes($request)
        $udp = New-Object System.Net.Sockets.UdpClient
        $udp.Client.ReceiveTimeout = $TimeoutMilliseconds
        $destination = New-Object -TypeName System.Net.IPEndPoint -ArgumentList ([System.Net.IPAddress]::Parse('239.255.255.250')), 1900
        [void]$udp.Send($bytes, $bytes.Length, $destination)

        $locations = New-Object System.Collections.Generic.HashSet[string]
        $end = [DateTime]::UtcNow.AddMilliseconds($TimeoutMilliseconds)
        while ([DateTime]::UtcNow -lt $end) {
            try {
                $remote = New-Object -TypeName System.Net.IPEndPoint -ArgumentList ([System.Net.IPAddress]::Any), 0
                $responseBytes = $udp.Receive([ref]$remote)
                $text = [System.Text.Encoding]::ASCII.GetString($responseBytes)
                $match = [regex]::Match($text, '(?im)^LOCATION:\s*(.+)$')
                if ($match.Success) { [void]$locations.Add($match.Groups[1].Value.Trim()) }
            } catch [System.Net.Sockets.SocketException] {
                break
            }
        }

        foreach ($location in $locations) {
            try {
                $description = Invoke-WebRequest -UseBasicParsing -Uri $location -TimeoutSec 5
                [xml]$xml = $description.Content
                $serviceNodes = $xml.SelectNodes("//*[local-name()='service']")
                foreach ($service in $serviceNodes) {
                    $serviceTypeNode = $service.SelectSingleNode("./*[local-name()='serviceType']")
                    $controlUrlNode = $service.SelectSingleNode("./*[local-name()='controlURL']")
                    if (-not $serviceTypeNode -or -not $controlUrlNode) { continue }
                    $serviceType = [string]$serviceTypeNode.InnerText
                    if ($serviceType -notmatch 'WANIPConnection|WANPPPConnection') { continue }

                    $baseUri = New-Object System.Uri($location)
                    $controlUri = New-Object System.Uri($baseUri, [string]$controlUrlNode.InnerText)
                    return [pscustomobject]@{
                        Location    = $location
                        ServiceType = $serviceType
                        ControlUri  = $controlUri.AbsoluteUri
                    }
                }
            } catch { }
        }
        return $null
    } finally {
        if ($udp) { $udp.Close() }
    }
}

function Get-UpnpExternalIPAddress {
    param([Parameter(Mandatory = $true)]$Service)

    try {
        $soap = @"
<?xml version="1.0"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
  <s:Body>
    <u:GetExternalIPAddress xmlns:u="$($Service.ServiceType)"></u:GetExternalIPAddress>
  </s:Body>
</s:Envelope>
"@
        $headers = @{ SOAPACTION = '"' + $Service.ServiceType + '#GetExternalIPAddress"' }
        $response = Invoke-WebRequest -UseBasicParsing -Uri $Service.ControlUri -Method POST -Headers $headers -ContentType 'text/xml; charset="utf-8"' -Body $soap -TimeoutSec 6
        [xml]$xml = $response.Content
        $node = $xml.SelectSingleNode("//*[local-name()='NewExternalIPAddress']")
        if ($node -and $node.InnerText) { return ([string]$node.InnerText).Trim() }
    } catch { }
    return $null
}

function Get-TracePrivateHops {
    param([string]$DestinationHost = 'one.one.one.one')

    $tracert = Join-Path $env:SystemRoot 'System32\tracert.exe'
    if (-not (Test-Path -LiteralPath $tracert)) { return @() }

    $run = Invoke-ExternalProcess -FilePath $tracert -Arguments @('-d', '-h', '8', '-w', '1200', $DestinationHost) -TimeoutSeconds 25
    $hops = @()
    foreach ($line in ($run.Output -split "`r?`n")) {
        if ($line -match '^\s*(\d+)\s+.+?\s((?:\d{1,3}\.){3}\d{1,3})\s*$') {
            $address = $Matches[2]
            $hops += [pscustomobject]@{
                Hop      = [int]$Matches[1]
                Address  = $address
                Category = Get-IPv4Category -Address $address
            }
        }
    }
    return $hops
}

function Get-TailscalePeerByName {
    param([string]$TailscaleExe, [string]$Name)

    if (-not $TailscaleExe -or [string]::IsNullOrWhiteSpace($Name)) { return $null }
    $run = Invoke-ExternalProcess -FilePath $TailscaleExe -Arguments @('status', '--json') -TimeoutSeconds 20
    if ($run.ExitCode -ne 0 -or -not $run.Output) { return $null }

    try { $status = $run.Output | ConvertFrom-Json } catch { return $null }
    if ($null -eq $status.Peer) { return $null }

    $matches = @()
    foreach ($property in $status.Peer.PSObject.Properties) {
        $peer = $property.Value
        $shortDns = ''
        if ($peer.PSObject.Properties.Name -contains 'DNSName' -and $peer.DNSName) {
            $shortDns = ([string]$peer.DNSName).TrimEnd('.').Split('.')[0]
        }
        $hostName = if ($peer.PSObject.Properties.Name -contains 'HostName') { [string]$peer.HostName } else { '' }
        $dnsName = if ($peer.PSObject.Properties.Name -contains 'DNSName') { ([string]$peer.DNSName).TrimEnd('.') } else { '' }
        if ($hostName -ieq $Name -or $shortDns -ieq $Name -or $dnsName -ieq $Name) {
            $matches += $peer
        }
    }
    if ($matches.Count -eq 1) { return $matches[0] }
    return $null
}

function Save-PlainTextReport {
    param([string]$Label)

    $downloads = Join-Path $env:USERPROFILE 'Downloads'
    if (-not (Test-Path -LiteralPath $downloads)) { $downloads = $env:TEMP }
    $safeName = ($Label -replace '[^a-zA-Z0-9._-]', '_')
    $path = Join-Path $downloads ("ScriptBox-KVM-Site-Network-{0}-{1}.txt" -f $safeName, (Get-Date -Format 'yyyyMMdd-HHmmss'))

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('ScriptBox KVM Site Network Diagnostics') | Out-Null
    $lines.Add(('Generated: {0}' -f (Get-Date))) | Out-Null
    $lines.Add(('KVM label: {0}' -f $Label)) | Out-Null
    $lines.Add('') | Out-Null
    $lines.Add('Important: this test cannot prove unsolicited inbound UDP reachability from inside the LAN.') | Out-Null
    $lines.Add('It tests the NAT, UDP, firewall, route, and port-mapping conditions used for direct connectivity.') | Out-Null
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
    Write-Output 'ScriptBox KVM site diagnostic validation passed.'
    return
}

if (-not $NonInteractive) { Clear-Host }
Write-Title 'ScriptBox - KVM Site Network Diagnostics'
Write-Host 'Run this on a Windows PC connected to the same router/network as the KVM.' -ForegroundColor Gray
Write-Host 'The test is read-only and does not open ports or change the router.' -ForegroundColor Gray
Write-Host ''
Write-Host 'Important limitation:' -ForegroundColor Yellow
Write-Host 'A device inside the LAN cannot conclusively prove that unsolicited inbound UDP reaches the KVM.' -ForegroundColor Gray
Write-Host 'This script checks UDP/STUN, NAT type, likely CGNAT/double NAT, port mapping, firewall policy, and required outbound paths.' -ForegroundColor Gray

while ([string]::IsNullOrWhiteSpace($KvmName)) {
    if ($NonInteractive) { throw 'A KVM machine name is required.' }
    Write-Host ''
    $KvmName = Read-Host 'Enter the KVM machine name for this report'
    if ([string]::IsNullOrWhiteSpace($KvmName)) {
        Write-Host 'A KVM name is required.' -ForegroundColor Yellow
    }
}
$KvmName = $KvmName.Trim()

Write-Host ''
Write-Host 'Inspecting the active Windows network...' -ForegroundColor Cyan
$ipConfigs = @(Get-NetIPConfiguration -ErrorAction SilentlyContinue | Where-Object {
    $_.IPv4DefaultGateway -and $_.NetAdapter.Status -eq 'Up' -and $_.InterfaceAlias -notmatch 'Tailscale'
})

if ($ipConfigs.Count -eq 0) {
    Add-DiagnosticResult -Status RED -Test 'Active internet adapter' -Value 'Not found' `
        -Message 'Windows did not report an active non-Tailscale adapter with a default gateway.'
    $primaryConfig = $null
} else {
    $primaryConfig = $ipConfigs | Sort-Object { $_.NetAdapter.LinkSpeed } -Descending | Select-Object -First 1
    $localIPv4 = @($primaryConfig.IPv4Address | Select-Object -ExpandProperty IPAddress) -join ', '
    $gatewayIPv4 = @($primaryConfig.IPv4DefaultGateway | Select-Object -ExpandProperty NextHop) -join ', '
    $adapterValue = "{0}; local {1}; gateway {2}" -f $primaryConfig.InterfaceAlias, $localIPv4, $gatewayIPv4

    Add-DiagnosticResult -Status GREEN -Test 'Active internet adapter' -Value $adapterValue `
        -Message 'An active adapter and default gateway were found.'

    if ($primaryConfig.NetAdapter.MediaType -match '802.11|Wireless' -or $primaryConfig.InterfaceAlias -match 'Wi-?Fi|Wireless') {
        Add-DiagnosticResult -Status AMBER -Test 'Local access medium' -Value 'Wi-Fi' `
            -Message 'This test computer is using Wi-Fi.' `
            -Note 'Wi-Fi loss or interference on the test PC can affect results. The JetKVM itself should preferably use wired Ethernet.'
    } else {
        Add-DiagnosticResult -Status GREEN -Test 'Local access medium' -Value 'Wired/non-Wi-Fi' `
            -Message 'The active test path does not appear to use Wi-Fi.'
    }
}

$firewallProfiles = @(Get-NetFirewallProfile -ErrorAction SilentlyContinue)
if ($firewallProfiles.Count -gt 0) {
    $blockingProfiles = @($firewallProfiles | Where-Object { $_.Enabled -and [string]$_.DefaultOutboundAction -eq 'Block' })
    if ($blockingProfiles.Count -gt 0) {
        Add-DiagnosticResult -Status RED -Test 'Windows Firewall outbound policy' -Value (($blockingProfiles.Name -join ', ') + ' blocks by default') `
            -Message 'One or more active firewall profiles block outbound traffic unless explicitly allowed.' `
            -Note 'Ensure Tailscale and required UDP/TCP destinations have explicit allow rules.'
    } else {
        Add-DiagnosticResult -Status GREEN -Test 'Windows Firewall outbound policy' -Value 'No enabled profile defaults to Block' `
            -Message 'Windows Firewall is not configured to block all outbound traffic by default.'
    }
} else {
    Add-DiagnosticResult -Status AMBER -Test 'Windows Firewall outbound policy' -Value 'Unable to inspect' `
        -Message 'Firewall profiles were not available to the script.'
}

Write-Host ''
Write-Host 'Testing required outbound TCP paths...' -ForegroundColor Cyan
$tcp443 = Test-TcpPort -ComputerName 'controlplane.tailscale.com' -Port 443
$tcp80 = Test-TcpPort -ComputerName 'controlplane.tailscale.com' -Port 80

if ($tcp443) {
    Add-DiagnosticResult -Status GREEN -Test 'Outbound TCP 443' -Value 'Reachable' `
        -Message 'HTTPS connectivity to the Tailscale control plane is available.'
} else {
    Add-DiagnosticResult -Status RED -Test 'Outbound TCP 443' -Value 'Blocked/unreachable' `
        -Message 'The network could not establish HTTPS to the Tailscale control plane.' `
        -Note 'Check DNS, proxy, firewall, web filtering, and ISP restrictions.'
}

if ($tcp80) {
    Add-DiagnosticResult -Status GREEN -Test 'Outbound TCP 80' -Value 'Reachable' `
        -Message 'The preferred HTTP transport and captive-portal checks can use TCP 80.'
} else {
    Add-DiagnosticResult -Status AMBER -Test 'Outbound TCP 80' -Value 'Blocked/unreachable' `
        -Message 'TCP 80 is unavailable, but Tailscale can normally fall back to HTTPS on TCP 443.'
}

Write-Host ''
Write-Host 'Testing public IP and UDP/STUN...' -ForegroundColor Cyan
$publicIP = Get-PublicIPv4
if ($publicIP) {
    Add-DiagnosticResult -Status GREEN -Test 'Public IPv4 discovery' -Value ("{0} via {1}" -f $publicIP.Address, $publicIP.Provider) `
        -Message 'The internet-facing IPv4 address was discovered.'
} else {
    Add-DiagnosticResult -Status AMBER -Test 'Public IPv4 discovery' -Value 'Unavailable' `
        -Message 'External HTTPS services did not return a public IPv4 address.' `
        -Note 'A proxy, content filter, DNS issue, or IPv6-only path may be involved.'
}

$stun = Invoke-StunBindingTest
if ($stun.Success) {
    Add-DiagnosticResult -Status GREEN -Test 'Outbound UDP/STUN 3478' -Value ("Reply received; mapped {0}:{1}" -f $stun.PublicAddress, $stun.PublicPort) `
        -Message 'UDP requests and return traffic work through the current network.' `
        -Note 'Tailscale uses STUN on UDP 3478 to discover public NAT mappings.'
} else {
    Add-DiagnosticResult -Status RED -Test 'Outbound UDP/STUN 3478' -Value 'No valid reply' `
        -Message 'The test could not complete a STUN exchange over UDP 3478.' `
        -Note ('Direct Tailscale connections are less likely. Detail: ' + $stun.Error)
}

Write-Host ''
Write-Host 'Checking UPnP gateway information...' -ForegroundColor Cyan
$upnpService = Find-UpnpGatewayService
$routerWanIP = $null
if ($upnpService) {
    $routerWanIP = Get-UpnpExternalIPAddress -Service $upnpService
    if ($routerWanIP) {
        Add-DiagnosticResult -Status GREEN -Test 'UPnP internet gateway discovery' -Value ("Gateway responded; WAN address {0}" -f $routerWanIP) `
            -Message 'The local router exposes an Internet Gateway Device service.'
    } else {
        Add-DiagnosticResult -Status AMBER -Test 'UPnP internet gateway discovery' -Value 'Gateway found; WAN address unavailable' `
            -Message 'UPnP discovery worked, but the router did not return its external address.'
    }
} else {
    Add-DiagnosticResult -Status AMBER -Test 'UPnP internet gateway discovery' -Value 'Not detected' `
        -Message 'No UPnP Internet Gateway Device responded.' `
        -Note 'UPnP may be disabled. Tailscale can still connect directly using other NAT traversal methods.'
}

Write-Host ''
Write-Host 'Looking for double NAT or CGNAT indicators...' -ForegroundColor Cyan
$natAssessmentMade = $false
if ($routerWanIP) {
    $wanCategory = Get-IPv4Category -Address $routerWanIP
    if ($wanCategory -eq 'CGNAT') {
        Add-DiagnosticResult -Status RED -Test 'CGNAT/double NAT assessment' -Value ("Router WAN address {0} is in 100.64.0.0/10" -f $routerWanIP) `
            -Message 'Carrier-grade NAT is highly likely.' `
            -Note 'Ask the ISP for a public IPv4 address, use IPv6 where supported, or rely on Tailscale relay/peer-relay fallback.'
        $natAssessmentMade = $true
    } elseif ($wanCategory -eq 'RFC1918') {
        Add-DiagnosticResult -Status RED -Test 'CGNAT/double NAT assessment' -Value ("Router WAN address {0} is private" -f $routerWanIP) `
            -Message 'The router is behind another NAT device, so double NAT is highly likely.' `
            -Note 'Bridge the upstream modem/router, place the downstream router in its DMZ, or remove the extra router layer where appropriate.'
        $natAssessmentMade = $true
    } elseif ($wanCategory -eq 'Public' -and $publicIP) {
        if ($routerWanIP -eq $publicIP.Address) {
            Add-DiagnosticResult -Status GREEN -Test 'CGNAT/double NAT assessment' -Value 'Router WAN IP matches public IP' `
                -Message 'No obvious CGNAT or upstream NAT was found through the UPnP comparison.'
        } else {
            Add-DiagnosticResult -Status AMBER -Test 'CGNAT/double NAT assessment' -Value ("Router WAN {0}; observed public {1}" -f $routerWanIP, $publicIP.Address) `
                -Message 'The router-reported WAN address differs from the observed public address.' `
                -Note 'This may indicate upstream NAT, proxying, multi-WAN, or an ISP translation layer.'
        }
        $natAssessmentMade = $true
    }
}

$traceHops = @(Get-TracePrivateHops)
if ($traceHops.Count -gt 0) {
    $cgnatHops = @($traceHops | Where-Object Category -eq 'CGNAT')
    $privateAfterFirst = @($traceHops | Where-Object { $_.Hop -gt 1 -and $_.Category -eq 'RFC1918' })

    if (-not $natAssessmentMade -and $cgnatHops.Count -gt 0) {
        Add-DiagnosticResult -Status RED -Test 'CGNAT/double NAT assessment' -Value ("CGNAT-range hop detected: {0}" -f (($cgnatHops.Address | Select-Object -Unique) -join ', ')) `
            -Message 'The early internet route contains an address in the carrier-grade NAT range.' `
            -Note 'Traceroute evidence is strong but not absolute; verify the WAN address shown in the router administration page.'
        $natAssessmentMade = $true
    } elseif (-not $natAssessmentMade -and $privateAfterFirst.Count -gt 0) {
        Add-DiagnosticResult -Status AMBER -Test 'CGNAT/double NAT assessment' -Value ("Additional private hop(s): {0}" -f (($privateAfterFirst.Address | Select-Object -Unique) -join ', ')) `
            -Message 'An additional private-addressed router appears after the first local gateway.' `
            -Note 'This suggests double NAT, although some ISP networks use private addresses internally.'
        $natAssessmentMade = $true
    }

    Add-DiagnosticResult -Status INFO -Test 'Early route hops' -Value (($traceHops | ForEach-Object { "{0}:{1}({2})" -f $_.Hop, $_.Address, $_.Category }) -join ' -> ') `
        -Message 'These are the responding addresses near the start of the route.'
} else {
    Add-DiagnosticResult -Status AMBER -Test 'Early route hops' -Value 'No responding hops parsed' `
        -Message 'The router or ISP may suppress traceroute responses.'
}

if (-not $natAssessmentMade) {
    Add-DiagnosticResult -Status AMBER -Test 'CGNAT/double NAT assessment' -Value 'Inconclusive' `
        -Message 'The script could not reliably compare the router WAN address with the observed public address.' `
        -Note 'Open the router status page and compare its WAN/Internet IPv4 address with the public IPv4 shown above. A private or 100.64.0.0/10 WAN address indicates upstream NAT.'
}

Write-Host ''
Write-Host 'Running Tailscale-specific NAT checks when available...' -ForegroundColor Cyan
$tailscaleExe = Get-TailscaleExecutable
if ($tailscaleExe) {
    Add-DiagnosticResult -Status GREEN -Test 'Tailscale installation on test PC' -Value $tailscaleExe `
        -Message 'The local Tailscale CLI is available for detailed NAT testing.'

    $netcheckRun = Invoke-ExternalProcess -FilePath $tailscaleExe -Arguments @('netcheck') -TimeoutSeconds 45
    if ($netcheckRun.ExitCode -eq 0 -and $netcheckRun.Output) {
        $netcheck = Parse-NetcheckText -Text $netcheckRun.Output

        if ($netcheck.UDP -eq $true) {
            Add-DiagnosticResult -Status GREEN -Test 'Tailscale UDP capability' -Value 'true' `
                -Message 'Tailscale can exchange UDP traffic from this network.'
        } elseif ($netcheck.UDP -eq $false) {
            Add-DiagnosticResult -Status RED -Test 'Tailscale UDP capability' -Value 'false' `
                -Message 'Tailscale cannot use UDP from this network.' `
                -Note 'Direct connections are unlikely; inspect router, firewall, ISP, proxy, and security filtering.'
        } else {
            Add-DiagnosticResult -Status AMBER -Test 'Tailscale UDP capability' -Value 'Not measured' `
                -Message 'Tailscale did not return a definite UDP result.'
        }

        if ($netcheck.MappingVariesByDestIP -eq $true) {
            Add-DiagnosticResult -Status RED -Test 'Tailscale NAT mapping type' -Value 'Mapping varies by destination' `
                -Message 'A difficult/hard NAT was detected.' `
                -Note 'This is a common reason direct connections fail and DERP is used.'
        } elseif ($netcheck.MappingVariesByDestIP -eq $false) {
            Add-DiagnosticResult -Status GREEN -Test 'Tailscale NAT mapping type' -Value 'Mapping does not vary by destination' `
                -Message 'The NAT behaviour is favourable for direct peer-to-peer connectivity.'
        } else {
            Add-DiagnosticResult -Status AMBER -Test 'Tailscale NAT mapping type' -Value 'Not measured' `
                -Message 'The NAT mapping type could not be determined.'
        }

        if ($netcheck.PortMapping) {
            Add-DiagnosticResult -Status GREEN -Test 'Router port-mapping protocols' -Value $netcheck.PortMapping `
                -Message 'At least one of UPnP, NAT-PMP, or PCP is available.'
        } else {
            Add-DiagnosticResult -Status AMBER -Test 'Router port-mapping protocols' -Value 'None detected' `
                -Message 'No automatic port-mapping protocol was detected.' `
                -Note 'Direct connectivity may still work, but router configuration or a manual UDP mapping can improve reliability.'
        }

        if ($netcheck.CaptivePortal -eq $true) {
            Add-DiagnosticResult -Status RED -Test 'Captive portal' -Value 'Detected' `
                -Message 'The network may require sign-in or be intercepting traffic.'
        } else {
            Add-DiagnosticResult -Status GREEN -Test 'Captive portal' -Value 'Not detected' `
                -Message 'No captive portal was reported.'
        }

        if ($netcheck.IPv4) {
            Add-DiagnosticResult -Status INFO -Test 'Tailscale-observed IPv4 mapping' -Value $netcheck.IPv4 `
                -Message 'This is the public IPv4 and UDP mapping observed by Tailscale STUN probes.'
        }
        if ($netcheck.NearestDERP) {
            Add-DiagnosticResult -Status INFO -Test 'Nearest DERP fallback' -Value $netcheck.NearestDERP `
                -Message 'This is the nearest fallback relay measured from the KVM-site network.'
        }
    } else {
        Add-DiagnosticResult -Status AMBER -Test 'Tailscale netcheck' -Value 'Failed' `
            -Message 'The Tailscale network report could not be completed.' `
            -Note (($netcheckRun.Error + ' ' + $netcheckRun.Output).Trim())
    }

    $peer = Get-TailscalePeerByName -TailscaleExe $tailscaleExe -Name $KvmName
    if ($peer) {
        $peerIPs = @($peer.TailscaleIPs)
        $peerIP = $peerIPs | Where-Object { [string]$_ -match '^\d{1,3}(\.\d{1,3}){3}$' } | Select-Object -First 1
        if (-not $peerIP -and $peerIPs.Count -gt 0) { $peerIP = $peerIPs[0] }

        Add-DiagnosticResult -Status GREEN -Test 'KVM lookup from site PC' -Value ("{0} ({1})" -f $peer.HostName, $peerIP) `
            -Message 'The KVM name was found in the local tailnet automatically.'

        if ($peerIP) {
            $pingRun = Invoke-ExternalProcess -FilePath $tailscaleExe -Arguments @('ping', '--c=5', '--timeout=5s', '--until-direct=false', [string]$peerIP) -TimeoutSeconds 35
            $combinedPing = $pingRun.Output + "`n" + $pingRun.Error
            if ($combinedPing -match '(?im)\bvia\s+([\[\]0-9a-fA-F:\.]+:\d+)') {
                Add-DiagnosticResult -Status GREEN -Test 'KVM path from site PC' -Value ('Direct via ' + $Matches[1]) `
                    -Message 'This test PC established a direct Tailscale path to the KVM.'
            } elseif ($combinedPing -match '(?im)\bvia\s+DERP\(([^\)]+)\)') {
                Add-DiagnosticResult -Status RED -Test 'KVM path from site PC' -Value ('DERP relay ' + $Matches[1]) `
                    -Message 'The path from this PC to the KVM is relayed.' `
                    -Note 'Because both are at the same site, also check whether they are actually on the same LAN/VLAN and whether local isolation is enabled.'
            } else {
                Add-DiagnosticResult -Status AMBER -Test 'KVM path from site PC' -Value 'Could not classify' `
                    -Message 'The KVM ping did not clearly report a connection type.' `
                    -Note $combinedPing.Trim()
            }
        }
    } else {
        Add-DiagnosticResult -Status INFO -Test 'KVM lookup from site PC' -Value 'Not available' `
            -Message 'The entered KVM name was not found from this PC.' `
            -Note 'This is expected if the test PC is not signed into the same tailnet; the site network tests remain valid.'
    }
} else {
    Add-DiagnosticResult -Status AMBER -Test 'Tailscale installation on test PC' -Value 'Not found' `
        -Message 'Generic network tests completed, but Tailscale-specific NAT measurements were unavailable.' `
        -Note 'For the strongest result, install/sign in to Tailscale temporarily on a PC using the same router as the KVM, or run tailscale netcheck directly on a supported device at the site.'
}

Add-DiagnosticResult -Status INFO -Test 'Inbound UDP port verification' -Value 'Not provable from inside this LAN' `
    -Message 'The script confirms UDP return traffic and NAT behaviour but cannot verify unsolicited inbound traffic from the public internet.' `
    -Note 'A conclusive test needs an external probe coordinated with a listening service, or inspection of the router NAT/port-forward table. Do not expose the JetKVM web interface directly to the public internet.'

Write-Title 'Summary'
$redCount = @($script:Results | Where-Object Status -eq 'RED').Count
$amberCount = @($script:Results | Where-Object Status -eq 'AMBER').Count
$greenCount = @($script:Results | Where-Object Status -eq 'GREEN').Count

if ($redCount -gt 0) {
    Write-Host ("Overall: RED - {0} serious issue(s), {1} warning(s), {2} good check(s)." -f $redCount, $amberCount, $greenCount) -ForegroundColor Red
    Write-Host 'Resolve UDP blocks, hard NAT, CGNAT/double NAT, or blocked TCP 443 before expecting consistently direct KVM connections.' -ForegroundColor Gray
} elseif ($amberCount -gt 0) {
    Write-Host ("Overall: AMBER - no definite critical fault, but {0} item(s) are uncertain or suboptimal." -f $amberCount) -ForegroundColor Yellow
    Write-Host 'Review the warnings, especially NAT assessment and automatic port-mapping availability.' -ForegroundColor Gray
} else {
    Write-Host 'Overall: GREEN - the site network has favourable conditions for direct Tailscale connectivity.' -ForegroundColor Green
    Write-Host 'This does not guarantee a low-latency international route or rule out upload saturation/bufferbloat.' -ForegroundColor Gray
}

if (-not $NoReportFile) {
    try {
        $reportPath = Save-PlainTextReport -Label $KvmName
        Write-Host ''
        Write-Host ('Report saved to: ' + $reportPath) -ForegroundColor Cyan
    } catch {
        Write-Host ''
        Write-Host ('The report could not be saved: ' + $_.Exception.Message) -ForegroundColor Yellow
    }
}

Write-Host ''
if (-not $NonInteractive) { Read-Host 'Press Enter to close' | Out-Null }
