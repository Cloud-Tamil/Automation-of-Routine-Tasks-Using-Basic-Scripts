[CmdletBinding()]
param(
    [string]$InstallPath = "C:\ServerSessionManager",
    [string]$TaskName = "Server-Idle-Session-Monitor"
)

$ErrorActionPreference = "Stop"

# Verify elevated Administrator privileges
$principalCheck = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principalCheck.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Run Register-Task.ps1 from an elevated Administrator PowerShell prompt."
}

$script = Join-Path $InstallPath "Monitor-Sessions.ps1"
$configPath = Join-Path $InstallPath "config.json"
if (-not (Test-Path -LiteralPath $script) -or -not (Test-Path -LiteralPath $configPath)) {
    throw "Copy Monitor-Sessions.ps1 and config.json to $InstallPath first."
}

$config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
$logDir = [Environment]::ExpandEnvironmentVariables([string]$config.LogDirectory)
New-Item -ItemType Directory -Path $logDir -Force | Out-Null

$eventSource = if ($null -ne $config.PSObject.Properties["EventLogSource"]) { [string]$config.EventLogSource } else { "ServerSessionManager" }
if (-not [System.Diagnostics.EventLog]::SourceExists($eventSource)) {
    New-EventLog -LogName Application -Source $eventSource
}

$intervalMinutes = if ($null -ne $config.PSObject.Properties["ScanIntervalMinutes"] -and [int]$config.ScanIntervalMinutes -ge 5) {
    [int]$config.ScanIntervalMinutes
} else {
    60
}

$action = New-ScheduledTaskAction `
    -Execute "PowerShell.exe" `
    -Argument "-NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -File `"$script`" -ConfigPath `"$configPath`""

# Use 3650 days (10 years) because [TimeSpan]::MaxValue overflows Task Scheduler XML schema (0x80041318)
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(2) `
    -RepetitionInterval (New-TimeSpan -Minutes $intervalMinutes) `
    -RepetitionDuration (New-TimeSpan -Days 3650)

$principal = New-ScheduledTaskPrincipal -UserId "NT AUTHORITY\SYSTEM" -LogonType ServiceAccount -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 10) `
    -MultipleInstances IgnoreNew

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force -ErrorAction Stop | Out-Null
Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop | Out-Null
Write-Host "Registered task '$TaskName' (every $intervalMinutes min as SYSTEM). DryRun=$($config.DryRun)." -ForegroundColor Green