#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

STATE_DIR='/var/lib/techsprint'
BOOTSTRAP_LOG='/var/log/techsprint-app-bootstrap.log'
install -d -m 0755 "$STATE_DIR"
touch "$BOOTSTRAP_LOG"
chmod 0644 "$BOOTSTRAP_LOG"
exec > >(tee -a "$BOOTSTRAP_LOG") 2>&1

CURRENT_STAGE='startup'

stage() {
  CURRENT_STAGE="$1"
  printf '%s\n' "$CURRENT_STAGE" >"$STATE_DIR/app-stage"
  printf '\n[%s] TechSprint app: %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$CURRENT_STAGE"
}

on_exit() {
  local exit_code=$?
  if [[ $exit_code -ne 0 ]]; then
    printf '%s (exit %s)\n' "$CURRENT_STAGE" "$exit_code" >"$STATE_DIR/app-error"
    printf '[%s] ERROR u fazi "%s" (exit %s)\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$CURRENT_STAGE" "$exit_code"
  fi
}
trap on_exit EXIT

rm -f "$STATE_DIR/app-ready" "$STATE_DIR/app-error"

APP_INDEX='__APP_INDEX__'
DEVELOPER_SLUG='__DEVELOPER_SLUG__'
MOODLE_WWWROOT='__MOODLE_WWWROOT__'
DB_PRIVATE_IP='__DB_PRIVATE_IP__'
DB_PASSWORD='__DB_PASSWORD__'
MOODLE_ADMIN_PASSWORD='__MOODLE_ADMIN_PASSWORD__'
LB_PRIVATE_IP='__LB_PRIVATE_IP__'
BLOB_STORAGE_NAME='__BLOB_STORAGE_NAME__'
FILE_STORAGE_NAME='__FILE_STORAGE_NAME__'
MANAGED_IDENTITY_CLIENT_ID='__MANAGED_IDENTITY_CLIENT_ID__'
DATA_DEVICE='/dev/disk/azure/scsi1/lun0'

retry() {
  local description="$1"
  shift
  local attempt
  for attempt in $(seq 1 12); do
    if "$@"; then
      return 0
    fi
    printf 'Pokusaj %s/12 nije uspio: %s\n' "$attempt" "$description"
    sleep 10
  done
  printf 'Odustajem nakon 12 pokusaja: %s\n' "$description"
  return 1
}

stage 'provjera mreze i instalacija paketa'
cat >/etc/apt/apt.conf.d/99techsprint-timeouts <<'EOF'
Acquire::http::Timeout "20";
Acquire::https::Timeout "20";
Acquire::Retries "3";
EOF

retry 'apt-get update' apt-get update
retry 'instalacija Moodle paketa' apt-get install -y apache2 git curl ca-certificates gnupg jq netcat-openbsd \
  mariadb-client xfsprogs cifs-utils fuse3 \
  php php-cli php-curl php-gd php-intl php-mbstring php-mysql php-soap \
  php-xml php-zip php-bcmath php-opcache

PHP_VERSION="$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')"
for php_sapi in cli apache2; do
  install -d -m 0755 "/etc/php/${PHP_VERSION}/${php_sapi}/conf.d"
  cat >"/etc/php/${PHP_VERSION}/${php_sapi}/conf.d/99-techsprint-moodle.ini" <<'EOF'
max_input_vars = 5000
memory_limit = 256M
post_max_size = 64M
upload_max_filesize = 64M
EOF
done

retry 'Microsoft package repozitorij' curl --connect-timeout 15 --max-time 60 \
  --retry 3 --retry-all-errors -fsSLo /tmp/packages-microsoft-prod.deb \
  https://packages.microsoft.com/config/ubuntu/24.04/packages-microsoft-prod.deb
dpkg -i /tmp/packages-microsoft-prod.deb
rm -f /tmp/packages-microsoft-prod.deb
retry 'apt-get update nakon Microsoft repozitorija' apt-get update
retry 'instalacija BlobFuse2 i azfilesauth' apt-get install -y blobfuse2 azfilesauth

stage 'priprema podatkovnog diska'
for attempt in $(seq 1 60); do
  if [[ -b "$DATA_DEVICE" ]]; then
    break
  fi
  sleep 5
done
[[ -b "$DATA_DEVICE" ]]

if ! blkid "$DATA_DEVICE" >/dev/null 2>&1; then
  mkfs.xfs -f "$DATA_DEVICE"
fi
install -d -m 0755 /srv/moodle
DATA_UUID="$(blkid -s UUID -o value "$DATA_DEVICE")"
grep -q "UUID=${DATA_UUID}" /etc/fstab || \
  echo "UUID=${DATA_UUID} /srv/moodle xfs defaults,nofail 0 2" >>/etc/fstab
mountpoint -q /srv/moodle || mount /srv/moodle

stage 'Blob Storage mount'
install -d -m 0755 /etc/blobfuse2 /mnt/moodleblob /srv/moodle/blobcache
grep -q '^user_allow_other$' /etc/fuse.conf 2>/dev/null || echo 'user_allow_other' >>/etc/fuse.conf

cat >/etc/blobfuse2/moodle.yaml <<EOF
logging:
  type: syslog
  level: LOG_WARNING

components:
  - libfuse
  - file_cache
  - attr_cache
  - azstorage

libfuse:
  allow-other: true

file_cache:
  path: /srv/moodle/blobcache
  timeout-sec: 120

attr_cache:
  timeout-sec: 3

azstorage:
  type: block
  account-name: ${BLOB_STORAGE_NAME}
  container: moodlefiles
  endpoint: https://${BLOB_STORAGE_NAME}.blob.core.windows.net
  mode: msi
  appid: ${MANAGED_IDENTITY_CLIENT_ID}
EOF
chmod 0600 /etc/blobfuse2/moodle.yaml

cat >/etc/systemd/system/moodleblob.service <<'EOF'
[Unit]
Description=TechSprint Moodle BlobFuse2 mount
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/blobfuse2 mount /mnt/moodleblob --foreground=true --config-file=/etc/blobfuse2/moodle.yaml -o allow_other -o uid=33 -o gid=33 -o umask=0007
ExecStop=/bin/fusermount3 -u /mnt/moodleblob
TimeoutStartSec=45
Restart=no

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable moodleblob.service
for attempt in $(seq 1 15); do
  if mountpoint -q /mnt/moodleblob; then
    break
  fi
  systemctl reset-failed moodleblob.service || true
  timeout 30 systemctl start moodleblob.service || true
  if mountpoint -q /mnt/moodleblob; then
    break
  fi
  if (( attempt % 6 == 0 )); then
    printf 'Blob mount jos nije spreman (%s/15).\n' "$attempt"
    journalctl -u moodleblob.service -n 20 --no-pager || true
  fi
  sleep 10
done
if ! mountpoint -q /mnt/moodleblob; then
  journalctl -u moodleblob.service -n 80 --no-pager || true
  exit 31
fi

install -d -m 0770 /mnt/moodleblob/moodledata

stage 'Azure Files autentikacija'
FILE_ENDPOINT="https://${FILE_STORAGE_NAME}.file.core.windows.net"
for attempt in $(seq 1 15); do
  if timeout 30 azfilesauthmanager set "$FILE_ENDPOINT" --imds-client-id "$MANAGED_IDENTITY_CLIENT_ID"; then
    break
  fi
  printf 'Azure Files credential jos nije spreman (%s/15).\n' "$attempt"
  sleep 10
done
azfilesauthmanager list
systemctl enable --now azfilesrefresh

AZFILES_UID="$(awk -F': *' '/^USER_UID:/{print $2}' /etc/azfilesauth/config.yaml | tr -d '[:space:]')"
if [[ -z "$AZFILES_UID" ]] && id azfilesuser >/dev/null 2>&1; then
  AZFILES_UID="$(id -u azfilesuser)"
fi
AZFILES_UID="${AZFILES_UID:-0}"

install -d -m 0770 -o www-data -g www-data /mnt/moodlebackup
MOUNT_OPTIONS="sec=krb5,cruid=${AZFILES_UID},username=${MANAGED_IDENTITY_CLIENT_ID},dir_mode=0770,file_mode=0660,uid=33,gid=33,serverino,nosharesock,mfsymlinks,actimeo=30,nofail,_netdev"
stage 'Azure Files mount'
if ! mountpoint -q /mnt/moodlebackup; then
  for attempt in $(seq 1 15); do
    if timeout 30 mount -t cifs "//${FILE_STORAGE_NAME}.file.core.windows.net/moodlebackup" /mnt/moodlebackup -o "$MOUNT_OPTIONS"; then
      break
    fi
    printf 'Azure Files mount jos nije spreman (%s/15).\n' "$attempt"
    sleep 10
  done
fi
mountpoint -q /mnt/moodlebackup

FSTAB_SOURCE="//${FILE_STORAGE_NAME}.file.core.windows.net/moodlebackup"
grep -qF "$FSTAB_SOURCE" /etc/fstab || \
  echo "$FSTAB_SOURCE /mnt/moodlebackup cifs ${MOUNT_OPTIONS},x-systemd.after=azfilesrefresh.service 0 0" >>/etc/fstab

stage 'preuzimanje i konfiguracija Moodlea'
clone_moodle() {
  rm -rf /srv/moodle/app
  timeout 240 git -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=30 \
    clone --depth 1 --branch MOODLE_500_STABLE https://github.com/moodle/moodle.git /srv/moodle/app
}
if [[ ! -d /srv/moodle/app/.git ]]; then
  retry 'git clone Moodle' clone_moodle
fi

cat >/srv/moodle/app/config.php <<EOF
<?php
unset(\$CFG);
global \$CFG;
\$CFG = new stdClass();
\$CFG->dbtype = 'mariadb';
\$CFG->dblibrary = 'native';
\$CFG->dbhost = '${DB_PRIVATE_IP}';
\$CFG->dbname = 'moodle';
\$CFG->dbuser = 'moodle';
\$CFG->dbpass = '${DB_PASSWORD}';
\$CFG->prefix = 'mdl_';
\$CFG->dboptions = [
  'dbpersist' => false,
  'dbport' => 3306,
  'dbsocket' => '',
  'dbcollation' => 'utf8mb4_unicode_ci',
];
\$CFG->wwwroot = '${MOODLE_WWWROOT}';
\$CFG->dataroot = '/mnt/moodleblob/moodledata';
\$CFG->admin = 'admin';
\$CFG->directorypermissions = 0770;
require_once(__DIR__ . '/lib/setup.php');
EOF

chown -R www-data:www-data /srv/moodle/app
find /srv/moodle/app -type d -exec chmod 0755 {} \;
find /srv/moodle/app -type f -exec chmod 0644 {} \;

cat >/etc/apache2/sites-available/moodle.conf <<'EOF'
<VirtualHost *:80>
    DocumentRoot /srv/moodle/app
    <Directory /srv/moodle/app>
        Options FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>
    ErrorLog ${APACHE_LOG_DIR}/moodle-error.log
    CustomLog ${APACHE_LOG_DIR}/moodle-access.log combined
</VirtualHost>
EOF
a2dissite 000-default
a2ensite moodle
a2enmod rewrite headers

cat >/srv/moodle/app/health.html <<EOF
healthy ${DEVELOPER_SLUG} app${APP_INDEX}
EOF
chown www-data:www-data /srv/moodle/app/health.html

stage 'provjera baze podataka'
for attempt in $(seq 1 120); do
  if nc -z "$DB_PRIVATE_IP" 3306; then
    break
  fi
  sleep 5
done
nc -z "$DB_PRIVATE_IP" 3306

if [[ "$APP_INDEX" == '0' ]]; then
  stage 'inicijalizacija Moodle baze'
  if ! mysql -h "$DB_PRIVATE_IP" -u moodle -p"$DB_PASSWORD" moodle -e 'SELECT 1 FROM mdl_config LIMIT 1' >/dev/null 2>&1; then
    sudo -u www-data php /srv/moodle/app/admin/cli/install_database.php \
      --agree-license \
      --adminuser=admin \
      --adminpass="$MOODLE_ADMIN_PASSWORD" \
      --adminemail="admin@${DEVELOPER_SLUG}.invalid" \
      --fullname="TechSprint ${DEVELOPER_SLUG}" \
      --shortname="TS-${DEVELOPER_SLUG}"
  fi
else
  stage 'cekam inicijalizaciju Moodle baze na app1'
  for attempt in $(seq 1 90); do
    if mysql -h "$DB_PRIVATE_IP" -u moodle -p"$DB_PASSWORD" moodle -e 'SELECT 1 FROM mdl_config LIMIT 1' >/dev/null 2>&1; then
      break
    fi
    sleep 10
  done
  mysql -h "$DB_PRIVATE_IP" -u moodle -p"$DB_PASSWORD" moodle -e 'SELECT 1 FROM mdl_config LIMIT 1' >/dev/null
fi

stage 'Apache i health provjera'
systemctl enable apache2
systemctl restart apache2
curl --fail --silent http://127.0.0.1/health.html >/dev/null

stage 'spremno'
printf '%s\n' "$DEVELOPER_SLUG" >"$STATE_DIR/environment"
printf '%s\n' "$APP_INDEX" >"$STATE_DIR/app-index"
printf '3\n' >"$STATE_DIR/app-bootstrap-version"
touch "$STATE_DIR/app-ready"
rm -f "$STATE_DIR/app-error"
trap - EXIT
