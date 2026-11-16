#!/usr/bin/env bash
# Permit the authenticated Wings HTTPS/WebSocket API for browser clients.
# Router/NAT configuration is intentionally left to the administrator because
# it is outside this host and must point at a stable LAN address.

set -Eeuo pipefail

EXECUTE=false
PORT=8080

usage() {
  sed -n '2,7p' "$0"
  printf 'Usage: sudo %s [--execute]\n' "$0"
  exit 2
}

while (( $# )); do
  case "$1" in
    --execute) EXECUTE=true; shift ;;
    -h|--help) usage ;;
    *) printf 'Unknown argument: %s\n' "$1" >&2; usage ;;
  esac
done

[[ $EUID -eq 0 ]] || { printf 'Run this script with sudo/root.\n' >&2; exit 1; }
command -v ufw >/dev/null || { printf 'UFW is required.\n' >&2; exit 1; }
systemctl is-active --quiet wings || { printf 'Wings service is not active.\n' >&2; exit 1; }
ss -lnt "( sport = :$PORT )" | grep -q ":$PORT" || { printf 'Wings is not listening on TCP %s.\n' "$PORT" >&2; exit 1; }

lan_ip=$(ip -4 route get 1.1.1.1 | awk '/src/ { for (i = 1; i <= NF; i++) if ($i == "src") { print $(i + 1); exit } }')
[[ $lan_ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || { printf 'Could not determine this host LAN IPv4 address.\n' >&2; exit 1; }

if ! $EXECUTE; then
  cat <<EOF
Dry run successful. The deployment will:
  - allow public IPv4 TCP $PORT through this host's UFW for the authenticated Wings API
  - leave TCP/UDP game allocations blocked by the separate pelican0 policy
  - leave SFTP TCP 2022 closed, and make no router, DNS, Caddy, or Cloudflare changes

Afterward, configure your router manually only after reserving this LAN address:
  WAN TCP $PORT -> $lan_ip TCP $PORT

Keep node-01.yernau.com DNS-only (grey cloud). This API must not use the normal Cloudflare proxy.
Run again with --execute to change only the local UFW rule.
EOF
  exit 0
fi

ufw allow from 0.0.0.0/0 to any port "$PORT" proto tcp comment 'Pelican Wings client API'
ufw status numbered
printf '%s\n' 'Host firewall updated. Router/NAT is still unchanged and must be configured separately.'
