#!/usr/bin/env bash
# Read-only diagnostics for the path Internet -> router -> local Wings API.
# It intentionally reports only whether public IPs match, not the IP values.

set -Eeuo pipefail

FQDN=node-01.yernau.com
PORT=8080

[[ $EUID -eq 0 ]] || { printf 'Run this script with sudo/root.\n' >&2; exit 1; }
command -v curl >/dev/null || { printf 'curl is required.\n' >&2; exit 1; }
command -v getent >/dev/null || { printf 'getent is required.\n' >&2; exit 1; }

printf '%s\n' '===== Local Wings listener and firewall ====='
systemctl is-active --quiet wings && printf '%s\n' 'Wings service: active' || printf '%s\n' 'Wings service: NOT active'
ss -lnt "( sport = :$PORT )" | grep -q ":$PORT" && printf 'TCP %s listener: present\n' "$PORT" || printf 'TCP %s listener: NOT present\n' "$PORT"
if ufw status | awk -v port="$PORT/tcp" '$1 == port && $2 == "ALLOW" && $3 == "IN" && $4 == "Anywhere" { found = 1 } END { exit !found }'; then
  printf '%s\n' 'Public IPv4 UFW rule: present'
else
  printf '%s\n' 'Public IPv4 UFW rule: NOT found'
fi

printf '%s\n' '===== Local HTTPS API check ====='
local_status=$(curl --silent --show-error --connect-timeout 5 --max-time 10 \
  --resolve "$FQDN:$PORT:127.0.0.1" --output /dev/null --write-out '%{http_code}' \
  "https://$FQDN:$PORT/" || true)
printf 'Local TLS API response: HTTP %s (401 is expected without credentials)\n' "$local_status"

printf '%s\n' '===== Public IPv4 and DNS consistency ====='
dns_ip=$(getent ahostsv4 "$FQDN" | awk 'NR == 1 { print $1 }')
egress_ip=$(curl --silent --show-error --ipv4 --connect-timeout 5 --max-time 10 https://api.ipify.org || true)
if [[ $dns_ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ && $egress_ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
  if [[ $dns_ip == "$egress_ip" ]]; then
    printf '%s\n' 'DNS A record matches this connection public IPv4: yes'
  else
    printf '%s\n' 'DNS A record matches this connection public IPv4: NO'
  fi
else
  printf '%s\n' 'Could not determine both the DNS A record and the connection public IPv4.'
fi

printf '%s\n' '===== Router checks to perform manually ====='
cat <<'EOF'
1. Its WAN/Internet IPv4 must be public and match the connection public IPv4 above.
2. It must not be in 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, or 100.64.0.0/10.
   Any of those means double NAT or CGNAT; a local port-forward cannot work alone.
3. The enabled rule must be TCP only: WAN 8080 -> 192.168.0.111, LAN port 8080.
4. The target host must retain its DHCP reservation for 192.168.0.111.
EOF

printf '%s\n' 'Diagnostics finished. No firewall, router, DNS, or service was changed.'
