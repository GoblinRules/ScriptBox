#Requires -Version 5.1
<#
.SYNOPSIS
    Installs or updates 7-Zip, Google Chrome, Mozilla Firefox, and Notepad++
    using the official Ninite bundle.

.DESCRIPTION
    Downloads the Ninite installer, verifies that Windows considers its digital
    signature valid, runs it unattended, checks the expected applications, and
    removes the temporary installer.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Write-Log {
    param(
        [ValidateSet('INFO', 'SUCCESS', 'WARNING', 'ERROR')]
        [string]$Level,
        [string]$Message
    )

    Write-Host "[$Level] $Message"
}

function Assert-Administrator {
    $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)

    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'This script must be run with administrator rights.'
    }
}

function Test-AnyPath {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Paths
    )

    foreach ($path in $Paths) {
        if (Test-Path -LiteralPath $path) {
            return $true
        }
    }

    return $false
}

try {
    Assert-Administrator

    # Ensure TLS 1.2 is available to Windows PowerShell 5.1.
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

    $applications = @(
        @{
            Name = '7-Zip'
            Paths = @(
                'C:\Program Files\7-Zip\7z.exe',
                'C:\Program Files (x86)\7-Zip\7z.exe'
            )
        },
        @{
            Name = 'Google Chrome'
            Paths = @(
                'C:\Program Files\Google\Chrome\Application\chrome.exe',
                'C:\Program Files (x86)\Google\Chrome\Application\chrome.exe'
            )
        },
        @{
            Name = 'Mozilla Firefox'
            Paths = @(
                'C:\Program Files\Mozilla Firefox\firefox.exe',
                'C:\Program Files (x86)\Mozilla Firefox\firefox.exe'
            )
        },
        @{
            Name = 'Notepad++'
            Paths = @(
                'C:\Program Files\Notepad++\notepad++.exe',
                'C:\Program Files (x86)\Notepad++\notepad++.exe'
            )
        }
    )

    foreach ($application in $applications) {
        $state = if (Test-AnyPath -Paths $application.Paths) { 'already installed; Ninite will update it if required' } else { 'not currently detected' }
        Write-Log INFO "$($application.Name): $state."
    }

    $downloadUrl = 'https://ninite.com/7zip-chrome-firefox-notepadplusplus/ninite.exe'
    $installerPath = Join-Path $env:TEMP "ScriptBox-Ninite-$([Guid]::NewGuid().ToString('N')).exe"

    try {
        Write-Log INFO 'Downloading the official Ninite bundle...'
        Invoke-WebRequest -Uri $downloadUrl -OutFile $installerPath -UseBasicParsing

        if (-not (Test-Path -LiteralPath $installerPath)) {
            throw 'The Ninite installer was not downloaded.'
        }

        $signature = Get-AuthenticodeSignature -FilePath $installerPath
        if ($signature.Status -ne [System.Management.Automation.SignatureStatus]::Valid) {
            throw "The downloaded Ninite installer did not have a valid digital signature. Signature status: $($signature.Status)."
        }

        Write-Log INFO "Installer signature is valid. Signer: $($signature.SignerCertificate.Subject)"
        Write-Log INFO 'Running Ninite. Existing apps will be updated where applicable...'

        $process = Start-Process -FilePath $installerPath -Wait -PassThru
        if ($process.ExitCode -ne 0) {
            throw "Ninite exited with code $($process.ExitCode)."
        }
    }
    finally {
        Remove-Item -LiteralPath $installerPath -Force -ErrorAction SilentlyContinue
    }

    $missing = @()
    foreach ($application in $applications) {
        if (Test-AnyPath -Paths $application.Paths) {
            Write-Log SUCCESS "$($application.Name) is installed."
        }
        else {
            $missing += $application.Name
            Write-Log ERROR "$($application.Name) was not detected after Ninite finished."
        }
    }

    if ($missing.Count -gt 0) {
        throw "One or more applications were not detected: $($missing -join ', ')."
    }

    Write-Log SUCCESS '7-Zip, Chrome, Firefox, and Notepad++ were installed or updated successfully.'
    return
}
catch {
    Write-Log ERROR $_.Exception.Message
    throw
}
