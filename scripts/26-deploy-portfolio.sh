#!/usr/bin/env bash
# Deploy the user's portfolio repository behind the existing central Caddy.
# The source repository is public, but runtime secrets are generated locally.
set -Eeuo pipefail

EXECUTE=false
ROOT=/opt/selfhost/portfolio
REPO=https://github.com/andrewyernau/portfolio_web.git
COMPOSE="$ROOT/compose.production.yml"
ENVFILE="$ROOT/.env"
CADDY_SITE=/opt/selfhost/caddy/sites/yernau-portfolio.caddy
ADMIN_EMAIL=${ADMIN_EMAIL:-}

while (($#)); do
  case "$1" in
    --execute) EXECUTE=true; shift ;;
    --root) ROOT=${2:?missing value for --root}; COMPOSE="$ROOT/compose.production.yml"; ENVFILE="$ROOT/.env"; shift 2 ;;
    -h|--help)
      printf 'Usage: sudo %s [--execute]\n' "$0"; exit 0 ;;
    *) printf 'Unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done

[[ $EUID -eq 0 ]] || { printf 'Run with sudo/root.\n' >&2; exit 1; }
command -v docker >/dev/null || { printf 'Docker is required.\n' >&2; exit 1; }
command -v git >/dev/null || { printf 'Git is required.\n' >&2; exit 1; }
command -v openssl >/dev/null || { printf 'OpenSSL is required.\n' >&2; exit 1; }
docker network inspect selfhost_proxy >/dev/null 2>&1 || { printf 'Docker network selfhost_proxy is missing.\n' >&2; exit 1; }
[[ ! -e "$ROOT" ]] || { printf 'Refusing to overwrite existing path: %s\n' "$ROOT" >&2; exit 1; }

if ! $EXECUTE; then
  cat <<EOF
Dry run successful. The deployment will:
  - clone $REPO into $ROOT/source
  - run only portfolio PostgreSQL, API, mail worker, migration, and web services
  - expose no application port on the host; Caddy will use selfhost_proxy
  - install a separate Caddy site for yernau.com and www.yernau.com
  - generate root-only database and analytics secrets
  - ask for the Gmail app password interactively during --execute
  - leave Gambito, Pelican, Wings, UFW, DNS, and router settings unchanged

It will not start Prometheus, Grafana, Alertmanager, Mailpit, or the repository's local backup profile.
Run again with --execute to perform these actions.
EOF
  exit 0
fi

[[ -n $ADMIN_EMAIL ]] || { printf 'Set ADMIN_EMAIL (Gmail account that sends and receives portfolio mail).\n' >&2; exit 1; }

SMTP_PASSWORD=$(read -r -s -p 'Gmail app password for portfolio (hidden): ' value; printf '%s' "$value"; printf '\n' >&2)
SMTP_PASSWORD=${SMTP_PASSWORD//[[:space:]]/}
[[ -n $SMTP_PASSWORD ]] || { printf 'An SMTP app password is required.\n' >&2; exit 1; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
install -d -o root -g root -m 0750 "$tmp/source"
git clone --depth 1 "$REPO" "$tmp/source"
install -d -o root -g root -m 0750 "$ROOT"
cp -a "$tmp/source" "$ROOT/source"
chown -R root:root "$ROOT"
# Source code is copied into images that run as the unprivileged `bun` user.
# Keep the source non-writable but readable; protect the runtime .env separately.
find "$ROOT/source" -type d -exec chmod 0755 {} +
find "$ROOT/source" -type f -exec chmod 0644 {} +
install -m 0640 -o root -g root /home/andrew/hosting/portfolio/compose.production.yml "$COMPOSE"

db_password=$(openssl rand -hex 24)
analytics_secret=$(openssl rand -hex 32)
umask 077
cat > "$ENVFILE" <<EOF
POSTGRES_DB=portfolio
POSTGRES_USER=portfolio
POSTGRES_PASSWORD=$db_password
DATABASE_URL=postgresql://portfolio:$db_password@postgres:5432/portfolio
ANALYTICS_HMAC_SECRET=$analytics_secret
SMTP_USER=$ADMIN_EMAIL
SMTP_PASSWORD=$SMTP_PASSWORD
SMTP_FROM=$ADMIN_EMAIL
SMTP_TO=$ADMIN_EMAIL
EOF
unset SMTP_PASSWORD db_password analytics_secret
chmod 0600 "$ENVFILE"

docker compose --env-file "$ENVFILE" -f "$COMPOSE" config >/dev/null
install -d -o root -g root -m 0750 /opt/selfhost/caddy/sites
install -m 0644 -o root -g root /home/andrew/hosting/portfolio/Caddyfile.template "$CADDY_SITE"

docker compose --env-file "$ENVFILE" -f "$COMPOSE" up -d --build
docker compose --env-file "$ENVFILE" -f "$COMPOSE" ps

caddy_container=$(docker ps --filter 'name=^/caddy-caddy-1$' --format '{{.Names}}' | head -n1)
[[ -n $caddy_container ]] || { printf 'Caddy container caddy-caddy-1 was not found; site installed but reload was not attempted.\n' >&2; exit 1; }
docker exec "$caddy_container" caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
docker exec "$caddy_container" caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile
printf 'Portfolio deployed. Verify https://yernau.com and https://www.yernau.com.\n'
