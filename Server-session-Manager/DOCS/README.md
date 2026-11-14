# Cross-Platform Server Idle Session Manager

A hardened, single-server toolkit for **Windows Server 2019 / 2022** and **systemd-based Linux distributions** (Ubuntu, Debian, RHEL, Rocky Linux, AlmaLinux). It scans sessions once per hour, logs all evaluations to daily CSV and system event logs, and signs out qualifying idle or disconnected sessions only when Dry-Run mode is explicitly turned off.

## Safety Defaults & Protection Layers

- **Dry-run enabled by default** (`"DryRun": true` on Windows, `DRY_RUN=true` on Linux).
- **Windows Server 2019 / 2022**:
  - Evaluates RDP sessions matching `rdp-tcp*` (`IncludeConsoleSessions: false`, `SessionId = 0` excluded).
  - Active RDP sessions idle `>= 60` minutes and disconnected (`Disc`) RDP sessions are eligible on the next hourly scan.
  - Protects `ProtectedUsers`, `ProtectedUserPatterns` (`svc_*`, `service_*`, `sql_*`), and `ProtectedGroups` (`Administrators`, `Domain Admins`, `Enterprise Admins`).
  - Prevents overlapping runs via a named global mutex and enforces `MaxLogoffsPerScan` (`10`) plus 30-day CSV retention.
- **Linux (Ubuntu, Debian, RHEL, Rocky Linux, AlmaLinux)**:
  - Correlates `w` terminal-idle timestamps (`LC_ALL=C`, `PROCPS_USERLEN=64` with TTY owner resolution to prevent truncated usernames) against active remote `sshd` sessions registered in `systemd-logind`.
  - Unknown or ambiguous idle values (`old`, `?`, `-`) and uncorrelated sessions are skipped safely.
  - Protects `UID < 1000`, `PROTECTED_USERS`, `PROTECTED_USER_PATTERNS`, and `PROTECTED_GROUPS` (`sudo`, `wheel`, `adm`).
  - Uses `flock` overlap locking, `loginctl terminate-session` (never blind `killall`/`pkill`), `MAX_TERMINATIONS_PER_SCAN` (`5`), and 30-day CSV retention.
- **Disconnected SSH Connections**: Linux cannot reliably label every SSH socket as "disconnected" the way RDP does. Dead TCP transports are cleaned up via `sshd` keepalives (`ClientAliveInterval 300`, `ClientAliveCountMax 2`), not guessed by killing arbitrary processes.
- **Unsaved Work Notice**: Logging out terminates user processes and can discard unsaved work. Always validate in Dry-Run mode and test with a disposable non-production account before setting Dry-Run to `false`.

## Contents

- `../windows/Monitor-Sessions.ps1` — Windows session scanner, protection guards, Event Log + CSV auditing, and safe logoff.
- `../windows/config.json` — Windows policy configuration.
- `../windows/Register-Task.ps1` — Registers the hourly `NT AUTHORITY\SYSTEM` Scheduled Task (`IgnoreNew` overlap guard).
- `../windows/Remove-Task.ps1` — Removes the Scheduled Task cleanly.
- `../linux/monitor-sessions.sh` — Linux session scanner correlating `w` and `loginctl` with `flock` overlap protection.
- `../linux/config.conf` — Linux policy configuration.
- `../linux/session-monitor.service` & `linux/session-monitor.timer` — Hourly systemd scheduling with `Persistent=true`.
- `../linux/install.sh` — Cross-distro root installer (configures scripts, `sshd` keepalives with `sshd -t`, and `systemd` timer).
- `DOCS` — Detailed installation, RDS Group Policy, and rollback steps.
- `DOCS` — Safety architecture and known OS limitations.
- `DOCS` — Diagnostics for `quser`, `loginctl`, `w`, and `sshd`.
- `../reports/sample-report.csv` — Example dry-run audit CSV output.

## Quick Start

### Windows Server 2019 / 2022

1. Copy `../windows` to `C:\ServerSessionManager\`.
2. Review `config.json` and keep `"DryRun": true` for initial validation.
3. Open PowerShell **as Administrator** and run:
   ```powershell
   Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
   cd C:\ServerSessionManager
   .\Register-Task.ps1
   ```
4. Trigger a manual dry-run scan and inspect `C:\ProgramData\ServerSessionManager\logs\`:
   ```powershell
   .\Monitor-Sessions.ps1 -ConfigPath .\config.json
   ```
5. After confirming expected results on a disposable RDP account, set `"DryRun": false` in `config.json` (no task re-registration required).

### Linux (Ubuntu, Debian, RHEL, Rocky Linux, AlmaLinux)

1. Copy `../linux` to the target server and review `config.conf` (`DRY_RUN=true`).
2. Run the automated installer as root:
   ```bash
   chmod +x linux/install.sh linux/monitor-sessions.sh
   sudo ./linux/install.sh
   ```
3. Run a manual dry-run scan and inspect logs:
   ```bash
   sudo /opt/server-session-manager/monitor-sessions.sh
   sudo journalctl -u session-monitor.service -n 50 --no-pager
   sudo tail -n 30 /var/log/server-session-manager/session-monitor-$(date +%Y%m%d).csv
   ```
4. After validating with a disposable SSH account, set `DRY_RUN=false` in `/opt/server-session-manager/config.conf`.
