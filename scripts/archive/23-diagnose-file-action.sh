#!/usr/bin/env bash
# Read-only diagnostics for failed Panel file actions such as Unarchive.
# It gathers only recent service/application errors and validates the existing
# private Panel -> Wings API route on the final 8443 port.

set -Eeuo pipefail

PANEL_CONTAINER=pelican-panel-1
FQDN=node-01.yernau.com
PORT=8443

[[ $EUID -eq 0 ]] || { printf 'Run this script with sudo/root.\n' >&2; exit 1; }
command -v docker >/dev/null || { printf 'Docker is required.\n' >&2; exit 1; }
docker inspect "$PANEL_CONTAINER" >/dev/null || { printf 'Panel container %s is missing.\n' "$PANEL_CONTAINER" >&2; exit 1; }

printf '%s\n' '===== Service state ====='
systemctl --no-pager --full status wings | sed -n '1,22p'
docker ps --filter name='pelican-panel-1' --filter name='pelican-database-1' --format 'table {{.Names}}\t{{.Status}}'

printf '%s\n' '===== Panel to Wings private route ====='
if output=$(docker exec "$PANEL_CONTAINER" sh -c "wget -S -O /dev/null https://$FQDN:$PORT/" 2>&1); then
  printf '%s\n' "$output"
else
  printf '%s\n' "$output"
fi

printf '%s\n' '===== Recent Panel application errors ====='
docker exec "$PANEL_CONTAINER" sh -c '
  for file in /var/www/html/storage/logs/*.log; do
    [ -f "$file" ] || continue
    tail -n 120 "$file"
  done
' | grep -Ei 'error|exception|unarchive|archive|zip|failed|permission|denied' || true

printf '%s\n' '===== Recent Wings errors ====='
journalctl -u wings --since '20 minutes ago' --no-pager | grep -Ei 'error|failed|archive|unarchive|zip|permission|denied' || true

printf '%s\n' 'Diagnostics finished. No file, server, firewall, configuration, or service was changed.'
