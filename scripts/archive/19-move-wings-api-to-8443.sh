#!/usr/bin/env bash
# Move the first Wings node API from 8080 to 8443 after confirming that the
# home router/ISP permits 8443 but not 8080. This adjusts only the local host;
# the matching Panel node setting and router LAN port are deliberately manual.

set -Eeuo pipefail

EXECUTE=false
CONFIG=/etc/pelican/config.yml
OLD_PORT=8080
NEW_PORT=8443
PANEL_SUBNET=172.21.0.0/16
FQDN=node-01.yernau.com

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
command -v curl >/dev/null || { printf 'curl is required.\n' >&2; exit 1; }
[[ -r $CONFIG ]] || { printf 'Wings configuration is missing: %s\n' "$CONFIG" >&2; exit 1; }
systemctl is-active --quiet wings || { printf 'Wings service is not active.\n' >&2; exit 1; }
[[ $(grep -c "^  port: $OLD_PORT$" "$CONFIG") -eq 1 ]] || {
  printf 'Expected exactly one Wings API port %s in %s; refusing to edit.\n' "$OLD_PORT" "$CONFIG" >&2; exit 1;
}

if ! $EXECUTE; then
  cat <<EOF
Dry run successful. The deployment will:
  - change the local Wings API port from $OLD_PORT to $NEW_PORT
  - add only IPv4 UFW rules for Panel subnet $PANEL_SUBNET and authenticated clients on TCP $NEW_PORT
  - restart Wings and verify its local HTTPS API returns 401 on TCP $NEW_PORT
  - retain the existing TCP $OLD_PORT rules until the public migration is verified
It will not change the router, the Panel node settings, DNS, Caddy, game ports, or Docker networks.
Run again with --execute to make the local part of the migration.
EOF
  exit 0
fi

stage=$(mktemp "${CONFIG}.XXXXXX")
backup="${CONFIG}.before-api-port-$NEW_PORT.$(date -u +%Y%m%dT%H%M%SZ)"
cleanup() { rm -f "$stage"; }
trap cleanup EXIT

wait_for_listener() {
  local attempt
  for attempt in {1..15}; do
    if ss -lnt "( sport = :$NEW_PORT )" | grep -q ":$NEW_PORT"; then
      return 0
    fi
    sleep 1
  done
  return 1
}

sed "s/^  port: $OLD_PORT$/  port: $NEW_PORT/" "$CONFIG" >"$stage"
[[ $(grep -c "^  port: $NEW_PORT$" "$stage") -eq 1 ]] || {
  printf 'Staged Wings configuration does not contain the expected API port.\n' >&2; exit 1;
}

ufw allow from "$PANEL_SUBNET" to any port "$NEW_PORT" proto tcp comment 'Pelican Panel to local Wings'
ufw allow from 0.0.0.0/0 to any port "$NEW_PORT" proto tcp comment 'Pelican Wings client API'
cp -a "$CONFIG" "$backup"
install -o root -g root -m 0600 "$stage" "$CONFIG"

if ! systemctl restart wings; then
  printf 'Wings restart failed; restoring %s.\n' "$backup" >&2
  cp -a "$backup" "$CONFIG"
  systemctl restart wings || true
  exit 1
fi

if ! wait_for_listener; then
  printf 'Wings is not listening on TCP %s; restoring %s.\n' "$NEW_PORT" "$backup" >&2
  cp -a "$backup" "$CONFIG"
  systemctl restart wings || true
  exit 1
fi

status=$(curl --silent --show-error --connect-timeout 5 --max-time 10 \
  --resolve "$FQDN:$NEW_PORT:127.0.0.1" --output /dev/null --write-out '%{http_code}' \
  "https://$FQDN:$NEW_PORT/" || true)
[[ $status == 401 ]] || {
  printf 'Local HTTPS API returned HTTP %s rather than 401; restoring %s.\n' "$status" "$backup" >&2
  cp -a "$backup" "$CONFIG"
  systemctl restart wings || true
  exit 1
}

printf 'Local Wings API now listens on TCP %s and returned HTTP 401 as expected.\n' "$NEW_PORT"
printf 'Backup of the prior Wings configuration: %s\n' "$backup"
cat <<EOF
Complete the two remaining manual steps immediately:
  1. Panel Admin -> Nodes -> node-01 -> Settings: change the node port to $NEW_PORT and save.
     Do not replace /etc/pelican/config.yml with a newly generated config.
  2. Router rule Wings: keep public TCP $NEW_PORT, change LAN port from $OLD_PORT to $NEW_PORT.
Then test https://$FQDN:$NEW_PORT/ from mobile data; it must return 401.
Only after that verification should TCP $OLD_PORT be removed from UFW and the router.
EOF
