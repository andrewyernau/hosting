#!/usr/bin/env bash
# Add one explicit TCP/UDP allocation range to the persistent game ingress
# allowlist. The policy remains deny-by-default for every port outside it.

set -Eeuo pipefail

EXECUTE=false
PROTOCOL=tcp
RANGE=
LABEL=
ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
HELPER_SOURCE="$ROOT_DIR/firewall/pelican-game-firewall"
HELPER_TARGET=/usr/local/sbin/pelican-game-firewall
ALLOWLIST=/etc/pelican/firewall/allowed-game-ports.conf
SERVICE=pelican-game-firewall.service

usage() {
  printf 'Usage: sudo %s --range START-END --label LABEL [--protocol tcp|udp] [--execute]\n' "$0"
  exit 2
}

while (( $# )); do
  case "$1" in
    --range) RANGE=${2:?missing value}; shift 2 ;;
    --label) LABEL=${2:?missing value}; shift 2 ;;
    --protocol) PROTOCOL=${2:?missing value}; shift 2 ;;
    --execute) EXECUTE=true; shift ;;
    -h|--help) usage ;;
    *) printf 'Unknown argument: %s\n' "$1" >&2; usage ;;
  esac
done

[[ $EUID -eq 0 ]] || { printf 'Run this script with sudo/root.\n' >&2; exit 1; }
command -v iptables >/dev/null || { printf 'iptables is required.\n' >&2; exit 1; }
[[ $PROTOCOL == tcp || $PROTOCOL == udp ]] || { printf 'Protocol must be tcp or udp.\n' >&2; exit 1; }
[[ $RANGE =~ ^([0-9]+)-([0-9]+)$ ]] || { printf 'Range must use START-END, for example 25550-25580.\n' >&2; exit 1; }
range_start=${BASH_REMATCH[1]}
range_end=${BASH_REMATCH[2]}
[[ $range_start -ge 1 && $range_end -le 65535 && $range_start -le $range_end ]] || { printf 'Invalid port range: %s\n' "$RANGE" >&2; exit 1; }
[[ $LABEL =~ ^[a-zA-Z0-9._-]+$ ]] || { printf 'Label may contain only letters, digits, dot, underscore, and hyphen.\n' >&2; exit 1; }
[[ -r $ALLOWLIST && -r $HELPER_SOURCE ]] || { printf 'Game firewall files are missing.\n' >&2; exit 1; }
systemctl is-active --quiet "$SERVICE" || { printf '%s is not active.\n' "$SERVICE" >&2; exit 1; }

entry="$PROTOCOL $RANGE $LABEL"
if grep -qE "^$PROTOCOL[[:space:]]+$RANGE([[:space:]]|$)" "$ALLOWLIST"; then
  printf 'An allowlist entry for %s %s already exists; refusing to duplicate it.\n' "$PROTOCOL" "$RANGE" >&2
  exit 1
fi

if ! $EXECUTE; then
  cat <<EOF
Dry run successful. The deployment will:
  - add '$entry' to the root-owned game-port allowlist
  - update the firewall helper to support explicit ranges
  - reload only the PELICAN-GAME-INGRESS chain
Ports outside $RANGE remain blocked. It will not change UFW, router/NAT, DNS, Caddy, Wings, or existing game data.
Run again with --execute to allow this range through the Docker game bridge.
EOF
  exit 0
fi

stage=$(mktemp "${ALLOWLIST}.XXXXXX")
backup="${ALLOWLIST}.before-${PROTOCOL}-${RANGE}.$(date -u +%Y%m%dT%H%M%SZ)"
cleanup() { rm -f "$stage"; }
trap cleanup EXIT

cp "$ALLOWLIST" "$stage"
printf '%s\n' "$entry" >>"$stage"
cp -a "$ALLOWLIST" "$backup"
install -o root -g root -m 0640 "$stage" "$ALLOWLIST"
install -o root -g root -m 0750 "$HELPER_SOURCE" "$HELPER_TARGET"

if ! systemctl restart "$SERVICE"; then
  printf 'Firewall reload failed; restoring %s.\n' "$backup" >&2
  cp -a "$backup" "$ALLOWLIST"
  systemctl restart "$SERVICE" || true
  exit 1
fi

iptables -w -S PELICAN-GAME-INGRESS | grep -F -- "--ctorigdstport ${range_start}:${range_end}" >/dev/null || {
  printf 'Expected range rule was not installed; restoring %s.\n' "$backup" >&2
  cp -a "$backup" "$ALLOWLIST"
  systemctl restart "$SERVICE" || true
  exit 1
}

printf 'Allowed through the game bridge: %s.\n' "$entry"
printf 'Backup of the prior allowlist: %s\n' "$backup"
