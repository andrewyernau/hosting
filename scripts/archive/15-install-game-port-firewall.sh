#!/usr/bin/env bash
# Install a persistent, deny-by-default ingress policy for Wings game ports.
# It intentionally starts with an empty allowlist: creating an allocation alone
# must not expose it until the administrator explicitly permits that port.

set -Eeuo pipefail

EXECUTE=false
ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SOURCE_DIR="$ROOT_DIR/firewall"
TARGET_DIR=/etc/pelican/firewall
UNIT=pelican-game-firewall.service
WINGS_DROPIN=/etc/systemd/system/wings.service.d/20-game-firewall.conf

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
command -v iptables >/dev/null || { printf 'iptables is required.\n' >&2; exit 1; }
[[ -r $SOURCE_DIR/pelican-game-firewall && -r $SOURCE_DIR/$UNIT && -r $SOURCE_DIR/allowed-game-ports.conf && -r $SOURCE_DIR/wings-game-firewall.conf ]] || {
  printf 'Required firewall templates are missing in %s.\n' "$SOURCE_DIR" >&2; exit 1;
}
docker network inspect pelican_nw >/dev/null || { printf 'Wings network pelican_nw is missing.\n' >&2; exit 1; }
container_count=$(docker network inspect pelican_nw --format '{{len .Containers}}')
[[ $container_count == 0 ]] || { printf 'Refusing: pelican_nw has attached containers.\n' >&2; exit 1; }
systemctl is-active --quiet wings || { printf 'Wings service is not active.\n' >&2; exit 1; }

if ! $EXECUTE; then
  cat <<EOF
Dry run successful. The deployment will:
  - install an empty, root-owned game-port allowlist at $TARGET_DIR
  - install a persistent DOCKER-USER policy scoped only to bridge pelican0
  - require that policy before Wings starts after future Docker restarts
  - keep all public game allocations blocked until individually allowlisted
It will not change UFW, DNS, Caddy, Panel data, MariaDB, or existing Docker networks.
Run again with --execute to install the deny-by-default game-port policy.
EOF
  exit 0
fi

install -d -o root -g root -m 0750 "$TARGET_DIR" /etc/systemd/system/wings.service.d
install -o root -g root -m 0750 "$SOURCE_DIR/pelican-game-firewall" /usr/local/sbin/pelican-game-firewall
install -o root -g root -m 0644 "$SOURCE_DIR/$UNIT" "/etc/systemd/system/$UNIT"
install -o root -g root -m 0644 "$SOURCE_DIR/wings-game-firewall.conf" "$WINGS_DROPIN"

if [[ ! -e $TARGET_DIR/allowed-game-ports.conf ]]; then
  install -o root -g root -m 0640 "$SOURCE_DIR/allowed-game-ports.conf" "$TARGET_DIR/allowed-game-ports.conf"
fi

systemctl daemon-reload
systemctl enable "$UNIT"
systemctl restart "$UNIT"
systemctl restart wings

printf '%s\n' 'Game-port firewall installed. The allowlist is intentionally empty.'
iptables -w -S PELICAN-GAME-INGRESS
printf '%s\n' 'Next: add an allocation and then explicitly allow only its required TCP/UDP ports.'
