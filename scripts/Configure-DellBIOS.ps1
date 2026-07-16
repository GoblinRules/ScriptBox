#requires -version 5.1
<#
  Dell BIOS configuration for mixed Dell commercial models.
  Installs Dell Command | Configure using winget when CCTK is absent.
  Optional ScriptBox variable: $BIOSPassword
  Unsupported attributes are logged and skipped.
#>
[CmdletBinding()]
param([string]$BIOSPassword)

$ErrorActionPreference='Stop'; $ProgressPreference='SilentlyContinue'
$LogRoot='C:\ProgramData\ScriptBox\BIOS'; New-Item $LogRoot -ItemType Directory -Force|Out-Null
$LogFile=Join-Path $LogRoot ("Dell-BIOS-{0:yyyyMMdd-HHmmss}.log" -f (Get-Date))
function Log($m,$l='INFO'){ $x='[{0:yyyy-MM-dd HH:mm:ss}] [{1}] {2}'-f(Get-Date),$l,$m; Write-Host $x; Add-Content $LogFile $x }
function IsAdmin{$p=[Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent());$p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)}
if(-not(IsAdmin)){Log 'Run elevated.' 'ERROR';throw 'Administrator rights are required.'}
$cs=Get-CimInstance Win32_ComputerSystem;if($cs.Manufacturer-notmatch'Dell'){Log "Not Dell: $($cs.Manufacturer)" 'ERROR';throw 'This BIOS script only supports Dell hardware.'}
Log "Detected Dell model: $($cs.Model)"
$pwd=if([string]::IsNullOrWhiteSpace($BIOSPassword)){$null}else{$BIOSPassword}
$paths=@("$env:ProgramFiles\Dell\Command Configure\X86_64\cctk.exe","${env:ProgramFiles(x86)}\Dell\Command Configure\X86_64\cctk.exe","$env:ProgramFiles\Dell\Command Configure\cctk.exe")
$cctk=$paths|?{Test-Path $_}|select -First 1
if(-not$cctk){
 Log 'Dell Command | Configure not found; attempting installation with winget.'
 $winget=(Get-Command winget.exe -EA SilentlyContinue).Source
 if($winget){&$winget install --id Dell.CommandConfigure --exact --silent --accept-source-agreements --accept-package-agreements | Out-Host}
 $cctk=$paths|?{Test-Path $_}|select -First 1
}
if(-not$cctk){Log 'Dell Command | Configure could not be installed automatically. Install it from Dell Support, then rerun.' 'ERROR';throw 'Dell Command | Configure is required.'}
Log "Using CCTK: $cctk" 'SUCCESS'

function Invoke-CCTK([string[]]$a){
 $all=@($a);if($pwd){$all+="--valsetuppwd=$pwd"}
 $o=&$cctk @all 2>&1;$code=$LASTEXITCODE;@{Output=($o-join"`n");Code=$code}
}
function SetDell($friendly,[string[]]$attempts){
 foreach($cmd in $attempts){
  $parts=$cmd -split ' ',2;$arg=$parts[0]
  $r=Invoke-CCTK @($arg)
  if($r.Code-eq 0){Log "$friendly configured using $arg. $($r.Output)" 'SUCCESS';return}
  if($r.Output-match 'not available|not supported|invalid option|does not exist'){continue}
  Log "$friendly attempt $arg returned: $($r.Output)" 'WARN'
 }
 Log "$friendly is unavailable or uses an unknown attribute on this model." 'UNSUPPORTED'
}
# Attribute/value names are Dell CCTK names and can vary by generation.
SetDell 'Wake on WLAN / LAN' @('--wakeonlan=lanwlan','--wakeonlan=wlan','--wakeonlan=lanorwlan')
SetDell 'Power On from Keyboard/USB' @('--usbwakesupport=enable','--wakeonusb=enable')
SetDell 'After Power Loss = Power On' @('--acpower=on','--acpowerrecovery=on')
SetDell 'Wake-on-LAN password policy' @('--wakeonlanpassword=enable','--wolpassword=enable')
SetDell 'Startup/POST delay = 30 seconds' @('--postdelay=30','--postmebs=30')
SetDell 'Boot audio alerts disabled' @('--audiomessages=disable','--postaudio=disable')
SetDell 'USB power while off' @('--usbpowershare=enable','--usbpowerdelivery=enable')
Log "Finished. Restart to apply firmware changes. Log: $LogFile" 'SUCCESS';return
