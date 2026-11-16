#!/usr/bin/env bash
set -Eeuo pipefail

EXECUTE=false
RESET_DATABASE=false
SOURCE=/home/andrew/src/kubo
ROOT=/opt/selfhost/gaming
COMPOSE_TEMPLATE=/home/andrew/hosting/kubo/compose.production.yaml
CADDY_TEMPLATE=/home/andrew/hosting/kubo/Caddyfile.template
CADDY_SITE=/opt/selfhost/caddy/sites/yernau-gaming.caddy

while (($#)); do
  case "$1" in
    --execute) EXECUTE=true; shift ;;
    --reset-database) RESET_DATABASE=true; shift ;;
    -h|--help) printf 'Usage: sudo %s [--execute] [--reset-database]\n' "$0"; exit 0 ;;
    *) printf 'Unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done

[[ $EUID -eq 0 ]] || { printf 'Run with sudo/root.\n' >&2; exit 1; }
$RESET_DATABASE && ! $EXECUTE && { printf '%s\n' '--reset-database requires --execute.' >&2; exit 2; }
for command in docker openssl tar; do command -v "$command" >/dev/null || { printf '%s is required.\n' "$command" >&2; exit 1; }; done
[[ -f "$SOURCE/docker-compose.yaml" && -f "$COMPOSE_TEMPLATE" && -f "$CADDY_TEMPLATE" ]] || { printf 'Gaming source or templates are incomplete.\n' >&2; exit 1; }
docker network inspect selfhost_proxy >/dev/null 2>&1 || { printf 'Missing external network selfhost_proxy.\n' >&2; exit 1; }
docker compose --env-file "$SOURCE/.env.example" -f "$SOURCE/docker-compose.yaml" config >/dev/null

if ! $EXECUTE; then
  cat <<EOF
Dry run successful. Deployment will:
  - copy $SOURCE into a timestamped release below $ROOT/releases
  - preserve an existing $ROOT/.env, or generate a root-only disabled-integration env
  - create the internal gaming_panel_api network shared with the Calagopus Panel
  - start only the Yernau Gaming PostgreSQL, migration, API, worker and web services
  - install $CADDY_SITE and reload the existing central Caddy
It will not change DNS, firewall, Wings, Stripe, Calagopus, or other Compose projects.
EOF
  exit 0
fi

docker network inspect gaming_panel_api >/dev/null 2>&1 || docker network create --internal gaming_panel_api >/dev/null

if [[ -f "$ROOT/.env" ]] && grep -q '^PELICAN_' "$ROOT/.env"; then
  printf 'The Gaming .env still has PELICAN_* settings. Run 40-migrate-pelican-to-calagopus.sh --phase connect-gaming.\n' >&2
  exit 1
fi

stamp=$(date -u +%Y%m%dT%H%M%SZ)
release="$ROOT/releases/$stamp"
install -d -o root -g selfhost -m 2770 "$ROOT"
install -d -o root -g selfhost -m 0750 "$ROOT/releases" "$ROOT/backups"

if $RESET_DATABASE && [[ -d "$ROOT/postgres-data" ]]; then
  if [[ -f "$ROOT/.env" && -f "$ROOT/compose.production.yaml" ]]; then
    docker compose --env-file "$ROOT/.env" -f "$ROOT/compose.production.yaml" down
  fi
  database_archive="$ROOT/backups/postgres-data-$stamp"
  [[ ! -e "$database_archive" ]] || { printf 'Database archive already exists: %s\n' "$database_archive" >&2; exit 1; }
  mv "$ROOT/postgres-data" "$database_archive"
  printf 'Previous PostgreSQL data moved to %s (recoverable).\n' "$database_archive"
fi

install -d -m 0700 "$ROOT/postgres-data"
chown 70:70 "$ROOT/postgres-data"
install -d -o root -g selfhost -m 2750 "$release"
tar --exclude='./.env' --exclude='./.git' --exclude='./.impeccable' --exclude='*/node_modules' --exclude='*/dist' -C "$SOURCE" -cf - . | tar -C "$release" -xf -
chown -R root:selfhost "$release"
find "$release" -type d -exec chmod 2750 {} +
find "$release" -type f -exec chmod 0640 {} +
docker build -t yernau/pumpkin:0.2.1 "$release/infra/pumpkin"
ln -s "$release" "$ROOT/source.next"
mv -Tf "$ROOT/source.next" "$ROOT/source"
chgrp -h selfhost "$ROOT/source"
install -m 0640 -o root -g selfhost "$COMPOSE_TEMPLATE" "$ROOT/compose.production.yaml"

if [[ ! -f "$ROOT/.env" ]]; then
  db_password=$(openssl rand -hex 24)
  jwt_secret=$(openssl rand -hex 48)
  token_secret=$(openssl rand -hex 48)
  csrf_secret=$(openssl rand -hex 48)
  grafana_password=$(openssl rand -hex 18)
  umask 077
  cat > "$ROOT/.env" <<EOF
APP_ENV=production
APP_ORIGIN=https://kubo.csmak.com
PRODUCTION_READY=false
API_PORT=3000
POSTGRES_DB=gaming
POSTGRES_USER=gaming
POSTGRES_PASSWORD=$db_password
DATABASE_URL=postgresql://gaming:$db_password@postgres:5432/gaming
JWT_SIGNING_SECRET=$jwt_secret
TOKEN_HMAC_SECRET=$token_secret
CSRF_SECRET=$csrf_secret
TRUSTED_PROXY_HOPS=1
BILLING_MODE=disabled
STRIPE_SECRET_KEY=
STRIPE_WEBHOOK_SECRET=
STRIPE_PRICE_BASIC=
STRIPE_PRICE_STANDARD=
STRIPE_PRICE_PLUS=
STRIPE_PRICE_PRO=
STRIPE_AUTOMATIC_TAX=false
CALAGOPUS_MODE=disabled
CALAGOPUS_BASE_URL=http://calagopus-panel-api:8000
CALAGOPUS_API_KEY=
CALAGOPUS_NODE_UUID=
CALAGOPUS_ALLOCATION_IP=192.168.0.111
CALAGOPUS_DOCKER_IMAGE=ghcr.io/pelican-eggs/yolks:java_25
GAME_PUBLIC_HOST=es1.kubo.csmak.com
GAME_DNS_MODE=disabled
CLOUDFLARE_API_TOKEN=
CLOUDFLARE_ZONE_ID=
CLOUDFLARE_ZONE_NAME=csmak.com
GAME_ORIGIN_IPV4=
GAME_SUBDOMAIN_SUFFIX=kubo.csmak.com
PANEL_PUBLIC_URL=https://panel.kubo.csmak.com
GAME_PORT_START=25550
GAME_PORT_END=25580
SELLABLE_MEMORY_MB=24576
SELLABLE_DISK_MB=300000
SELLABLE_CPU_PERCENT=800
PAYMENT_GRACE_DAYS=3
SUSPENDED_RETENTION_DAYS=14
AUTOMATIC_SERVER_DELETION=false
SMTP_MODE=log
SMTP_HOST=
SMTP_PORT=465
SMTP_SECURE=true
SMTP_USER=
SMTP_PASSWORD=
SMTP_FROM="Kubo <no-reply@yernau.com>"
TURNSTILE_MODE=disabled
TURNSTILE_SITE_KEY=
TURNSTILE_SECRET=
METRICS_TOKEN=$(openssl rand -hex 24)
GRAFANA_ADMIN_USER=admin
GRAFANA_ADMIN_PASSWORD=$grafana_password
PROMETHEUS_HTTP_PORT=9091
GRAFANA_HTTP_PORT=3002
BACKUP_RETENTION_DAYS=14
EOF
  chown root:selfhost "$ROOT/.env"
  chmod 0640 "$ROOT/.env"
  unset db_password jwt_secret token_secret csrf_secret grafana_password
fi

ensure_env_default() {
  local gaming_key=$1 gaming_value=$2
  grep -q "^${gaming_key}=" "$ROOT/.env" || printf '%s=%s\n' "$gaming_key" "$gaming_value" >> "$ROOT/.env"
}
ensure_env_default CALAGOPUS_BASE_URL http://calagopus-panel-api:8000
ensure_env_default CALAGOPUS_ALLOCATION_IP 192.168.0.111
ensure_env_default GAME_PUBLIC_HOST es1.kubo.csmak.com
ensure_env_default GAME_DNS_MODE disabled
ensure_env_default CLOUDFLARE_API_TOKEN ''
ensure_env_default CLOUDFLARE_ZONE_ID ''
ensure_env_default CLOUDFLARE_ZONE_NAME csmak.com
ensure_env_default GAME_ORIGIN_IPV4 ''
ensure_env_default GAME_SUBDOMAIN_SUFFIX kubo.csmak.com
ensure_env_default PANEL_PUBLIC_URL https://panel.kubo.csmak.com
ensure_env_default GAME_PORT_START 25550
ensure_env_default GAME_PORT_END 25580
ensure_env_default PAYMENT_GRACE_DAYS 3
ensure_env_default SUSPENDED_RETENTION_DAYS 14
ensure_env_default AUTOMATIC_SERVER_DELETION false
ensure_env_default PRODUCTION_READY false

env_mode() {
  awk -F= -v key="$1" '$1 == key { sub(/^[^=]*=/, ""); value=$0 } END { print value }' "$ROOT/.env"
}

docker compose --env-file "$ROOT/.env" -f "$ROOT/compose.production.yaml" config >/dev/null
chgrp selfhost "$ROOT/.env"
install -m 0644 -o root -g selfhost "$CADDY_TEMPLATE" "$CADDY_SITE"
docker compose --env-file "$ROOT/.env" -f "$ROOT/compose.production.yaml" build
if [[ $(env_mode BILLING_MODE) == live ]]; then
  printf 'Running live production preflight before replacing containers...\n'
  docker compose --env-file "$ROOT/.env" -f "$ROOT/compose.production.yaml" run --rm --no-deps api bun /app/api/src/cli/check-production.ts
fi
docker compose --env-file "$ROOT/.env" -f "$ROOT/compose.production.yaml" --profile monitoring up -d
docker compose --env-file "$ROOT/.env" -f "$ROOT/compose.production.yaml" ps

caddy_container=$(docker ps --filter 'name=^/caddy-caddy-1$' --format '{{.Names}}' | head -n1)
[[ -n $caddy_container ]] || { printf 'Caddy container not found; site installed but not reloaded.\n' >&2; exit 1; }
docker exec "$caddy_container" caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
docker exec "$caddy_container" caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile

billing_mode=$(env_mode BILLING_MODE)
panel_mode=$(env_mode CALAGOPUS_MODE)
turnstile_mode=$(env_mode TURNSTILE_MODE)
dns_mode=$(env_mode GAME_DNS_MODE)
printf 'Yernau Gaming deployed successfully (billing: %s; Calagopus: %s; Turnstile: %s; game DNS: %s).\n' \
  "${billing_mode:-disabled}" "${panel_mode:-disabled}" "${turnstile_mode:-disabled}" "${dns_mode:-disabled}"
