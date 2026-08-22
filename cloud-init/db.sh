#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
DB_PASSWORD='__DB_PASSWORD__'
APP_SUBNET_CIDR='__APP_SUBNET_CIDR__'
DEVELOPER_SLUG='__DEVELOPER_SLUG__'
APP_HOST_PATTERN="${APP_SUBNET_CIDR%0/24}%"
DATA_DEVICE='/dev/disk/azure/scsi1/lun0'

retry() {
  local attempt
  for attempt in $(seq 1 12); do
    if "$@"; then
      return 0
    fi
    sleep $((attempt * 5))
  done
  return 1
}

retry apt-get update
retry apt-get install -y mariadb-server xfsprogs

for attempt in $(seq 1 60); do
  if [[ -b "$DATA_DEVICE" ]]; then
    break
  fi
  sleep 5
done
[[ -b "$DATA_DEVICE" ]]

systemctl stop mariadb || true

if ! blkid "$DATA_DEVICE" >/dev/null 2>&1; then
  mkfs.xfs -f "$DATA_DEVICE"
fi

if [[ ! -d /var/lib/mysql.bootstrap ]]; then
  mv /var/lib/mysql /var/lib/mysql.bootstrap
fi
install -d -m 0750 -o mysql -g mysql /var/lib/mysql
DATA_UUID="$(blkid -s UUID -o value "$DATA_DEVICE")"
grep -q "UUID=${DATA_UUID}" /etc/fstab || \
  echo "UUID=${DATA_UUID} /var/lib/mysql xfs defaults,nofail 0 2" >>/etc/fstab
mountpoint -q /var/lib/mysql || mount /var/lib/mysql

if [[ -z "$(find /var/lib/mysql -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
  cp -a /var/lib/mysql.bootstrap/. /var/lib/mysql/
fi
chown -R mysql:mysql /var/lib/mysql

cat >/etc/mysql/mariadb.conf.d/60-techsprint.cnf <<'EOF'
[mysqld]
bind-address = 0.0.0.0
character-set-server = utf8mb4
collation-server = utf8mb4_unicode_ci
innodb_file_per_table = 1
max_allowed_packet = 64M
EOF

systemctl enable --now mariadb

mysql <<SQL
CREATE DATABASE IF NOT EXISTS moodle DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS 'moodle'@'${APP_HOST_PATTERN}' IDENTIFIED BY '${DB_PASSWORD}';
ALTER USER 'moodle'@'${APP_HOST_PATTERN}' IDENTIFIED BY '${DB_PASSWORD}';
GRANT ALL PRIVILEGES ON moodle.* TO 'moodle'@'${APP_HOST_PATTERN}';
FLUSH PRIVILEGES;
SQL

install -d -m 0755 /var/lib/techsprint
printf '%s\n' "$DEVELOPER_SLUG" >/var/lib/techsprint/environment
printf '2\n' >/var/lib/techsprint/db-bootstrap-version
touch /var/lib/techsprint/db-ready
