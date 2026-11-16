#!/usr/bin/env bash
# Make the local Pelican Panel reach this first Wings node through the private
# Docker bridge while retaining the public FQDN for TLS/SNI validation.
#
# This is deliberately limited to node-01. Future physical nodes must retain
# their public/private routable addresses and do not need this local override.

set -Eeuo pipefail

EXECUTE=false
DEPLOY=/opt/selfhost/pelican
COMPOSE="$DEPLOY/compose.yml"
ENV_FILE="$DEPLOY/.env"
PANEL_CONTAINER=pelican-panel-1
NODE_FQDN=es1.kubo.csmak.com
PROXY_NETWORK=selfhost_proxy

usage() {
  sed -n '2,8p' "$0"
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
command -v docker >/dev/null || { printf 'Docker is required.\n' >&2; exit 1; }
[[ -r $COMPOSE && -r $ENV_FILE ]] || { printf 'Pelican compose files are missing.\n' >&2; exit 1; }
docker network inspect "$PROXY_NETWORK" >/dev/null || { printf 'Docker network %s is missing.\n' "$PROXY_NETWORK" >&2; exit 1; }
docker inspect "$PANEL_CONTAINER" >/dev/null || { printf 'Panel container %s is missing.\n' "$PANEL_CONTAINER" >&2; exit 1; }

gateway=$(docker network inspect "$PROXY_NETWORK" --format '{{(index .IPAM.Config 0).Gateway}}')
[[ $gateway =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || {
  printf 'Could not determine an IPv4 gateway for %s.\n' "$PROXY_NETWORK" >&2
  exit 1
}

if grep -qE '^[[:space:]]+extra_hosts:' "$COMPOSE"; then
  printf 'compose.yml already contains extra_hosts; refusing to alter it automatically.\n' >&2
  exit 1
fi

if ! $EXECUTE; then
  cat <<EOF
Dry run successful. The deployment will:
  - map $NODE_FQDN to local Docker gateway $gateway inside the Panel container
  - validate a staged Compose configuration
  - recreate only $PANEL_CONTAINER (brief Panel downtime)
It will not change Wings, Caddy, MariaDB, firewall rules, DNS, or public ports.
Run again with --execute to apply this local-only routing adjustment.
EOF
  exit 0
fi

stage=$(mktemp "$DEPLOY/.compose.yml.XXXXXX")
backup="$COMPOSE.before-local-node-resolution.$(date -u +%Y%m%dT%H%M%SZ)"
cleanup() { rm -f "$stage"; }
trap cleanup EXIT

# The first indented `volumes:` belongs to the panel service in the controlled
# deployment template. Inserting immediately before it keeps the entry scoped
# to that service rather than applying it to MariaDB.
awk -v fqdn="$NODE_FQDN" -v host_gateway="$gateway" '
  !inserted && /^    volumes:$/ {
    print "    extra_hosts:"
    print "      - \"" fqdn ":" host_gateway "\""
    inserted=1
  }
  { print }
  END { if (!inserted) exit 42 }
' "$COMPOSE" >"$stage" || {
  printf 'Could not locate the Panel volumes section in compose.yml. Nothing was changed.\n' >&2
  exit 1
}

docker compose --project-directory "$DEPLOY" --env-file "$ENV_FILE" -f "$stage" config -q
cp -a "$COMPOSE" "$backup"
install -o root -g root -m 0640 "$stage" "$COMPOSE"

if ! docker compose --project-directory "$DEPLOY" --env-file "$ENV_FILE" -f "$COMPOSE" up -d --force-recreate panel; then
  printf 'Panel recreation failed; restoring %s and attempting recovery.\n' "$backup" >&2
  cp -a "$backup" "$COMPOSE"
  docker compose --project-directory "$DEPLOY" --env-file "$ENV_FILE" -f "$COMPOSE" up -d --force-recreate panel || true
  exit 1
fi

printf 'Applied local resolution: %s -> %s inside %s.\n' "$NODE_FQDN" "$gateway" "$PANEL_CONTAINER"
printf 'Backup of the prior Compose file: %s\n' "$backup"
printf 'Next: verify it with the hostname from inside the Panel container.\n'
