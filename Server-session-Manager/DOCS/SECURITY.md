# Security and production safety

1. **Dry-run first.** Both implementations default to dry-run. Review several hourly scans before enabling termination.
2. **Protect identities.** Add all named administrators, break-glass accounts, database/service users, automation users, and monitoring accounts to the protected list.
3. **Least privilege.** The scheduled task/service needs privileges to enumerate and end sessions. Protect scripts and configuration so ordinary users cannot modify them.
4. **Scope.** Windows targets RDP session names matching `rdp-tcp*`; console sessions are excluded by default. Linux targets only remote `sshd` logind sessions.
5. **Avoid broad process killing.** Do not use `pkill -u`, `killall`, or kill every process belonging to a user. Linux uses `loginctl terminate-session` only after matching the user, TTY, remote flag, sshd service and active state.
6. **Limit actions.** The per-scan maximum limits accidental mass logoff.
7. **Unsaved work.** Logging off ends user processes and can lose unsaved work. Provide a warning/grace period if your operational policy requires one; this package does not implement an interactive warning.
8. **Audit.** Restrict access to logs. Forward them to your central log platform if required.
9. **Scheduling overlap.** Windows Task Scheduler uses `IgnoreNew`; systemd oneshot service instances are not run concurrently.
10. **Change management.** Test on a non-production server and obtain server-owner approval before setting dry-run false.

## Known limitations

- Windows `quser` output is localized and may vary between OS builds. Validate parsing on the server language/build before production.
- Linux `w` idle values and logind session registration depend on distro, PAM, terminal and SSH configuration. Unsupported/ambiguous sessions are skipped.
- SSH keepalive identifies an unresponsive client transport, not a human's idle activity.
- This is a local agent for one server, not a fleet management/control plane.
