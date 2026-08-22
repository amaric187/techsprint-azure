#!/usr/bin/env bash
set -euo pipefail

STATE_DIR='/var/lib/techsprint'
PID_FILE="$STATE_DIR/app-bootstrap-worker.pid"
RUNNER='/usr/local/sbin/techsprint-app-bootstrap-worker'

install -d -m 0755 "$STATE_DIR"

if [[ -f "$STATE_DIR/app-ready" ]] && grep -qx 3 "$STATE_DIR/app-bootstrap-version" 2>/dev/null; then
  exit 0
fi

if [[ -f "$PID_FILE" ]]; then
  existing_pid="$(cat "$PID_FILE" 2>/dev/null || true)"
  if [[ "$existing_pid" =~ ^[0-9]+$ ]] && kill -0 "$existing_pid" 2>/dev/null; then
    exit 0
  fi
fi

cat >"$RUNNER" <<'RUNNER'
#!/usr/bin/env bash
set -euo pipefail

STATE_DIR='/var/lib/techsprint'
PID_FILE="$STATE_DIR/app-bootstrap-worker.pid"
trap 'rm -f "$PID_FILE"' EXIT

cloud-init status --wait || true

if [[ -f "$STATE_DIR/app-ready" ]] && grep -qx 3 "$STATE_DIR/app-bootstrap-version" 2>/dev/null; then
  exit 0
fi

printf '%s' '__APP_SCRIPT_B64__' | base64 -d | bash
RUNNER

chmod 0755 "$RUNNER"
nohup "$RUNNER" </dev/null >>/var/log/techsprint-app-worker.log 2>&1 &
printf '%s\n' "$!" >"$PID_FILE"

exit 0
