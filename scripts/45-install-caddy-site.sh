#!/usr/bin/env bash
# Install one site file into the central Caddy, validate and reload; restore on failure.
# Usage: 45-install-caddy-site.sh <source-file> <installed-name.caddy>
set -Eeuo pipefail
[[ $# -eq 2 ]] || { printf 'Usage: %s <source-file> <name.caddy>\n' "$0" >&2; exit 2; }
SRC=$(realpath "$1"); NAME=$2
[[ -f $SRC ]] || { printf 'Missing %s\n' "$SRC" >&2; exit 1; }
[[ $NAME =~ ^[a-z0-9.-]+\.caddy$ ]] || { printf 'Invalid site file name.\n' >&2; exit 2; }
CADDY=caddy-caddy-1
STAMP=$(date -u +%Y%m%dT%H%M%SZ)

op() {
  docker run --rm --network none --cap-drop ALL --cap-add DAC_OVERRIDE --security-opt no-new-privileges:true \
    --mount "type=bind,src=/opt/selfhost/caddy,dst=/caddy" --mount "type=bind,src=$SRC,dst=/new,readonly" \
    alpine:3.22 sh -euc '
      site=/caddy/sites/$2; bk=/caddy/sites-rollback/$2.$3
      case "$1" in
        install) mkdir -p /caddy/sites-rollback; if [ -f "$site" ]; then cp -p "$site" "$bk"; fi
                 cat /new > "$site"; chmod 644 "$site" ;;
        restore) if [ -f "$bk" ]; then cat "$bk" > "$site"; else rm -f "$site"; fi ;;
      esac' sh "$1" "$NAME" "$STAMP"
}

op install
if ! docker exec "$CADDY" caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null 2>&1 \
  || ! docker exec "$CADDY" caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile 2>/dev/null; then
  op restore; docker exec "$CADDY" caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile || true
  printf 'Caddy rejected %s; previous version restored.\n' "$NAME" >&2; exit 1
fi
printf 'Installed %s (rollback: /opt/selfhost/caddy/sites-rollback/%s.%s)\n' "$NAME" "$NAME" "$STAMP"
