# Linux Server — End-to-End Installation Guide

This toolkit uses **separate, OS-native end-to-end installations** for Windows Server and Linux. Follow only the section for your target server OS, or open the dedicated standalone guide:

- **Windows Server 2019 / 2022 standalone guide**: [``](./WINDOWS-INSTALLATION.md)
- **Linux standalone guide (Ubuntu / Debian / RHEL / Rocky / AlmaLinux)**: [``](./LINUX-INSTALLATION.md)

---

## Part A: Windows Server 2019 / 2022 (End-to-End)

### A1. Prerequisites
- Windows Server 2019 or 2022 with Windows PowerShell 5.1+
- Local **Administrator** privileges

### A2. Create Folder & Copy Files Directly (No Nested Subfolder)
Copy the **4 files inside** `windows/` directly into `C:\ServerSessionManager`:
- `C:\ServerSessionManager\Monitor-Sessions.ps1`
- `C:\ServerSessionManager\Register-Task.ps1`
- `C:\ServerSessionManager\Remove-Task.ps1`
- `C:\ServerSessionManager\config.json`

Verify in an **elevated Administrator PowerShell** prompt:
```powershell
New-Item -ItemType Directory -Path C:\ServerSessionManager -Force | Out-Null
Get-ChildItem C:\ServerSessionManager
```
*(If a ZIP extraction left files inside `C:\ServerSessionManager\windows\`, move them up into `C:\ServerSessionManager\` before running.)*

### A3. Review Policy (`C:\ServerSessionManager\config.json`)
Keep `"DryRun": true` while testing. Verify:
- `"IdleThresholdMinutes": 60`
- `"ScanIntervalMinutes": 60`
- `"DisconnectedPolicy": "NextScan"`
- `"ProtectedUsers"`, `"ProtectedUserPatterns"`, and `"ProtectedGroups"` include all local/domain admin and service accounts
- `"AllowedSessionNamePatterns": ["rdp-tcp*"]` and `"IncludeConsoleSessions": false`

### A4. Unblock Scripts & Run Manual Dry-Run Scan
```powershell
Set-Location C:\ServerSessionManager
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
Unblock-File -Path C:\ServerSessionManager\*.ps1
.\Monitor-Sessions.ps1 -ConfigPath .\config.json
```

Inspect active sessions, the daily CSV report, and the Application Event Log:
```powershell
quser
Import-Csv "C:\ProgramData\ServerSessionManager\logs\session-monitor-$(Get-Date -Format 'yyyyMMdd').csv" | Format-Table -AutoSize
Get-EventLog -LogName Application -Source ServerSessionManager -Newest 20 | Format-Table TimeGenerated, EventID, EntryType, Message -Wrap
```
Dry-run entries show `Action = WouldLogoff`. No user is signed out.

### A5. Register & Manual Check for the Hourly Scheduled Task
```powershell
.\Register-Task.ps1 -InstallPath C:\ServerSessionManager

# Manual PowerShell task checks (State=Ready, Trigger=1h, LastTaskResult=0)
Get-ScheduledTask -TaskName "Server-Idle-Session-Monitor" | Select-Object TaskName, State
(Get-ScheduledTask -TaskName "Server-Idle-Session-Monitor").Triggers | Select-Object Enabled, Repetition
Start-ScheduledTask -TaskName "Server-Idle-Session-Monitor"
Start-Sleep -Seconds 5
Get-ScheduledTaskInfo -TaskName "Server-Idle-Session-Monitor" | Select-Object LastRunTime, LastTaskResult, NextRunTime, NumberOfMissedRuns
Get-WinEvent -LogName "Microsoft-Windows-TaskScheduler/Operational" -MaxEvents 15 |
  Where-Object { $_.Message -like "*Server-Idle-Session-Monitor*" } |
  Format-Table TimeCreated, Id, LevelDisplayName, Message -Wrap
```
**Manual GUI check (`taskschd.msc`)**: Open `taskschd.msc` → **Task Scheduler Library** → verify `Server-Idle-Session-Monitor` is `Ready` (runs as `NT AUTHORITY\SYSTEM` every `60` minutes), right-click → **Run**, and check the **History** tab (`Event ID 102`/`201`, return code `0`).

### A6. Validate with a Disposable RDP Account & Enable Live Logoff
1. Test with a non-admin RDP account left idle `>= 60` minutes or in `Disc` state and confirm `WouldLogoff` in the CSV.
2. Edit `C:\ServerSessionManager\config.json` and set `"DryRun": false` (no task re-registration needed):
```powershell
(Get-Content C:\ServerSessionManager\config.json -Raw) -replace '"DryRun"\s*:\s*true', '"DryRun": false' |
  Set-Content C:\ServerSessionManager\config.json -Encoding UTF8
```
3. Run `Start-ScheduledTask -TaskName "Server-Idle-Session-Monitor"` and confirm `LoggedOff` (`EventID 4101`).

### A7. Optional RDS Group Policy Baseline (`gpedit.msc`)
Navigate to **Computer Configuration → Administrative Templates → Windows Components → Remote Desktop Services → Remote Desktop Session Host → Session Time Limits**, configure idle/disconnected limits + **End session when time limits are reached**, and run:
```powershell
gpupdate /force
```

### A8. Windows Rollback / Uninstall
```powershell
Set-Location C:\ServerSessionManager
.\Remove-Task.ps1 -TaskName "Server-Idle-Session-Monitor"
# Optional complete cleanup:
# Remove-Item -Path C:\ServerSessionManager, C:\ProgramData\ServerSessionManager -Recurse -Force
```

---

## Part B: Linux — Ubuntu / Debian / RHEL / Rocky / AlmaLinux (End-to-End)

### B1. Prerequisites
- `systemd` (`systemctl`, `loginctl`), `procps`/`procps-ng` (`w`), `util-linux` (`flock`), `openssh-server` (`sshd`), and `root`/`sudo` access.

### B2. Prepare Files & Run Installer
Copy the `linux/` folder to the target server (e.g. `/tmp/server-session-manager/linux/`) and run:
```bash
cd /tmp/server-session-manager/linux
sed -i 's/\r$//' install.sh monitor-sessions.sh config.conf session-monitor.service session-monitor.timer
chmod +x install.sh monitor-sessions.sh
sudo ./install.sh
```
This installs:
- `/opt/server-session-manager/monitor-sessions.sh` (`0750`)
- `/opt/server-session-manager/config.conf` (`0640`)
- `/var/log/server-session-manager/` (`0750`)
- `/etc/systemd/system/session-monitor.service` & `session-monitor.timer` (enabled & started)
- `/etc/ssh/sshd_config.d/99-server-session-keepalive.conf` (`ClientAliveInterval 300`, `ClientAliveCountMax 2`, validated via `sshd -t`)

*(For manual installation commands without `install.sh`, see [``](./LINUX-INSTALLATION.md).)*

### B3. Review Policy (`/opt/server-session-manager/config.conf`)
Keep `DRY_RUN=true` during initial testing and verify `PROTECTED_USERS`, `PROTECTED_USER_PATTERNS`, and `PROTECTED_GROUPS`:
```bash
sudoedit /opt/server-session-manager/config.conf
```

### B4. Run Manual Dry-Run Scan & Inspect Logs
```bash
LC_ALL=C PROCPS_USERLEN=64 w -h
loginctl list-sessions
sudo /opt/server-session-manager/monitor-sessions.sh
sudo tail -n 30 "/var/log/server-session-manager/session-monitor-$(date +%Y%m%d).csv"
sudo journalctl -t server-session-manager -n 30 --no-pager
```

### B5. Manual Check for the Hourly `systemd` Timer & Service
```bash
systemctl is-enabled session-monitor.timer
systemctl is-active session-monitor.timer
systemctl list-timers session-monitor.timer --all --no-pager
sudo systemctl start session-monitor.service
sudo systemctl status session-monitor.service --no-pager
sudo journalctl -u session-monitor.service --since today --no-pager
```

### B6. Validate SSH Keepalives (Dead-Client Detection)
Keep an existing admin SSH session open in another terminal while checking:
```bash
sudo sshd -t
sudo sshd -T | grep -iE 'clientaliveinterval|clientalivecountmax'
```
If your distro's `/etc/ssh/sshd_config` does not include `/etc/ssh/sshd_config.d/*.conf`, back up `/etc/ssh/sshd_config`, add `ClientAliveInterval 300` and `ClientAliveCountMax 2`, run `sudo sshd -t`, and reload `sshd` / `ssh`.

### B7. Validate with a Disposable SSH Account & Enable Live Termination
1. Connect via SSH with a non-admin test user (`UID >= 1000`) and confirm it appears in both `w -h` and `loginctl list-sessions` (`Service=sshd`, `Remote=yes`).
2. Confirm `WouldLogoff` in the CSV once idle `>= 60` minutes.
3. Enable live enforcement:
```bash
sudo sed -i 's/^DRY_RUN=true/DRY_RUN=false/' /opt/server-session-manager/config.conf
grep '^DRY_RUN=' /opt/server-session-manager/config.conf
```
4. Trigger `sudo systemctl start session-monitor.service` and confirm `LoggedOff` in the CSV and journal.

### B8. Linux Rollback / Uninstall
```bash
sudo systemctl disable --now session-monitor.timer
sudo rm -f /etc/systemd/system/session-monitor.timer /etc/systemd/system/session-monitor.service
sudo systemctl daemon-reload
sudo rm -f /etc/ssh/sshd_config.d/99-server-session-keepalive.conf
sudo sshd -t && (sudo systemctl reload sshd || sudo systemctl reload ssh)
# Optional complete cleanup:
# sudo rm -rf /opt/server-session-manager /var/log/server-session-manager
```
