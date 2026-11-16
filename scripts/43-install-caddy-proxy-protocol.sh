#!/usr/bin/env bash
# Install caddy/Caddyfile (PROXY protocol from edge-tunnel) into the central Caddy.
# The Caddyfile is a single-file bind mount, so it is rewritten in place (same inode).
# Validates and reloads; restores the previous file on any failure.
set -Eeuo pipefail
cd "$(dirname "$0")/.."
SRC=$PWD/caddy/Caddyfile
DEST_DIR=/opt/selfhost/caddy
CADDY=caddy-caddy-1
STAMP=$(date -u +%Y%m%dT%H%M%SZ)

op() {
  docker run --rm --network none --cap-drop ALL --cap-add DAC_OVERRIDE --security-opt no-new-privileges:true \
    --mount "type=bind,src=$DEST_DIR,dst=/caddy" --mount "type=bind,src=$SRC,dst=/new,readonly" \
    alpine:3.22 sh -euc '
      case "$1" in
        install) cp -p /caddy/Caddyfile "/caddy/Caddyfile.rollback-$2"; cat /new > /caddy/Caddyfile ;;
        restore) cat "/caddy/Caddyfile.rollback-$2" > /caddy/Caddyfile ;;
      esac' sh "$1" "$STAMP"
}

op install
if ! docker exec "$CADDY" caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null 2>&1 \
  || ! docker exec "$CADDY" caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile; then
  op restore
  docker exec "$CADDY" caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile || true
  printf 'Caddy rejected the new Caddyfile; previous one restored (backup %s).\n' "Caddyfile.rollback-$STAMP" >&2
  exit 1
fi
printf 'Caddyfile installed (backup %s/Caddyfile.rollback-%s).\n' "$DEST_DIR" "$STAMP"
