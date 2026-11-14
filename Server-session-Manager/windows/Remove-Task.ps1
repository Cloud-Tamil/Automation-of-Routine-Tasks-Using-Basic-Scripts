[CmdletBinding()]
param([string]$TaskName = "Server-Idle-Session-Monitor")
Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
Write-Host "Removed task '$TaskName' if it existed."
