#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

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
retry apt-get install -y curl jq netcat-openbsd mariadb-client traceroute

install -d -m 0755 /var/lib/techsprint
cat >/etc/motd <<'EOF'
TechSprint DevOps Lead VM

Ovaj VM nema javni IP. Pristup je moguc samo preko Jump Hosta.
Iz ovog VM-a dopusten je SSH prema privatnim adresama svih developer okolina.
EOF
printf '2\n' >/var/lib/techsprint/lead-bootstrap-version
touch /var/lib/techsprint/lead-ready
