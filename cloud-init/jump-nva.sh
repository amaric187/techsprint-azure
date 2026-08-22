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
retry apt-get install -y iptables-persistent jq curl

cat >/etc/sysctl.d/99-techsprint-router.conf <<'EOF'
net.ipv4.ip_forward=1
net.ipv4.conf.all.send_redirects=0
net.ipv4.conf.default.send_redirects=0
EOF
sysctl --system

WAN_INTERFACE="$(ip -4 route show default | awk 'NR==1 {print $5}')"
[[ -n "$WAN_INTERFACE" ]]

SPOKE_PREFIXES=('__SPOKE_PREFIX_1__' '__SPOKE_PREFIX_2__')

iptables -t nat -N TECHSPRINT-NAT 2>/dev/null || true
iptables -t nat -F TECHSPRINT-NAT
iptables -t nat -C POSTROUTING -j TECHSPRINT-NAT 2>/dev/null || \
  iptables -t nat -I POSTROUTING 1 -j TECHSPRINT-NAT
iptables -t nat -A TECHSPRINT-NAT -s 10.0.1.0/24 -o "$WAN_INTERFACE" -j MASQUERADE
for prefix in "${SPOKE_PREFIXES[@]}"; do
  iptables -t nat -A TECHSPRINT-NAT -s "$prefix" -o "$WAN_INTERFACE" -j MASQUERADE
done

iptables -N TECHSPRINT-FWD 2>/dev/null || true
iptables -F TECHSPRINT-FWD
iptables -C FORWARD -j TECHSPRINT-FWD 2>/dev/null || iptables -I FORWARD 1 -j TECHSPRINT-FWD

iptables -A TECHSPRINT-FWD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# Lead VM smije prema Internetu i svim developer okolinama.
iptables -A TECHSPRINT-FWD -s 10.0.1.0/24 -j ACCEPT

# Developer traffic may reach the Internet, but may not be routed to any private network.
for prefix in "${SPOKE_PREFIXES[@]}"; do
  iptables -A TECHSPRINT-FWD -s "$prefix" -d 10.0.0.0/8 -j DROP
  iptables -A TECHSPRINT-FWD -s "$prefix" -d 172.16.0.0/12 -j DROP
  iptables -A TECHSPRINT-FWD -s "$prefix" -d 192.168.0.0/16 -j DROP
  iptables -A TECHSPRINT-FWD -s "$prefix" -o "$WAN_INTERFACE" -j ACCEPT
done
iptables -A TECHSPRINT-FWD -j DROP

netfilter-persistent save

install -d -m 0755 /var/lib/techsprint
printf '2\n' >/var/lib/techsprint/nva-config-version
touch /var/lib/techsprint/nva-ready
