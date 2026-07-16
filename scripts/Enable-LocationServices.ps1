#requires -Version 5.1
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$locationKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\LocationAndSensors'
$appPrivacyKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy'

Write-Host '[INFO] Removing policies that disable Windows location.'
Remove-ItemProperty -Path $locationKey -Name 'DisableLocation' -ErrorAction SilentlyContinue
Remove-ItemProperty -Path $locationKey -Name 'DisableWindowsLocationProvider' -ErrorAction SilentlyContinue
Remove-ItemProperty -Path $locationKey -Name 'DisableSensors' -ErrorAction SilentlyContinue
Remove-ItemProperty -Path $appPrivacyKey -Name 'LetAppsAccessLocation' -ErrorAction SilentlyContinue

Write-Host '[INFO] Restoring the Windows Geolocation Service.'
sc.exe config lfsvc start= demand | Out-Null
sc.exe start lfsvc | Out-Null

Write-Host '[INFO] Refreshing local policy. This may take a moment.'
gpupdate.exe /force
Write-Host '[SUCCESS] Location restrictions were removed. Restart Windows to finish applying the change.'
