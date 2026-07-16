#requires -Version 5.1
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Write-Host '[INFO] Scheduling a Windows restart in 10 seconds.'
shutdown.exe /r /t 10 /c "Restart started from ScriptBox"
if ($LASTEXITCODE -ne 0) { throw "Windows rejected the restart request with exit code $LASTEXITCODE." }
Write-Host '[SUCCESS] Restart scheduled. Run shutdown /a within 10 seconds to cancel.'
