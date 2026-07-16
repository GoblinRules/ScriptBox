#Requires -Version 5.1
<#
.SYNOPSIS
    Enables Remote Desktop for the PC and adds the currently signed-in Windows
    user to the local Remote Desktop Users group.

.DESCRIPTION
    Designed for ScriptBox, Action1, or another elevated deployment runner.
    The script deliberately detects the interactive user instead of using the
    account under which the script is running (which may be SYSTEM or Admin).

    An optional -TargetUser value can be supplied if no user is interactively
    signed in. Examples:
      .\02_Enable_RDP_Add_Current_User.ps1 -TargetUser 'PCNAME\Gareth'
      .\02_Enable_RDP_Add_Current_User.ps1 -TargetUser 'MicrosoftAccount\name@example.com'
      .\02_Enable_RDP_Add_Current_User.ps1 -TargetUser 'AzureAD\name@example.com'
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$TargetUser
)

$ErrorActionPreference = 'Stop'

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

function Get-InteractiveUser {
    # Win32_ComputerSystem returns the signed-in console user even when this
    # script is running as SYSTEM or under a separate administrator account.
    $computerSystem = Get-CimInstance -ClassName Win32_ComputerSystem
    if (-not [string]::IsNullOrWhiteSpace($computerSystem.UserName)) {
        return $computerSystem.UserName.Trim()
    }

    # Fallback: identify the owner of Explorer.exe.
    $explorerProcesses = Get-CimInstance -ClassName Win32_Process -Filter "Name='explorer.exe'"
    foreach ($process in $explorerProcesses) {
        try {
            $owner = Invoke-CimMethod -InputObject $process -MethodName GetOwner
            if ($owner.ReturnValue -eq 0 -and -not [string]::IsNullOrWhiteSpace($owner.User)) {
                if ([string]::IsNullOrWhiteSpace($owner.Domain)) {
                    return $owner.User
                }

                return "$($owner.Domain)\$($owner.User)"
            }
        }
        catch {
            # Continue checking other Explorer processes.
        }
    }

    return $null
}

try {
    Assert-Administrator

    $editionId = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name EditionID).EditionID
    if ($editionId -match 'Core|Home') {
        throw "Windows edition '$editionId' cannot act as a Microsoft Remote Desktop host. Windows Pro, Enterprise, Education, or Server is required."
    }

    if ([string]::IsNullOrWhiteSpace($TargetUser)) {
        $TargetUser = Get-InteractiveUser
    }

    if ([string]::IsNullOrWhiteSpace($TargetUser)) {
        throw 'No interactively signed-in user was detected. Sign in as the intended user or run the script again with -TargetUser.'
    }

    if ($TargetUser -match '^(NT AUTHORITY\\SYSTEM|SYSTEM)$') {
        throw 'The detected account is SYSTEM rather than an interactive user.'
    }

    Write-Log INFO "Interactive user selected for RDP access: $TargetUser"

    # Enable Remote Desktop for the machine. Set both the normal system value
    # and the local policy value so an existing local deny policy cannot leave
    # the Settings toggle effectively off.
    $terminalServerPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server'
    $terminalServerPolicyPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services'
    New-Item -Path $terminalServerPolicyPath -Force | Out-Null

    Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' `
        -Name 'fDenyTSConnections' -Type DWord -Value 0
    Set-ItemProperty -Path $terminalServerPolicyPath `
        -Name 'fDenyTSConnections' -Type DWord -Value 0

    # Require Network Level Authentication for incoming connections.
    Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' `
        -Name 'UserAuthentication' -Type DWord -Value 1

    # Ensure Remote Desktop Services is available.
    Set-Service -Name 'TermService' -StartupType Manual
    Start-Service -Name 'TermService' -ErrorAction SilentlyContinue

    # Create predictable, language-independent firewall rules. Recreating only
    # our own named rules makes the script safe to run repeatedly.
    $firewallRules = @(
        @{ Name = 'ScriptBox-RDP-TCP-In'; Protocol = 'TCP' },
        @{ Name = 'ScriptBox-RDP-UDP-In'; Protocol = 'UDP' }
    )

    foreach ($rule in $firewallRules) {
        Remove-NetFirewallRule -Name $rule.Name -ErrorAction SilentlyContinue
        New-NetFirewallRule `
            -Name $rule.Name `
            -DisplayName $rule.Name `
            -Description 'Created by ScriptBox to permit Microsoft Remote Desktop.' `
            -Direction Inbound `
            -Action Allow `
            -Enabled True `
            -Profile Any `
            -Protocol $rule.Protocol `
            -LocalPort 3389 | Out-Null
    }

    # Resolve the localized group name through its well-known SID.
    $rdpGroup = Get-LocalGroup -SID 'S-1-5-32-555'
    $members  = @(Get-LocalGroupMember -Group $rdpGroup.Name -ErrorAction SilentlyContinue)

    $alreadyMember = $members | Where-Object {
        $_.Name -ieq $TargetUser -or
        $_.Name -ieq "$env:COMPUTERNAME\$TargetUser"
    }

    if ($alreadyMember) {
        Write-Log INFO "'$TargetUser' is already a member of '$($rdpGroup.Name)'."
    }
    else {
        Add-LocalGroupMember -Group $rdpGroup.Name -Member $TargetUser
        Write-Log SUCCESS "Added '$TargetUser' to '$($rdpGroup.Name)'."
    }

    $rdpEnabled = (Get-ItemProperty -Path $terminalServerPath).fDenyTSConnections -eq 0
    $rdpPolicyEnabled = (Get-ItemProperty -Path $terminalServerPolicyPath).fDenyTSConnections -eq 0
    $nlaEnabled = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp').UserAuthentication -eq 1
    $rdpService = Get-Service -Name 'TermService'
    $firewallEnabled = @($firewallRules | Where-Object {
        -not (Get-NetFirewallRule -Name $_.Name -ErrorAction SilentlyContinue | Where-Object Enabled -eq 'True')
    }).Count -eq 0

    if (-not $rdpEnabled -or -not $rdpPolicyEnabled -or -not $nlaEnabled -or
        $rdpService.Status -ne 'Running' -or -not $firewallEnabled) {
        throw 'The final Remote Desktop configuration check failed.'
    }

    Write-Log SUCCESS 'Remote Desktop is enabled for this PC, NLA is enabled, the firewall is open, and the signed-in user is permitted to connect.'
    Write-Log WARNING 'When connecting by RDP, use the account password. A Windows Hello PIN normally cannot be used as the remote credential.'
    return
}
catch {
    Write-Log ERROR $_.Exception.Message
    throw
}
