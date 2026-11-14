#!/usr/bin/env bash
# Single-command installer for Ubuntu, Debian, RHEL, Rocky Linux, and AlmaLinux.
set -euo pipefail

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  echo "ERROR: Run install.sh as root (sudo ./install.sh)." >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "[1/5] Verifying prerequisites..."
if command -v apt-get >/dev/null 2>&1; then
  apt-get update -qq
  apt-get install -y -qq util-linux procps systemd openssh-server
elif command -v dnf >/dev/null 2>&1; then
  dnf install -y -q util-linux procps-ng systemd openssh-server
elif command -v yum >/dev/null 2>&1; then
  yum install -y -q util-linux procps-ng systemd openssh-server
fi

echo "[2/5] Installing monitor script and policy config..."
install -d -o root -g root -m 0750 /opt/server-session-manager
install -d -o root -g root -m 0750 /var/log/server-session-manager
install -o root -g root -m 0750 "$SCRIPT_DIR/monitor-sessions.sh" /opt/server-session-manager/monitor-sessions.sh

if [[ ! -f /opt/server-session-manager/config.conf ]]; then
  install -o root -g root -m 0640 "$SCRIPT_DIR/config.conf" /opt/server-session-manager/config.conf
else
  echo "Preserving existing /opt/server-session-manager/config.conf (wrote new template to config.conf.new)."
  install -o root -g root -m 0640 "$SCRIPT_DIR/config.conf" /opt/server-session-manager/config.conf.new
fi

echo "[3/5] Installing systemd service and hourly timer..."
install -o root -g root -m 0644 "$SCRIPT_DIR/session-monitor.service" /etc/systemd/system/session-monitor.service
install -o root -g root -m 0644 "$SCRIPT_DIR/session-monitor.timer" /etc/systemd/system/session-monitor.timer
systemctl daemon-reload
systemctl enable --now session-monitor.timer

echo "[4/5] Configuring SSH keepalives for dead-client detection..."
if [[ -d /etc/ssh/sshd_config.d ]]; then
  cat <<'EOF' > /etc/ssh/sshd_config.d/99-server-session-keepalive.conf
# Detect unresponsive/dead SSH clients after ~10 minutes (300s x 2)
ClientAliveInterval 300
ClientAliveCountMax 2
EOF
  if sshd -t; then
    systemctl reload sshd 2>/dev/null || systemctl reload ssh 2>/dev/null || true
  else
    echo "WARNING: sshd -t failed; remove /etc/ssh/sshd_config.d/99-server-session-keepalive.conf and check sshd_config." >&2
  fi
fi

echo "[5/5] Verifying timer schedule..."
systemctl list-timers session-monitor.timer --no-pager
echo "Done. DRY_RUN remains controlled by /opt/server-session-manager/config.conf."
