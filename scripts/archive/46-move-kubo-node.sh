#!/usr/bin/env bash
# Move node-01 (Wings) to es1.kubo.csmak.com and deploy Kubo (ex Yernau Gaming) with the
# new domains and the subdomain filter. Root-only steps of the kubo.csmak.com migration;
# DNS, Caddy, panel settings and the Gaming .env were prepared beforehand.
#
#   sudo ./46-move-kubo-node.sh            # dry run: checks and plan
#   sudo ./46-move-kubo-node.sh --execute
set -Eeuo pipefail

EXECUTE=false
[[ ${1:-} == --execute ]] && EXECUTE=true
[[ $# -le 1 && ( $# -eq 0 || $EXECUTE == true ) ]] || { printf 'Usage: sudo %s [--execute]\n' "$0" >&2; exit 2; }
[[ $EUID -eq 0 ]] || { printf 'Run with sudo/root.\n' >&2; exit 1; }

NEW=es1.kubo.csmak.com
OLD=node-01.yernau.com
PANEL=https://panel.kubo.csmak.com
WINGS_CONFIG=/etc/pelican/config.yml
CREDENTIALS=/etc/letsencrypt/cloudflare-dns.ini
NEW_TOKEN_FILE=/home/andrew/.config/cloudflare/token
HERE=$(cd "$(dirname "$0")" && pwd)
STAMP=$(date -u +%Y%m%dT%H%M%SZ)

for f in "$WINGS_CONFIG" "$CREDENTIALS" "$NEW_TOKEN_FILE" "$HERE/33-deploy-gaming.sh"; do
  [[ -f $f ]] || { printf 'Missing %s\n' "$f" >&2; exit 1; }
done
grep -q "/live/$OLD/fullchain.pem" "$WINGS_CONFIG" || grep -q "/live/$NEW/fullchain.pem" "$WINGS_CONFIG" \
  || { printf 'Unexpected Wings TLS paths in %s\n' "$WINGS_CONFIG" >&2; exit 1; }
[[ $(getent ahostsv4 "$NEW" | awk 'NR==1{print $1}') == 143.20.32.134 ]] \
  || printf 'Warning: %s does not resolve to the VPS yet (fine for DNS-01).\n' "$NEW" >&2

if ! $EXECUTE; then
  cat <<EOF
Dry run OK. --execute will:
  1. put the minipc-domains Cloudflare token (DNS edit incl. csmak.com) in $CREDENTIALS
     (backup kept next to it); renewals of $OLD keep working with it
  2. certbot certonly (DNS-01) for $NEW; the existing deploy hook restarts Wings on renewal
  3. point Wings TLS to /etc/letsencrypt/live/$NEW and 'remote' to $PANEL
     (backup $WINGS_CONFIG.before-kubo.$STAMP), restart Wings and verify the certificate
  4. run 33-deploy-gaming.sh --execute (new release with kubo.csmak.com + subdomain filter)
If Wings does not come back, the script restores its config and restarts it.
EOF
  exit 0
fi

printf '== 1. Cloudflare credentials for certbot\n'
cp -p "$CREDENTIALS" "$CREDENTIALS.before-kubo.$STAMP"
( umask 077; printf 'dns_cloudflare_api_token = %s\n' "$(tr -d '[:space:]' < "$NEW_TOKEN_FILE")" > "$CREDENTIALS" )
chmod 0600 "$CREDENTIALS"

printf '== 2. Certificate for %s\n' "$NEW"
certbot certonly --non-interactive --keep-until-expiring --key-type ecdsa \
  --dns-cloudflare --dns-cloudflare-credentials "$CREDENTIALS" --dns-cloudflare-propagation-seconds 60 \
  --domain "$NEW"
openssl x509 -in "/etc/letsencrypt/live/$NEW/fullchain.pem" -noout -subject -issuer -enddate

printf '== 3. Wings\n'
cp -p "$WINGS_CONFIG" "$WINGS_CONFIG.before-kubo.$STAMP"
sed -i -e "s#/etc/letsencrypt/live/$OLD/#/etc/letsencrypt/live/$NEW/#g" \
       -e "s#^remote: .*#remote: $PANEL#" "$WINGS_CONFIG"
grep -nE "live/|^remote:" "$WINGS_CONFIG"
systemctl restart wings.service
ok=false
for _ in $(seq 1 20); do
  sleep 2
  subject=$(echo | timeout 5 openssl s_client -connect 127.0.0.1:8443 -servername "$NEW" 2>/dev/null | openssl x509 -noout -subject 2>/dev/null || true)
  if systemctl is-active --quiet wings.service && [[ $subject == *"$NEW"* ]]; then ok=true; break; fi
done
if ! $ok; then
  printf 'Wings did not come back with the new certificate; restoring the previous config.\n' >&2
  cp -p "$WINGS_CONFIG.before-kubo.$STAMP" "$WINGS_CONFIG"
  systemctl restart wings.service
  journalctl -u wings.service -n 30 --no-pager >&2
  exit 1
fi
printf 'Wings serves %s\n' "$subject"

printf '== 4. Deploy Kubo\n'
"$HERE/33-deploy-gaming.sh" --execute

printf '\nDone. Tell Claude to run phase C (panel node URL, server migration, old-domain redirects).\n'
