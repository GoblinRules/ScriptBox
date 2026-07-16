#requires -version 5.1
<#
  Lenovo BIOS configuration for supported ThinkCentre/ThinkPad/ThinkStation systems.
  Uses Lenovo's built-in WMI BIOS interface; no additional software is normally required.
  Optional ScriptBox variable: $BIOSPassword
  Unsupported settings are logged and skipped.
#>
[CmdletBinding()]
param([string]$BIOSPassword)

$ErrorActionPreference='Stop'
$LogRoot='C:\ProgramData\ScriptBox\BIOS';New-Item $LogRoot -ItemType Directory -Force|Out-Null
$LogFile=Join-Path $LogRoot ("Lenovo-BIOS-{0:yyyyMMdd-HHmmss}.log"-f(Get-Date))
function Log($m,$l='INFO'){$x='[{0:yyyy-MM-dd HH:mm:ss}] [{1}] {2}'-f(Get-Date),$l,$m;Write-Host$x;Add-Content $LogFile $x}
function IsAdmin{$p=[Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent());$p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)}
if(-not(IsAdmin)){Log 'Run elevated.' 'ERROR';throw 'Administrator rights are required.'}
$cs=Get-CimInstance Win32_ComputerSystem;if($cs.Manufacturer-notmatch'Lenovo'){Log "Not Lenovo: $($cs.Manufacturer)" 'ERROR';throw 'This BIOS script only supports Lenovo hardware.'};Log "Detected Lenovo model: $($cs.Model)"
try{$settings=@(Get-WmiObject -Namespace root\wmi -Class Lenovo_BiosSetting -EA Stop)}catch{Log "Lenovo WMI BIOS interface unavailable: $($_.Exception.Message)" 'ERROR';throw}
$set=Get-WmiObject -Namespace root\wmi -Class Lenovo_SetBiosSetting
$save=Get-WmiObject -Namespace root\wmi -Class Lenovo_SaveBiosSettings
$pwd=if([string]::IsNullOrWhiteSpace($BIOSPassword)){$null}else{$BIOSPassword}
function CurrentPairs{
 $h=@{};foreach($s in $settings){if($s.CurrentSetting){$p=$s.CurrentSetting.Split(',',2);$h[$p[0]]=$p[1]}};$h
}
function FindName([string[]]$aliases){$h=CurrentPairs;foreach($a in $aliases){$k=$h.Keys|?{$_-ieq$a}|select -First 1;if($k){return$k}};foreach($a in $aliases){$k=$h.Keys|?{$_-match[regex]::Escape($a)}|select -First 1;if($k){return$k}};$null}
function TrySet($friendly,[string[]]$aliases,[string[]]$values){
 $name=FindName $aliases;if(-not$name){Log "$friendly not exposed on this model." 'UNSUPPORTED';return}
 foreach($v in $values){
  try{
   $command="$name,$v";if($pwd){$command="$command,$pwd,ascii,us"}
   $r=$set.SetBiosSetting($command)
   if($r.return-eq'Success'){Log "$friendly staged as '$v' using '$name'." 'SUCCESS';return}
   if($r.return-match'Invalid Parameter'){continue}
   Log "$friendly '$name=$v' returned: $($r.return)" 'WARN'
  }catch{Log "$friendly attempt failed: $($_.Exception.Message)" 'WARN'}
 }
 Log "$friendly exists as '$name', but no known value was accepted." 'UNSUPPORTED'
}
TrySet 'Wake on WLAN' @('WakeOnWLAN','Wake on WLAN','WakeOnLAN') @('Enable','Enabled','Primary')
TrySet 'Power On from Keyboard/USB' @('PowerOnFromKeyboard','KeyboardPowerOn','USBWakeSupport','USB Always On') @('Enable','Enabled')
TrySet 'After Power Loss = Power On' @('AfterPowerLoss','After Power Loss','ACPowerRecovery','RestoreOnACPowerLoss') @('Power On','PowerOn','On')
TrySet 'Wake-on-LAN password policy' @('WakeOnLANPassword','WOLPasswordPolicy','Wake on LAN Password') @('Require Password','Password Required','Enable')
TrySet 'Startup/POST delay = 30 seconds' @('StartupDelay','Startup Delay','POSTDelay','BootTimeExtension') @('30','30 Seconds')
TrySet 'Boot audio alerts disabled' @('AudioAlertsDuringBoot','BootAudio','POSTAudio','StartupSound') @('Disable','Disabled','Off')
TrySet 'USB always on / charge while off' @('AlwaysOnUSB','USB Always On','ChargeInBatteryMode','USBChargeInOffMode') @('Enable','Enabled')
try{
 $cmd=if($pwd){"$pwd,ascii,us"}else{''};$r=$save.SaveBiosSettings($cmd)
 if($r.return-ne'Success'){Log "Save BIOS settings returned: $($r.return)" 'ERROR';throw 'Lenovo BIOS settings could not be saved.'}
 Log 'Lenovo BIOS changes saved.' 'SUCCESS'
}catch{Log "Could not save Lenovo BIOS settings: $($_.Exception.Message)" 'ERROR';throw}
Log "Finished. Restart to apply firmware changes. Log: $LogFile" 'SUCCESS';return
