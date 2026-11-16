#!/usr/bin/env bash
# Disable Docker inter-container communication on the dedicated Wings bridge.
# Run this only before the first game server is created, or after moving every
# game container off the bridge. Wings itself continues to manage containers
# through the Docker API; this blocks direct game-server-to-game-server traffic.

set -Eeuo pipefail

EXECUTE=false
CONFIG=/etc/pelican/config.yml
NETWORK=pelican_nw
SERVICE=wings

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
command -v docker >/dev/null || { printf 'Docker is required.\n' >&2; exit 1; }
[[ -r $CONFIG ]] || { printf 'Wings configuration is missing: %s\n' "$CONFIG" >&2; exit 1; }
docker network inspect "$NETWORK" >/dev/null || { printf 'Wings network %s is missing.\n' "$NETWORK" >&2; exit 1; }
systemctl is-active --quiet "$SERVICE" || { printf 'Wings service is not active; stop and investigate before changing its network.\n' >&2; exit 1; }

container_count=$(docker network inspect "$NETWORK" --format '{{len .Containers}}')
[[ $container_count =~ ^[0-9]+$ ]] || { printf 'Could not count containers attached to %s.\n' "$NETWORK" >&2; exit 1; }
[[ $container_count -eq 0 ]] || {
  printf 'Refusing: %s has %s attached container(s). Migrate/stop them first.\n' "$NETWORK" "$container_count" >&2
  exit 1
}

[[ $(grep -c '^    enable_icc: true$' "$CONFIG") -eq 1 ]] || {
  printf 'Expected exactly one enabled Docker ICC setting in %s; refusing to edit.\n' "$CONFIG" >&2
  exit 1
}

if ! $EXECUTE; then
  cat <<EOF
Dry run successful. The deployment will:
  - change only Docker network enable_icc from true to false in $CONFIG
  - stop Wings briefly, remove its empty $NETWORK bridge, and start Wings again
  - verify that Docker recreated the bridge with inter-container traffic disabled
It will not change game data, Caddy, the Panel, MariaDB, firewall rules, DNS, or public ports.
Run again with --execute to apply this isolation control.
EOF
  exit 0
fi

stage=$(mktemp "${CONFIG}.XXXXXX")
backup="${CONFIG}.before-disable-icc.$(date -u +%Y%m%dT%H%M%SZ)"
cleanup() { rm -f "$stage"; }
trap cleanup EXIT

wait_for_network() {
  local attempt
  for attempt in {1..15}; do
    if docker network inspect "$NETWORK" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  return 1
}

sed 's/^    enable_icc: true$/    enable_icc: false/' "$CONFIG" >"$stage"
[[ $(grep -c '^    enable_icc: false$' "$stage") -eq 1 ]] || {
  printf 'Staged configuration did not contain the expected ICC setting.\n' >&2
  exit 1
}

systemctl stop "$SERVICE"
if ! docker network rm "$NETWORK"; then
  printf 'Could not remove the empty Wings bridge. Restoring service without configuration changes.\n' >&2
  systemctl start "$SERVICE" || true
  exit 1
fi

cp -a "$CONFIG" "$backup"
install -o root -g root -m 0600 "$stage" "$CONFIG"

if ! systemctl start "$SERVICE" || ! wait_for_network; then
  printf 'Wings did not start with the staged configuration; restoring %s.\n' "$backup" >&2
  systemctl stop "$SERVICE" || true
  cp -a "$backup" "$CONFIG"
  systemctl start "$SERVICE" || true
  exit 1
fi

icc=$(docker network inspect "$NETWORK" --format '{{index .Options "com.docker.network.bridge.enable_icc"}}')
if [[ $icc != false ]]; then
  printf 'Unexpected ICC value after recreation: %s. Restoring the prior configuration.\n' "${icc:-<unset>}" >&2
  systemctl stop "$SERVICE" || true
  docker network rm "$NETWORK" || true
  cp -a "$backup" "$CONFIG"
  systemctl start "$SERVICE" || true
  exit 1
fi

printf 'Wings network isolation enabled: %s has com.docker.network.bridge.enable_icc=false.\n' "$NETWORK"
printf 'Backup of the prior Wings configuration: %s\n' "$backup"
