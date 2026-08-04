#Requires -Version 5.1
<#
.SYNOPSIS
    Shows a hardware and network summary and saves PC-Info.txt to the Desktop.

.DESCRIPTION
    Collects the computer name, make, model, BIOS serial number, primary MAC
    address, CPU, installed RAM, and the external IP address (via
    api.ipify.org), prints the summary so ScriptBox can display it in the
    results popup, and always writes it to PC-Info.txt on the current user's
    Desktop. All queries are read-only.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

try {
    $pc = Get-CimInstance -ClassName Win32_ComputerSystem
    $bios = Get-CimInstance -ClassName Win32_BIOS
    $cpu = Get-CimInstance -ClassName Win32_Processor | Select-Object -First 1
    # Prefer the MAC of real hardware: virtual adapters (Tailscale, VMware,
    # Hyper-V) enumerate on ROOT/SWD buses, while physical NICs sit on PCI or
    # USB. Fall back to PhysicalAdapter, then to any IP-enabled adapter.
    $configurations = @(Get-CimInstance -ClassName Win32_NetworkAdapterConfiguration |
        Where-Object { $_.IPEnabled -eq $true -and $_.MACAddress })
    $adaptersByIndex = @{}
    foreach ($adapter in @(Get-CimInstance -ClassName Win32_NetworkAdapter)) {
        $adaptersByIndex[[string]$adapter.Index] = $adapter
    }
    $rankedConfigurations = $configurations | Sort-Object -Property @{ Expression = {
        $adapter = $adaptersByIndex[[string]$_.Index]
        $pnpId = if ($adapter -and $adapter.PNPDeviceID) { [string]$adapter.PNPDeviceID } else { '' }
        if ($pnpId -like 'PCI\*' -or $pnpId -like 'USB\*') { 0 }
        elseif ($adapter -and $adapter.PhysicalAdapter -eq $true) { 1 }
        else { 2 }
    } }
    $nic = $rankedConfigurations | Select-Object -First 1

    $ramGb = [math]::Round($pc.TotalPhysicalMemory / 1GB, 2)
    $macAddress = if ($nic) { $nic.MACAddress } else { 'Unavailable' }

    $externalIp = 'Unavailable'
    try {
        $externalIp = (Invoke-RestMethod -UseBasicParsing -Uri 'https://api.ipify.org?format=json' -TimeoutSec 12).ip
    }
    catch {
        Write-Host '[WARNING] The external IP address could not be determined; the computer may be offline.'
    }

    $reportLines = @(
        "PC Name       : $($pc.Name)"
        "PC Make       : $($pc.Manufacturer)"
        "PC Model      : $($pc.Model)"
        "Serial Number : $($bios.SerialNumber)"
        "MAC           : $macAddress"
        "CPU           : $($cpu.Name)"
        "RAM (GB)      : $ramGb"
        "External IP   : $externalIp"
    )

    foreach ($line in $reportLines) { Write-Host $line }

    $reportPath = Join-Path ([Environment]::GetFolderPath('Desktop')) 'PC-Info.txt'
    [IO.File]::WriteAllText(
        $reportPath,
        (($reportLines -join [Environment]::NewLine) + [Environment]::NewLine),
        (New-Object Text.UTF8Encoding($false))
    )

    Write-Host "[SUCCESS] The PC summary was saved to $reportPath."
}
catch {
    Write-Host "[ERROR] PC information could not be collected: $($_.Exception.Message)"
    throw
}
