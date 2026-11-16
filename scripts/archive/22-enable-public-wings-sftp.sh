#!/usr/bin/env bash
# Permit Pelican's authenticated SFTP service for client file transfers.
# This exposes only the Wings SFTP protocol, not host SSH or an SSH shell.

set -Eeuo pipefail

EXECUTE=false
PORT=2022

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

if ! $EXECUTE; then
  cat <<EOF
Dry run successful. The deployment will:
  - allow public IPv4 TCP $PORT through UFW for Pelican's authenticated SFTP service
  - leave host SSH on TCP 22 unchanged
  - leave game-port policy, Caddy, Panel, DNS, and router/NAT unchanged

Afterward, configure the router manually:
  WAN TCP $PORT -> 192.168.0.111 TCP $PORT
Run again with --execute to change only this host UFW rule.
EOF
  exit 0
fi

ufw allow from 0.0.0.0/0 to any port "$PORT" proto tcp comment 'Pelican Wings SFTP'
ufw status numbered
printf '%s\n' 'Host firewall updated. Router/NAT remains unchanged.'
