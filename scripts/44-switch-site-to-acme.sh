#!/usr/bin/env bash
# Drop the Cloudflare Origin `tls <cert> <key>` line from an installed Caddy site so
# Caddy issues a Let's Encrypt certificate (DNS-01) for it, then wait for issuance.
# Every site sharing a wildcard Origin certificate must switch together: while any
# site still loads it, Caddy skips ACME for all names the wildcard covers.
# Usage: 44-switch-site-to-acme.sh <a.caddy[,b.caddy...]> <hostname> [hostname...]
set -Eeuo pipefail
[[ $# -ge 2 ]] || { printf 'Usage: %s <a.caddy[,b.caddy]> <host>...\n' "$0" >&2; exit 2; }
SITES=$1; shift
[[ $SITES =~ ^[a-z0-9.-]+\.caddy(,[a-z0-9.-]+\.caddy)*$ ]] || { printf 'Invalid site file list.\n' >&2; exit 2; }
SITES_DIR=/opt/selfhost/caddy/sites
CADDY=caddy-caddy-1
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
BACKUP_DIR=/opt/selfhost/caddy/sites-rollback

op() {
  docker run --rm --network none --cap-drop ALL --cap-add DAC_OVERRIDE --security-opt no-new-privileges:true \
    --mount "type=bind,src=/opt/selfhost/caddy,dst=/caddy" alpine:3.22 sh -euc '
      mkdir -p /caddy/sites-rollback
      for name in $(echo "$2" | tr , " "); do
        site=/caddy/sites/$name; bk=/caddy/sites-rollback/$name.$3
        case "$1" in
          switch) cp -p "$site" "$bk"
                  sed "/^[[:space:]]*tls \/etc\/caddy\/certs\//d" "$site" > /tmp/new; cat /tmp/new > "$site" ;;
          restore) cat "$bk" > "$site" ;;
        esac
      done' sh "$1" "$SITES" "$STAMP"
}

op switch
if ! docker exec "$CADDY" caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null 2>&1 \
  || ! docker exec "$CADDY" caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile 2>/dev/null; then
  op restore; docker exec "$CADDY" caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile || true
  printf 'Caddy rejected the change; %s restored.\n' "$SITES" >&2; exit 1
fi

for host in "$@"; do
  for _ in $(seq 1 36); do
    issuer=$(echo | timeout 5 openssl s_client -connect 192.168.0.111:443 -servername "$host" 2>/dev/null \
      | openssl x509 -noout -issuer 2>/dev/null || true)
    [[ $issuer == *"Let's Encrypt"* || $issuer == *ZeroSSL* ]] && break
    sleep 5
  done
  printf '%-28s %s\n' "$host" "${issuer:-no certificate}"
  [[ $issuer == *"Let's Encrypt"* || $issuer == *ZeroSSL* ]] || { printf 'Issuance not confirmed for %s (backups %s/*.%s).\n' "$host" "$BACKUP_DIR" "$STAMP" >&2; exit 1; }
done
