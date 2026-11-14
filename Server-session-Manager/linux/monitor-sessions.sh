#!/usr/bin/env bash
# Cross-Distro Linux Idle Session Monitor (Ubuntu, Debian, RHEL, Rocky, AlmaLinux)
# Correlates `w` terminal-idle values with active remote sshd sessions in systemd-logind.

set -euo pipefail

# Ensure deterministic 24h time format and prevent 8-char username truncation in `w`
export LC_ALL=C
export PROCPS_USERLEN=64

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_PATH="${1:-${CONFIG_PATH:-$SCRIPT_DIR/config.conf}}"
if [[ ! -f "$CONFIG_PATH" && -f "/opt/server-session-manager/config.conf" ]]; then
  CONFIG_PATH="/opt/server-session-manager/config.conf"
fi

if [[ ! -f "$CONFIG_PATH" ]]; then
  echo "ERROR: Configuration file not found: $CONFIG_PATH" >&2
  exit 1
fi

IDLE_THRESHOLD_MINUTES=60
DRY_RUN=true
MAX_TERMINATIONS_PER_SCAN=5
LOG_RETENTION_DAYS=30
LOG_DIR="/var/log/server-session-manager"
PROTECTED_USERS=("root" "admin" "administrator" "postgres" "mysql" "oracle")
PROTECTED_USER_PATTERNS=("svc_*" "service_*" "sql_*")
PROTECTED_GROUPS=("sudo" "wheel" "adm")

# shellcheck disable=SC1090
source "$CONFIG_PATH"

if ! [[ "$IDLE_THRESHOLD_MINUTES" =~ ^[0-9]+$ ]] || (( IDLE_THRESHOLD_MINUTES < 1 )); then
  echo "ERROR: IDLE_THRESHOLD_MINUTES must be >= 1." >&2
  exit 1
fi

if ! [[ "$MAX_TERMINATIONS_PER_SCAN" =~ ^[0-9]+$ ]] || (( MAX_TERMINATIONS_PER_SCAN < 1 )); then
  echo "ERROR: MAX_TERMINATIONS_PER_SCAN must be >= 1." >&2
  exit 1
fi

for cmd in w awk loginctl flock; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERROR: Required command '$cmd' is not installed." >&2
    exit 1
  fi
done

mkdir -p "$LOG_DIR"

# Enforce CSV retention cleanup
if [[ "$LOG_RETENTION_DAYS" =~ ^[0-9]+$ ]] && (( LOG_RETENTION_DAYS >= 1 )); then
  find "$LOG_DIR" -maxdepth 1 -type f -name "session-monitor-*.csv" -mtime +"$LOG_RETENTION_DAYS" -delete 2>/dev/null || true
fi

LOCK_FILE="/run/server-session-monitor.lock"
if [[ ! -w "/run" ]]; then
  LOCK_FILE="$LOG_DIR/server-session-monitor.lock"
fi

exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  echo "Another session-monitor scan is already running. Exiting cleanly."
  exit 0
fi

HOSTNAME_SHORT="$(hostname -s 2>/dev/null || hostname)"
LOG_PATH="$LOG_DIR/session-monitor-$(date +%Y%m%d).csv"

if [[ ! -f "$LOG_PATH" ]]; then
  echo "Timestamp,Hostname,OS,Username,SessionId,TTY,IdleText,IdleMinutes,Action,Detail,DryRun" > "$LOG_PATH"
fi

csv_escape() {
  local val="$1"
  val="${val//\"/\"\"}"
  printf '"%s"' "$val"
}

write_log_row() {
  local username="$1"
  local sid="$2"
  local tty="$3"
  local idle_text="$4"
  local idle_min="$5"
  local action="$6"
  local detail="$7"
  local ts
  ts="$(date --iso-8601=seconds)"

  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
    "$(csv_escape "$ts")" \
    "$(csv_escape "$HOSTNAME_SHORT")" \
    "$(csv_escape "Linux")" \
    "$(csv_escape "$username")" \
    "$(csv_escape "$sid")" \
    "$(csv_escape "$tty")" \
    "$(csv_escape "$idle_text")" \
    "$(csv_escape "$idle_min")" \
    "$(csv_escape "$action")" \
    "$(csv_escape "$detail")" \
    "$(csv_escape "$DRY_RUN")" >> "$LOG_PATH"

  if command -v logger >/dev/null 2>&1; then
    logger -t server-session-manager "host=$HOSTNAME_SHORT user=$username sid=$sid tty=$tty idle=$idle_text action=$action detail=$detail dry_run=$DRY_RUN" || true
  fi
}

is_protected_user() {
  local target="$1"
  local p
  for p in "${PROTECTED_USERS[@]}"; do
    if [[ "$target" == "$p" ]]; then
      return 0
    fi
  done
  return 1
}

matches_protected_pattern() {
  local target="$1"
  local pat
  for pat in "${PROTECTED_USER_PATTERNS[@]}"; do
    # shellcheck disable=SC2053
    if [[ -n "$pat" && "$target" == $pat ]]; then
      return 0
    fi
  done
  return 1
}

matched_protected_group() {
  local target="$1"
  local user_groups grp pg
  user_groups="$(id -Gn "$target" 2>/dev/null || true)"
  for grp in $user_groups; do
    for pg in "${PROTECTED_GROUPS[@]}"; do
      if [[ -n "$pg" && "$grp" == "$pg" ]]; then
        echo "$pg"
        return 0
      fi
    done
  done
  return 1
}

# Converts `w` idle column to integer minutes.
# Outputs empty string for unknown values (`old`, `?`, `-`) so they are skipped safely.
convert_w_idle_to_minutes() {
  local raw="$1"
  raw="${raw// /}"

  if [[ -z "$raw" || "$raw" == "old" || "$raw" == "?" || "$raw" == "-" ]]; then
    echo ""
    return 0
  fi

  if [[ "$raw" =~ ^[0-9]+(\.[0-9]+)?s$ ]]; then
    echo "0"
    return 0
  fi

  if [[ "$raw" =~ ^([0-9]+)days?$ ]]; then
    echo $(( BASH_REMATCH[1] * 1440 ))
    return 0
  fi

  if [[ "$raw" =~ ^([0-9]+):([0-9]{2})m$ ]]; then
    local h=$((10#${BASH_REMATCH[1]}))
    local m=$((10#${BASH_REMATCH[2]}))
    echo $(( h * 60 + m ))
    return 0
  fi

  if [[ "$raw" =~ ^([0-9]+):([0-9]{2})$ ]]; then
    local m=$((10#${BASH_REMATCH[1]}))
    echo "$m"
    return 0
  fi

  echo ""
}

find_matching_logind_session() {
  local target_user="$1"
  local target_tty="$2"
  local sid uid uname seat tty_col

  while read -r sid uid uname seat tty_col; do
    [[ -z "${sid:-}" ]] && continue
    [[ "$uname" != "$target_user" ]] && continue

    local s_tty s_remote s_service s_state s_class
    s_tty="$(loginctl show-session "$sid" -p TTY --value 2>/dev/null || true)"
    [[ "$s_tty" != "$target_tty" ]] && continue

    s_remote="$(loginctl show-session "$sid" -p Remote --value 2>/dev/null || echo "no")"
    [[ "$s_remote" != "yes" ]] && continue

    s_service="$(loginctl show-session "$sid" -p Service --value 2>/dev/null || true)"
    if [[ "$s_service" != sshd* ]]; then
      continue
    fi

    s_state="$(loginctl show-session "$sid" -p State --value 2>/dev/null || true)"
    [[ "$s_state" != "active" ]] && continue

    s_class="$(loginctl show-session "$sid" -p Class --value 2>/dev/null || true)"
    [[ "$s_class" != "user" ]] && continue

    echo "$sid"
    return 0
  done < <(loginctl list-sessions --no-legend 2>/dev/null)

  echo ""
}

actions=0

while read -r w_user w_tty w_from w_login w_idle w_rest; do
  [[ -z "${w_user:-}" || -z "${w_tty:-}" ]] && continue

  if [[ "$w_tty" != pts/* ]]; then
    continue
  fi

  # Resolve full username from TTY device ownership if `w` truncated the name
  if [[ "$w_user" == *+ && -e "/dev/$w_tty" ]]; then
    tty_owner="$(stat -c '%U' "/dev/$w_tty" 2>/dev/null || true)"
    if [[ -n "$tty_owner" && "$tty_owner" != "UNKNOWN" ]]; then
      w_user="$tty_owner"
    fi
  fi

  if is_protected_user "$w_user"; then
    write_log_row "$w_user" "-" "$w_tty" "${w_idle:-?}" "" "Skipped" "ProtectedUser"
    continue
  fi

  if matches_protected_pattern "$w_user"; then
    write_log_row "$w_user" "-" "$w_tty" "${w_idle:-?}" "" "Skipped" "ProtectedUserPattern"
    continue
  fi

  if grp_match="$(matched_protected_group "$w_user")"; then
    write_log_row "$w_user" "-" "$w_tty" "${w_idle:-?}" "" "Skipped" "ProtectedGroup:$grp_match"
    continue
  fi

  user_uid="$(id -u "$w_user" 2>/dev/null || echo "")"
  if [[ -n "$user_uid" && "$user_uid" =~ ^[0-9]+$ ]] && (( user_uid < 1000 )); then
    write_log_row "$w_user" "-" "$w_tty" "${w_idle:-?}" "" "Skipped" "SystemUidBelow1000"
    continue
  fi

  matched_sid="$(find_matching_logind_session "$w_user" "$w_tty")"
  if [[ -z "$matched_sid" ]]; then
    write_log_row "$w_user" "-" "$w_tty" "${w_idle:-?}" "" "Skipped" "NoMatchingRemoteSshdLogindSession"
    continue
  fi

  idle_minutes="$(convert_w_idle_to_minutes "${w_idle:-}")"
  if [[ -z "$idle_minutes" ]]; then
    write_log_row "$w_user" "$matched_sid" "$w_tty" "${w_idle:-?}" "" "Skipped" "UnknownIdleTimeSkipped"
    continue
  fi

  if (( idle_minutes < IDLE_THRESHOLD_MINUTES )); then
    write_log_row "$w_user" "$matched_sid" "$w_tty" "$w_idle" "$idle_minutes" "Skipped" "NotEligible"
    continue
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    write_log_row "$w_user" "$matched_sid" "$w_tty" "$w_idle" "$idle_minutes" "WouldLogoff" "DryRun:IdleThresholdReached"
    continue
  fi

  if (( actions >= MAX_TERMINATIONS_PER_SCAN )); then
    write_log_row "$w_user" "$matched_sid" "$w_tty" "$w_idle" "$idle_minutes" "Skipped" "MaxTerminationsPerScanReached"
    continue
  fi

  if loginctl terminate-session "$matched_sid" 2>/dev/null; then
    actions=$(( actions + 1 ))
    write_log_row "$w_user" "$matched_sid" "$w_tty" "$w_idle" "$idle_minutes" "LoggedOff" "IdleThresholdReached"
  else
    write_log_row "$w_user" "$matched_sid" "$w_tty" "$w_idle" "$idle_minutes" "Failed" "TerminateSessionFailed"
  fi
done < <(w -h 2>/dev/null || true)

echo "Scan complete. CSV: $LOG_PATH"
