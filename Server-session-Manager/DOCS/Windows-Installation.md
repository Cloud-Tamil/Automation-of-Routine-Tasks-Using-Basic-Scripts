# Windows Server — End-to-End Installation Guide

Complete, standalone installation, verification, scheduling, hardening, and rollback guide for **Windows Server 2019** and **Windows Server** (single-server deployment).

---

## 1. Prerequisites

- **OS**: Windows Server 2019 or Windows Server 2022 (Desktop Experience or Server Core).
- **Privileges**: Local **Administrator** privileges to copy files, create the Application Event Log source, and register the `NT AUTHORITY\SYSTEM` Scheduled Task.
- **PowerShell**: Windows PowerShell 5.1+ (built into Windows Server 2019/2022).
- **Built-in OS tools used**: `quser.exe`, `logoff.exe`, `msg.exe` (all standard on Windows Server).

---

## 2. Create Install Directory & Copy Files

Create `C:\ServerSessionManager` and copy the **4 files inside** `windows/` directly into `C:\ServerSessionManager` (do **not** leave them inside a nested `C:\ServerSessionManager\windows\` folder):

- `C:\ServerSessionManager\windows\Monitor-Sessions.ps1`
- `C:\ServerSessionManager\windows\Register-Task.ps1`
- `C:\ServerSessionManager\windows\Remove-Task.ps1`
- `C:\ServerSessionManager\windows\config.json`

Open **Windows PowerShell as Administrator** and verify the directory layout:

```powershell
New-Item -ItemType Directory -Path C:\ServerSessionManager -Force | Out-Null
Get-ChildItem C:\ServerSessionManager
```

If you extracted a ZIP and accidentally ended up with a nested `windows\` subfolder, flatten it with:

```powershell
Get-ChildItem C:\ServerSessionManager -Recurse -File |
  Where-Object { $_.DirectoryName -ne "C:\ServerSessionManager" -and $_.Name -in @("Monitor-Sessions.ps1","Register-Task.ps1","Remove-Task.ps1","config.json") } |
  Move-Item -Destination C:\ServerSessionManager -Force
Get-ChildItem C:\ServerSessionManager
```

---

## 3. Configure Policy (`C:\ServerSessionManager\config.json`)

Review `C:\ServerSessionManager\config.json` in Notepad or PowerShell before running anything. **Keep `"DryRun": true` during initial validation.**

Key settings in `config.json`:

| Setting | Default | Description |
| :--- | :--- | :--- |
| `IdleThresholdMinutes` | `60` | Minimum active RDP idle minutes before a session qualifies for logoff. |
| `ScanIntervalMinutes` | `60` | How often the Scheduled Task runs (minimum 5). |
| `DisconnectedPolicy` | `"NextScan"` | Disconnected (`Disc`) RDP sessions qualify on the next hourly scan. |
| `DryRun` | `true` | `true` logs `WouldLogoff` without terminating sessions; `false` performs real logoffs. |
| `MaxLogoffsPerScan` | `10` | Safety cap limiting how many sessions can be signed out in a single scan. |
| `WarningSeconds` | `0` | Optional `msg.exe` countdown notice shown to active idle users before logoff (`0` = disabled). |
| `ProtectedUsers` | `["Administrator", ...]` | Exact usernames that are never logged off. Add all break-glass/admin accounts here. |
| `ProtectedUserPatterns` | `["svc_*", "service_*", "sql_*"]` | Wildcard patterns for service accounts. |
| `ProtectedGroups` | `["Administrators", "Domain Admins", "Enterprise Admins"]` | Local/domain group names whose members are never logged off. |
| `AllowedSessionNamePatterns` | `["rdp-tcp*"]` | Restricts evaluation to RDP sessions. |
| `IncludeConsoleSessions` | `false` | Keeps physical/VMware/Hyper-V console sessions excluded. |
| `EnableWindowsEventLog` | `true` | Writes audit events (`4100`–`4199`) to Application Event Log under source `ServerSessionManager`. |
| `LogRetentionDays` | `30` | Automatically deletes CSV logs older than 30 days. |
| `LogDirectory` | `C:\ProgramData\ServerSessionManager\logs` | Output folder for daily `session-monitor-yyyyMMdd.csv` files. |

---

## 4. Unblock Scripts & Run Manual Dry-Run Test

In your **elevated Administrator PowerShell** window:

```powershell
Set-Location C:\ServerSessionManager
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
Unblock-File -Path C:\ServerSessionManager\*.ps1
.\Monitor-Sessions.ps1 -ConfigPath .\config.json
```

Verify the current sessions and check the generated CSV and Event Log:

```powershell
quser
$csv = "C:\ProgramData\ServerSessionManager\logs\session-monitor-$(Get-Date -Format 'yyyyMMdd').csv"
Import-Csv $csv | Format-Table -AutoSize
Get-EventLog -LogName Application -Source ServerSessionManager -Newest 20 | Format-Table TimeGenerated, EventID, EntryType, Message -Wrap
```

Expected behavior in Dry-Run mode:
- Active RDP sessions idle `>= 60` minutes and `Disc` RDP sessions report `Action = WouldLogoff`.
- Protected users/groups and console sessions report `Action = Skipped`.
- No user is actually signed out.

---

## 5. Register & Manual Check for the Hourly Scheduled Task

Run the installer script from `C:\ServerSessionManager`:

```powershell
.\Register-Task.ps1 -InstallPath C:\ServerSessionManager
```

This creates the Scheduled Task `Server-Idle-Session-Monitor`:
- Principal: `NT AUTHORITY\SYSTEM` with highest privileges
- Trigger: Runs every `ScanIntervalMinutes` (default `60` minutes) for 10 years (`New-TimeSpan -Days 3650`, avoiding the `0x80041318` XML overflow error)
- Settings: `-MultipleInstances IgnoreNew`, `-StartWhenAvailable`, `10`-minute execution time limit

### Manual Check — PowerShell
Verify the task registration, trigger interval, principal, and run it manually on demand:

```powershell
# 1. Confirm task exists, is Ready, and runs every 60 minutes as SYSTEM
Get-ScheduledTask -TaskName "Server-Idle-Session-Monitor" | Select-Object TaskName, State
(Get-ScheduledTask -TaskName "Server-Idle-Session-Monitor").Triggers | Select-Object Enabled, StartBoundary, Repetition
(Get-ScheduledTask -TaskName "Server-Idle-Session-Monitor").Principal | Select-Object UserId, RunLevel

# 2. Trigger the Scheduled Task manually right now
Start-ScheduledTask -TaskName "Server-Idle-Session-Monitor"
Start-Sleep -Seconds 5

# 3. Check last run result (0 = success), next scheduled run time, and missed runs
Get-ScheduledTaskInfo -TaskName "Server-Idle-Session-Monitor" | Select-Object LastRunTime, LastTaskResult, NextRunTime, NumberOfMissedRuns

# 4. Inspect Task Scheduler operational history events for this task
Get-WinEvent -LogName "Microsoft-Windows-TaskScheduler/Operational" -MaxEvents 20 |
  Where-Object { $_.Message -like "*Server-Idle-Session-Monitor*" } |
  Format-Table TimeCreated, Id, LevelDisplayName, Message -Wrap
```

### Manual Check — Task Scheduler GUI (`taskschd.msc`)
1. Press `Win + R`, run `taskschd.msc`, and click **Task Scheduler Library**.
2. Locate **`Server-Idle-Session-Monitor`** (press `F5` to refresh if needed) and verify **Status** is `Ready`.
3. Double-click the task and confirm:
    - **General** tab: **Run whether user is logged on or not**, **Run with highest privileges**, account `NT AUTHORITY\SYSTEM`.
    - **Triggers** tab: Enabled, **Repeat task every: `1 hour`**.
    - **Actions** tab: `PowerShell.exe` with `-NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -File "C:\ServerSessionManager\Monitor-Sessions.ps1" -ConfigPath "C:\ServerSessionManager\config.json"`.
    - **History** tab: Shows Task Completed (`Event ID 102` / `201`) with return code `0`.
4. Right-click **`Server-Idle-Session-Monitor`** → **Run** to execute a manual test run from the UI, then confirm a new timestamped set of rows was appended to `C:\ProgramData\ServerSessionManager\logs\session-monitor-$(Get-Date -Format 'yyyyMMdd').csv`.

---

## 6. Validate with a Test Account & Enable Live Enforcement

1. Sign in to the server via RDP using a **disposable test account** (not in `Administrators` or `ProtectedUsers`).
2. Leave one test session idle past `IdleThresholdMinutes` (or disconnect the RDP window without signing out).
3. Run `Start-ScheduledTask -TaskName "Server-Idle-Session-Monitor"` and verify the CSV marks that test account as `WouldLogoff`.
4. Edit `C:\ServerSessionManager\config.json` and change `"DryRun": true` to `"DryRun": false`:

```powershell
(Get-Content C:\ServerSessionManager\config.json -Raw) -replace '"DryRun"\s*:\s*true', '"DryRun": false' |
  Set-Content C:\ServerSessionManager\config.json -Encoding UTF8
```

5. Run one more manual or scheduled scan and verify the test account is logged off (`Action = LoggedOff`, `EventID = 4101`). You do **not** need to re-run `Register-Task.ps1` after changing `config.json`.

---

## 7. Optional: Native RDS Group Policy Baseline (`gpedit.msc`)

For defense-in-depth alongside the hourly PowerShell monitor:

1. Run `gpedit.msc`.
2. Navigate to **Computer Configuration → Administrative Templates → Windows Components → Remote Desktop Services → Remote Desktop Session Host → Session Time Limits**.
3. Configure:
    - **Set time limit for disconnected sessions** → Enabled (e.g., `1 hour` or `30 minutes`)
    - **Set time limit for active but idle Remote Desktop Services sessions** → Enabled (`1 hour`)
    - **End session when time limits are reached** → Enabled
4. Apply policy immediately:

```powershell
gpupdate /force
```

---

## 8. Rollback & Uninstall

To disable and remove the Scheduled Task immediately:

```powershell
Set-Location C:\ServerSessionManager
.\Remove-Task.ps1 -TaskName "Server-Idle-Session-Monitor"
```

To pause enforcement without removing the task, set `"DryRun": true` in `C:\ServerSessionManager\config.json`.

To completely remove all scripts and logs:

```powershell
.\Remove-Task.ps1 -TaskName "Server-Idle-Session-Monitor"
Remove-Item -Path C:\ServerSessionManager -Recurse -Force
Remove-Item -Path C:\ProgramData\ServerSessionManager -Recurse -Force
```
