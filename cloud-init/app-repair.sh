#!/usr/bin/env bash
set -euo pipefail

STATE_DIR='/var/lib/techsprint'
WORKER='/usr/local/sbin/techsprint-app-bootstrap-worker'
FIXED_SCRIPT='/usr/local/sbin/techsprint-app-bootstrap-fixed'
REPAIR_UNIT='techsprint-app-bootstrap-repair.service'

if [[ -f "$STATE_DIR/app-ready" ]] && grep -qx 3 "$STATE_DIR/app-bootstrap-version" 2>/dev/null; then
  echo 'ALREADY_READY'
  exit 0
fi

if [[ ! -f "$WORKER" ]]; then
  echo "Nedostaje $WORKER" >&2
  exit 41
fi

embedded_app_b64="$(sed -n "s/^printf '%s' '\([^']*\)' | base64 -d | bash$/\1/p" "$WORKER" | head -n 1)"
if [[ -z "$embedded_app_b64" ]]; then
  echo 'Nije moguce procitati ugradenu app skriptu iz workera.' >&2
  exit 42
fi

printf '%s' "$embedded_app_b64" |
  base64 -d |
  sed \
    -e 's/^Type=forking$/Type=simple/' \
    -e 's|^  endpoint: blob\.core\.windows\.net$|  endpoint: https://${BLOB_STORAGE_NAME}.blob.core.windows.net|' \
    -e 's|^ExecStart=/usr/bin/blobfuse2 mount /mnt/moodleblob --config-file=|ExecStart=/usr/bin/blobfuse2 mount /mnt/moodleblob --foreground=true --config-file=|' \
    -e "s|^systemctl enable --now apache2$|stage 'Apache i health provjera'\\nsystemctl enable apache2\\nsystemctl restart apache2|" \
    >"$FIXED_SCRIPT"
chmod 0755 "$FIXED_SCRIPT"
bash -n "$FIXED_SCRIPT"

# Moodle 5 na PHP-u 8 zahtijeva najmanje 5000 ulaznih varijabli. PHP je vec
# instaliran na VM-ovima koje ova recovery skripta popravlja.
if command -v php >/dev/null 2>&1; then
  php_version="$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')"
  for php_sapi in cli apache2; do
    install -d -m 0755 "/etc/php/${php_version}/${php_sapi}/conf.d"
    cat >"/etc/php/${php_version}/${php_sapi}/conf.d/99-techsprint-moodle.ini" <<'EOF'
max_input_vars = 5000
memory_limit = 256M
post_max_size = 64M
upload_max_filesize = 64M
EOF
  done
fi

if [[ -f "$STATE_DIR/app-bootstrap-worker.pid" ]]; then
  legacy_pid="$(cat "$STATE_DIR/app-bootstrap-worker.pid" 2>/dev/null || true)"
  if [[ "$legacy_pid" =~ ^[0-9]+$ ]] && kill -0 "$legacy_pid" 2>/dev/null; then
    kill "$legacy_pid" || true
    sleep 2
  fi
fi
rm -f "$STATE_DIR/app-bootstrap-worker.pid" "$STATE_DIR/app-error" "$STATE_DIR/app-ready"

systemctl stop moodleblob.service 2>/dev/null || true
if mountpoint -q /mnt/moodleblob; then
  fusermount3 -u /mnt/moodleblob || true
fi
systemctl stop "$REPAIR_UNIT" 2>/dev/null || true
systemctl reset-failed "$REPAIR_UNIT" 2>/dev/null || true

systemd-run --unit=techsprint-app-bootstrap-repair --collect "$FIXED_SCRIPT" >/dev/null
echo 'REPAIR_STARTED'
