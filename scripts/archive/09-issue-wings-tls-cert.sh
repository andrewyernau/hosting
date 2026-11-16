#!/usr/bin/env bash
# Obtain and renew a public Let's Encrypt certificate for a Wings node through
# Cloudflare DNS-01. It does not open ports or change Caddy.
#
# sudo ./09-issue-wings-tls-cert.sh --email admin@example.com --execute
set -Eeuo pipefail

domain=node-01.yernau.com
zone=yernau.com
email=
credentials=/etc/letsencrypt/cloudflare-dns.ini
execute=false
reuse_credentials=false
verify_credentials=false
verify_zone_access=false

usage() {
  sed -n '2,5p' "$0"
  exit 2
}

while (( $# )); do
  case "$1" in
    --domain) domain=${2:?missing value}; shift 2 ;;
    --zone) zone=${2:?missing value}; shift 2 ;;
    --email) email=${2:?missing value}; shift 2 ;;
    --reuse-credentials) reuse_credentials=true; shift ;;
    --verify-credentials) verify_credentials=true; shift ;;
    --verify-zone-access) verify_zone_access=true; shift ;;
    --execute) execute=true; shift ;;
    -h|--help) usage ;;
    *) printf 'Unknown argument: %s\n' "$1" >&2; usage ;;
  esac
done

[[ $EUID -eq 0 ]] || { printf 'Run this script with sudo/root.\n' >&2; exit 1; }
[[ $domain != *' '* && $domain == *.* ]] || { printf 'Provide a valid DNS name with --domain.\n' >&2; exit 1; }
[[ $zone != *' '* && $zone == *.* ]] || { printf 'Provide a valid Cloudflare zone with --zone.\n' >&2; exit 1; }

if $verify_credentials || $verify_zone_access; then
  [[ -r $credentials ]] || { printf 'No readable credentials file exists at %s.\n' "$credentials" >&2; exit 1; }
  cf_token=$(sed -n 's/^dns_cloudflare_api_token = //p' "$credentials")
  [[ -n $cf_token && $(printf '%s\n' "$cf_token" | wc -l) -eq 1 ]] || {
    printf 'The credentials file does not contain exactly one API token entry.\n' >&2
    exit 1
  }
  curl --fail --silent --show-error --output /dev/null \
    --write-out 'Cloudflare token verification: HTTP %{http_code}\n' \
    --header "Authorization: Bearer $cf_token" \
    https://api.cloudflare.com/client/v4/user/tokens/verify
  unset cf_token
  printf 'Authentication succeeded. This checks identity only; Certbot will check the scoped DNS permission.\n'
  if ! $verify_zone_access; then
    exit 0
  fi

  cf_token=$(sed -n 's/^dns_cloudflare_api_token = //p' "$credentials")
  zone_json=$(curl --fail --silent --show-error \
    --header "Authorization: Bearer $cf_token" \
    "https://api.cloudflare.com/client/v4/zones?name=$zone")
  zone_id=$(printf '%s' "$zone_json" | sed -n 's/.*"result":\[{"id":"\([^"]*\)".*/\1/p')
  [[ -n $zone_id ]] || {
    printf 'The token authenticated but cannot discover the Cloudflare zone %s.\n' "$zone" >&2
    exit 1
  }
  curl --fail --silent --show-error --output /dev/null \
    --write-out 'Cloudflare DNS read check: HTTP %{http_code}\n' \
    --header "Authorization: Bearer $cf_token" \
    "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records?name=_acme-challenge.$domain"
  unset cf_token zone_json zone_id
  printf 'The token can discover the zone and read its DNS records.\n'
  exit 0
fi

[[ -n $email ]] || { printf 'Provide a renewal email with --email.\n' >&2; exit 1; }

printf '%s\n' \
  "Domain: $domain" \
  "Credentials file: $credentials (root-only)" \
  'Will install Certbot and its Cloudflare DNS plugin, request/renew one public certificate, and enable normal Certbot renewal.' \
  'No TCP/UDP ports, firewall rules, Caddy configuration, or game containers will be changed.'

if ! $execute; then
  printf 'Dry run complete. Create the scoped Cloudflare API token, then re-run with --execute.\n'
  exit 0
fi

if [[ -e $credentials ]] && ! $reuse_credentials; then
  printf 'Refusing to overwrite existing Cloudflare credentials at %s. Inspect or rotate them deliberately first.\n' "$credentials" >&2
  exit 1
fi

apt-get update
apt-get install -y certbot python3-certbot-dns-cloudflare

if $reuse_credentials; then
  [[ -r $credentials ]] || { printf 'No readable credentials file exists at %s.\n' "$credentials" >&2; exit 1; }
  printf 'Reusing existing Cloudflare credentials; no token was requested or displayed.\n'
else
  read -r -s -p 'Paste the scoped Cloudflare API token (input hidden): ' cf_token
  printf '\n'
  [[ -n $cf_token ]] || { printf 'No token provided.\n' >&2; exit 1; }
  install -d -o root -g root -m 0700 /etc/letsencrypt
  umask 077
  printf 'dns_cloudflare_api_token = %s\n' "$cf_token" >"$credentials"
  unset cf_token
  chown root:root "$credentials"
  chmod 0600 "$credentials"
fi

certbot certonly \
  --non-interactive \
  --agree-tos \
  --email "$email" \
  --keep-until-expiring \
  --dns-cloudflare \
  --dns-cloudflare-credentials "$credentials" \
  --dns-cloudflare-propagation-seconds 60 \
  --domain "$domain"

install -d -o root -g root -m 0755 /etc/letsencrypt/renewal-hooks/deploy
cat >/etc/letsencrypt/renewal-hooks/deploy/restart-wings-if-installed <<'HOOK'
#!/bin/sh
# Certbot invokes this only after a successful certificate renewal.
if systemctl cat wings.service >/dev/null 2>&1; then
  systemctl restart wings.service
fi
HOOK
chown root:root /etc/letsencrypt/renewal-hooks/deploy/restart-wings-if-installed
chmod 0755 /etc/letsencrypt/renewal-hooks/deploy/restart-wings-if-installed

if systemctl list-unit-files certbot.timer --no-legend 2>/dev/null | grep -q '^certbot.timer'; then
  systemctl enable --now certbot.timer
fi

openssl x509 -in "/etc/letsencrypt/live/$domain/fullchain.pem" -noout -subject -issuer -enddate
printf '%s\n' \
  'Certificate ready. Its private key and Cloudflare token are root-only.' \
  'Next: install Wings, save the rotated node configuration privately, then validate it before enabling the service.'
