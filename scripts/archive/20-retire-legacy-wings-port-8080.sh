#!/usr/bin/env bash
# Remove only the temporary UFW rules retained during the Wings 8080 -> 8443
# migration. The router rule is intentionally manual and must already use
# public/LAN TCP 8443 before running this cleanup.

set -Eeuo pipefail

EXECUTE=false
OLD_PORT=8080
NEW_PORT=8443
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
systemctl is-active --quiet wings || { printf 'Wings service is not active.\n' >&2; exit 1; }
ss -lnt "( sport = :$NEW_PORT )" | grep -q ":$NEW_PORT" || { printf 'Wings is not listening on TCP %s.\n' "$NEW_PORT" >&2; exit 1; }
if ss -lnt "( sport = :$OLD_PORT )" | grep -q ":$OLD_PORT"; then
  printf 'Refusing: a process is still listening on legacy TCP %s.\n' "$OLD_PORT" >&2
  exit 1
fi

api_status=$(curl --silent --show-error --connect-timeout 5 --max-time 10 \
  --resolve "$FQDN:$NEW_PORT:127.0.0.1" --output /dev/null --write-out '%{http_code}' \
  "https://$FQDN:$NEW_PORT/" || true)
[[ $api_status == 401 ]] || { printf 'Wings HTTPS API on %s returned HTTP %s, expected 401.\n' "$NEW_PORT" "$api_status" >&2; exit 1; }

mapfile -t rules < <(ufw status numbered | awk '
  /8080\/tcp/ && /Pelican Panel to local Wings|Pelican Wings client API/ {
    if (match($0, /\[[[:space:]]*[0-9]+[[:space:]]*\]/)) {
      rule = substr($0, RSTART, RLENGTH)
      gsub(/[^0-9]/, "", rule)
      if (rule ~ /^[0-9]+$/) print rule
    }
  }
')
[[ ${#rules[@]} -eq 2 && ${rules[0]} =~ ^[0-9]+$ && ${rules[1]} =~ ^[0-9]+$ ]] || {
  printf 'Expected exactly two legacy 8080 UFW rules, found %s; refusing to delete by number.\n' "${#rules[@]}" >&2
  exit 1
}

if ! $EXECUTE; then
  cat <<EOF
Dry run successful. The deployment will remove only UFW rules [${rules[*]}]:
  - private Panel-to-Wings TCP $OLD_PORT
  - public Wings client API TCP $OLD_PORT
TCP $NEW_PORT, game-port policy, SFTP, router configuration, and all other rules are unchanged.
Before executing, make sure the router has no remaining TCP $OLD_PORT Wings forward.
Run again with --execute to retire the legacy host firewall rules.
EOF
  exit 0
fi

# Rule numbers shift after deletion, so delete from highest to lowest.
while read -r rule; do
  ufw --force delete "$rule"
done < <(printf '%s\n' "${rules[@]}" | sort -rn)

ufw status numbered
printf 'Legacy TCP %s UFW rules removed.\n' "$OLD_PORT"
