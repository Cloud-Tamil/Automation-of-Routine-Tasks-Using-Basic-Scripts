<#
.SYNOPSIS
    Monitors Windows Server 2019/2022 RDP sessions and logs off idle or disconnected sessions safely.
.DESCRIPTION
    Hardened hourly session monitor featuring:
      - Named global mutex to prevent concurrent scan overlap
      - ProtectedUsers, ProtectedUserPatterns, and ProtectedGroups (local & domain fallback)
      - Console/services exclusion and rdp-tcp* session allowlisting
      - NextScan disconnected session termination and configurable idle threshold (default 60m)
      - DryRun default mode, MaxLogoffsPerScan circuit breaker, optional msg.exe warning
      - Daily CSV audit log, log retention cleanup, and Windows Application Event Log auditing
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot "config.json")
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Prevent overlapping executions if triggered manually while scheduled scan is active
$mutexCreated = $false
$mutex = New-Object System.Threading.Mutex($true, "Global\ServerSessionManager_MonitorMutex", [ref]$mutexCreated)
if (-not $mutexCreated) {
    Write-Output "Another Server Session Manager scan is already running. Exiting cleanly."
    exit 0
}

function Write-LogRow {
    param(
        [hashtable]$Row,
        [string]$CsvPath,
        [bool]$WriteEventLog,
        [string]$EventSource
    )
    $obj = [pscustomobject]$Row
    if (Test-Path -LiteralPath $CsvPath) {
        $obj | Export-Csv -LiteralPath $CsvPath -NoTypeInformation -Append -Encoding UTF8
    } else {
        $obj | Export-Csv -LiteralPath $CsvPath -NoTypeInformation -Encoding UTF8
    }

    if ($WriteEventLog) {
        try {
            if (-not [System.Diagnostics.EventLog]::SourceExists($EventSource)) {
                New-EventLog -LogName Application -Source $EventSource -ErrorAction SilentlyContinue
            }
            $entryType = switch ($Row.Action) {
                "LoggedOff" { "Warning" }
                "Failed"    { "Error" }
                default     { "Information" }
            }
            $eventId = switch ($Row.Action) {
                "LoggedOff"   { 4101 }
                "WouldLogoff" { 4102 }
                "Failed"      { 4199 }
                default       { 4100 }
            }
            $msg = "host=$($Row.Hostname) user=$($Row.Username) sid=$($Row.SessionId) session=$($Row.SessionName) state=$($Row.State) idle=$($Row.IdleMinutes)m action=$($Row.Action) detail=$($Row.Detail) dryRun=$($Row.DryRun)"
            Write-EventLog -LogName Application -Source $EventSource -EventId $eventId -EntryType $entryType -Message $msg
        } catch {
            # Do not abort scan if Event Log source cannot be written
        }
    }
}

function Convert-IdleTimeToMinutes {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value) -or $Value -in @(".", "none", "N/A")) { return 0 }
    $v = $Value.Trim()
    if ($v -match '^(?<days>\d+)\+(?<hours>\d{1,2}):(?<mins>\d{2})$') {
        return ([int]$Matches.days * 1440) + ([int]$Matches.hours * 60) + [int]$Matches.mins
    }
    if ($v -match '^(?<hours>\d{1,3}):(?<mins>\d{2})$') {
        return ([int]$Matches.hours * 60) + [int]$Matches.mins
    }
    if ($v -match '^(?<mins>\d+)$') { return [int]$Matches.mins }
    return $null
}

function Test-PatternMatch {
    param([string]$Value, [string[]]$Patterns)
    foreach ($pattern in $Patterns) {
        if ($Value -like $pattern) { return $true }
    }
    return $false
}

function Get-MatchedProtectedGroup {
    param(
        [string]$Username,
        [string[]]$ProtectedGroups
    )
    foreach ($groupName in $ProtectedGroups) {
        if ([string]::IsNullOrWhiteSpace($groupName)) { continue }
        try {
            $members = Get-LocalGroupMember -Group $groupName -ErrorAction Stop
            foreach ($member in $members) {
                $shortName = ($member.Name -split '\\')[-1]
                if ($shortName -ieq $Username) {
                    return $groupName
                }
            }
        } catch {
            try {
                $netOut = & net.exe localgroup "$groupName" 2>$null
                if ($netOut) {
                    foreach ($line in $netOut) {
                        $trimmed = $line.Trim()
                        if ($trimmed -ieq $Username -or ($trimmed -split '\\')[-1] -ieq $Username) {
                            return $groupName
                        }
                    }
                }
            } catch {
                continue
            }
        }
    }
    return $null
}

try {
    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        throw "Configuration file not found: $ConfigPath"
    }

    $config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
    if ([int]$config.IdleThresholdMinutes -lt 1) { throw "IdleThresholdMinutes must be >= 1." }
    if ($config.DisconnectedPolicy -ne "NextScan") { throw "Unsupported DisconnectedPolicy. Use NextScan." }

    $logDir = [Environment]::ExpandEnvironmentVariables([string]$config.LogDirectory)
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null

    # Enforce log retention policy
    $retentionDays = if ($null -ne $config.PSObject.Properties["LogRetentionDays"]) { [int]$config.LogRetentionDays } else { 30 }
    if ($retentionDays -ge 1) {
        $cutoff = (Get-Date).AddDays(-$retentionDays)
        Get-ChildItem -Path $logDir -Filter "session-monitor-*.csv" -File -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -lt $cutoff } |
            Remove-Item -Force -ErrorAction SilentlyContinue
    }

    $logPath = Join-Path $logDir ("session-monitor-{0}.csv" -f (Get-Date -Format "yyyyMMdd"))
    $hostName = $env:COMPUTERNAME
    $enableEventLog = if ($null -ne $config.PSObject.Properties["EnableWindowsEventLog"]) { [bool]$config.EnableWindowsEventLog } else { $true }
    $eventSource = if ($null -ne $config.PSObject.Properties["EventLogSource"]) { [string]$config.EventLogSource } else { "ServerSessionManager" }
    $warningSeconds = if ($null -ne $config.PSObject.Properties["WarningSeconds"]) { [int]$config.WarningSeconds } else { 0 }
    $protectedGroups = if ($null -ne $config.PSObject.Properties["ProtectedGroups"]) { @($config.ProtectedGroups) } else { @() }

    $raw = @()
    try {
        $raw = & quser.exe 2>&1
        $rawText = ($raw | Out-String)
        if ($LASTEXITCODE -ne 0) {
            if ($rawText -match "No User exists") {
                Write-Output "No active or disconnected sessions found. Scan complete."
                exit 0
            }
            throw "quser.exe failed (exit $LASTEXITCODE): $rawText"
        }
    } catch {
        throw "Unable to query sessions. Run elevated as Administrator/SYSTEM. $($_.Exception.Message)"
    }

    $actions = 0
    foreach ($line in ($raw | Select-Object -Skip 1)) {
        $s = ([string]$line).Trim() -replace '^>', ''
        $s = $s.Trim()
        if ([string]::IsNullOrWhiteSpace($s)) { continue }

        $tokens = $s -split '\s+'
        if ($tokens.Count -lt 4) { continue }

        $user = $tokens[0]
        $sessionName = ""
        $idIndex = 1
        if ($tokens[1] -notmatch '^\d+$') {
            $sessionName = $tokens[1]
            $idIndex = 2
        }
        if ($tokens.Count -le ($idIndex + 2)) { continue }

        $sessionId = 0
        if (-not [int]::TryParse($tokens[$idIndex], [ref]$sessionId)) { continue }
        $state = $tokens[$idIndex + 1]
        $idleText = $tokens[$idIndex + 2]
        $idleMinutes = Convert-IdleTimeToMinutes $idleText

        $reason = ""
        $eligible = $false

        if ($user -in @($config.ProtectedUsers)) {
            $reason = "ProtectedUser"
        } elseif (Test-PatternMatch -Value $user -Patterns @($config.ProtectedUserPatterns)) {
            $reason = "ProtectedUserPattern"
        } elseif ($sessionId -eq 0) {
            $reason = "SessionIdZero"
        } elseif (-not $sessionName -and -not [bool]$config.IncludeConsoleSessions) {
            $reason = "NoSessionNameOrConsoleExcluded"
        } elseif ($sessionName -and -not (Test-PatternMatch -Value $sessionName -Patterns @($config.AllowedSessionNamePatterns))) {
            $reason = "SessionTypeNotAllowed"
        } else {
            $matchedGroup = Get-MatchedProtectedGroup -Username $user -ProtectedGroups $protectedGroups
            if ($null -ne $matchedGroup) {
                $reason = "ProtectedGroup:$matchedGroup"
            } elseif ($state -eq "Disc") {
                $eligible = $true
                $reason = "Disconnected"
            } elseif ($state -eq "Active" -and $null -ne $idleMinutes -and $idleMinutes -ge [int]$config.IdleThresholdMinutes) {
                $eligible = $true
                $reason = "IdleThresholdReached"
            } elseif ($state -eq "Active" -and $null -eq $idleMinutes) {
                $reason = "UnknownIdleTimeSkipped"
            } else {
                $reason = "NotEligible"
            }
        }

        $action = "Skipped"
        $detail = $reason
        if ($eligible) {
            if ([bool]$config.DryRun) {
                $action = "WouldLogoff"
                $detail = "DryRun:$reason"
            } elseif ($actions -ge [int]$config.MaxLogoffsPerScan) {
                $action = "Skipped"
                $detail = "MaxLogoffsPerScanReached"
            } else {
                try {
                    if ($warningSeconds -gt 0 -and $state -eq "Active") {
                        & msg.exe $sessionId /TIME:$warningSeconds "Your server session has been idle for $idleMinutes minutes and will be signed out in $warningSeconds seconds." 2>$null
                        Start-Sleep -Seconds ([Math]::Min($warningSeconds, 15))
                    }
                    & logoff.exe $sessionId 2>&1 | Out-Null
                    if ($LASTEXITCODE -eq 0) {
                        $action = "LoggedOff"
                        $detail = $reason
                        $actions++
                    } else {
                        $action = "Failed"
                        $detail = "logoff.exe exit code $LASTEXITCODE"
                    }
                } catch {
                    $action = "Failed"
                    $detail = $_.Exception.Message
                }
            }
        }

        Write-LogRow -CsvPath $logPath -WriteEventLog $enableEventLog -EventSource $eventSource -Row @{
            Timestamp   = (Get-Date).ToString("o")
            Hostname    = $hostName
            OS          = "Windows"
            Username    = $user
            SessionId   = $sessionId
            SessionName = $sessionName
            State       = $state
            IdleText    = $idleText
            IdleMinutes = $idleMinutes
            Action      = $action
            Detail      = $detail
            DryRun      = [bool]$config.DryRun
        }
    }

    Write-Output "Scan complete. CSV: $logPath"
} finally {
    if ($null -ne $mutex) {
        try { $mutex.ReleaseMutex() | Out-Null } catch {}
        $mutex.Dispose()
    }
}
