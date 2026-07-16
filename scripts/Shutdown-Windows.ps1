#requires -Version 5.1
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Write-Host '[INFO] Scheduling a Windows shutdown in 30 seconds.'
shutdown.exe /s /t 30 /c "Shutdown started from ScriptBox"
if ($LASTEXITCODE -ne 0) { throw "Windows rejected the shutdown request with exit code $LASTEXITCODE." }
Write-Host '[SUCCESS] Shutdown scheduled. Run shutdown /a within 30 seconds to cancel.'
