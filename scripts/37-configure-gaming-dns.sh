#!/usr/bin/env bash
set -Eeuo pipefail

GAMING_ROOT=/opt/selfhost/gaming
GAMING_ENV=$GAMING_ROOT/.env
CERTBOT_CREDENTIALS=/etc/letsencrypt/cloudflare-dns.ini
REUSE_CERTBOT=false

[[ ${1:-} != --reuse-certbot-token ]] || REUSE_CERTBOT=true
[[ $# -le 1 ]] || { printf 'Usage: %s [--reuse-certbot-token]\n' "$0" >&2; exit 2; }
[[ $EUID -eq 0 ]] || { printf 'Run with sudo/root.\n' >&2; exit 1; }
[[ -f $GAMING_ENV ]] || { printf 'Deploy Gaming once before configuring DNS.\n' >&2; exit 1; }
command -v curl >/dev/null || { printf 'curl is required.\n' >&2; exit 1; }

env_value() {
  awk -F= -v key="$1" '$1 == key { sub(/^[^=]*=/, ""); value=$0 } END { gsub(/^"|"$/, "", value); print value }' "$GAMING_ENV"
}

update_env_value() {
  local dns_file=$1 dns_key=$2 dns_value=$3 dns_stage dns_found=false dns_line
  [[ $dns_value != *$'\n'* && $dns_value != *$'\r'* ]] || { printf 'Newlines are not allowed in environment values.\n' >&2; exit 2; }
  dns_stage=$(mktemp "${dns_file}.XXXXXX")
  while IFS= read -r dns_line || [[ -n $dns_line ]]; do
    if [[ $dns_line == "$dns_key="* ]]; then printf '%s=%s\n' "$dns_key" "$dns_value" >> "$dns_stage"; dns_found=true
    else printf '%s\n' "$dns_line" >> "$dns_stage"
    fi
  done < "$dns_file"
  $dns_found || printf '%s=%s\n' "$dns_key" "$dns_value" >> "$dns_stage"
  chown --reference="$dns_file" "$dns_stage"
  chmod --reference="$dns_file" "$dns_stage"
  mv -f "$dns_stage" "$dns_file"
}

if $REUSE_CERTBOT; then
  [[ -r $CERTBOT_CREDENTIALS ]] || { printf 'Cannot read %s.\n' "$CERTBOT_CREDENTIALS" >&2; exit 1; }
  TOKEN=$(awk -F= '/^[[:space:]]*dns_cloudflare_api_token[[:space:]]*=/{sub(/^[^=]*=/, ""); gsub(/^[[:space:]]+|[[:space:]]+$/, ""); print; exit}' "$CERTBOT_CREDENTIALS")
  [[ -n $TOKEN ]] || { printf 'No Cloudflare API token found in the Certbot credentials file.\n' >&2; exit 1; }
else
  read -r -s -p 'Cloudflare API token (Zone DNS Edit for yernau.com): ' TOKEN
  printf '\n'
fi
[[ $TOKEN =~ ^[A-Za-z0-9_-]{20,}$ ]] || { printf 'The Cloudflare API token format is invalid.\n' >&2; exit 2; }

ZONE_NAME=${CLOUDFLARE_ZONE_NAME:-$(env_value CLOUDFLARE_ZONE_NAME)}
ZONE_NAME=${ZONE_NAME:-yernau.com}
[[ $ZONE_NAME =~ ^[a-z0-9.-]+$ ]] || { printf 'Invalid DNS zone name.\n' >&2; exit 2; }
CURRENT_ZONE_ID=$(env_value CLOUDFLARE_ZONE_ID)
read -r -p "Cloudflare zone ID [$CURRENT_ZONE_ID]: " ZONE_ID
ZONE_ID=${ZONE_ID:-$CURRENT_ZONE_ID}
[[ $ZONE_ID =~ ^[A-Fa-f0-9]{32}$ ]] || { printf 'The zone ID must be 32 hexadecimal characters.\n' >&2; exit 2; }

CURRENT_IP=$(env_value GAME_ORIGIN_IPV4)
read -r -p "Public origin IPv4 [$CURRENT_IP]: " ORIGIN_IP
ORIGIN_IP=${ORIGIN_IP:-$CURRENT_IP}
IFS=. read -r IP1 IP2 IP3 IP4 <<< "$ORIGIN_IP"
for OCTET in "$IP1" "$IP2" "$IP3" "$IP4"; do [[ $OCTET =~ ^[0-9]{1,3}$ && $OCTET -le 255 ]] || { printf 'Invalid IPv4 address.\n' >&2; exit 2; }; done

CF_CURL_CONFIG=$(mktemp)
chmod 0600 "$CF_CURL_CONFIG"
trap 'rm -f "$CF_CURL_CONFIG"' EXIT
printf 'header = "Authorization: Bearer %s"\n' "$TOKEN" > "$CF_CURL_CONFIG"
VERIFY=$(curl --fail-with-body --silent --show-error --max-time 20 --config "$CF_CURL_CONFIG" "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records?per_page=1")
[[ $VERIFY == *'"success":true'* ]] || { printf 'Cloudflare did not accept the token/zone combination.\n' >&2; exit 1; }

update_env_value "$GAMING_ENV" GAME_DNS_MODE cloudflare
update_env_value "$GAMING_ENV" CLOUDFLARE_API_TOKEN "$TOKEN"
update_env_value "$GAMING_ENV" CLOUDFLARE_ZONE_ID "$ZONE_ID"
update_env_value "$GAMING_ENV" CLOUDFLARE_ZONE_NAME "$ZONE_NAME"
update_env_value "$GAMING_ENV" GAME_ORIGIN_IPV4 "$ORIGIN_IP"
update_env_value "$GAMING_ENV" GAME_SUBDOMAIN_SUFFIX "$ZONE_NAME"
unset TOKEN VERIFY
rm -f "$CF_CURL_CONFIG"
trap - EXIT

printf 'Cloudflare game DNS is staged for *.%s -> %s. No DNS record was created by this script.\n' "$ZONE_NAME" "$ORIGIN_IP"
printf 'The next deployment will verify access again before accepting live orders.\n'
