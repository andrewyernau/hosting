#!/usr/bin/env bash
# Deploy the first Pelican control plane behind the existing central Caddy.
# It creates only /opt/selfhost/pelican, a private MariaDB, and one Caddy site.
# It never publishes host ports and refuses to overwrite an existing deployment.
#
# Example:
# sudo ./03-deploy-pelican-panel.sh --admin-email admin@example.com --execute
set -Eeuo pipefail

ADMIN_EMAIL=
EXECUTE=false
DEPLOY=/opt/selfhost/pelican
CADDY_ROOT=/opt/selfhost/caddy
CADDY_CONTAINER=caddy-caddy-1
PANEL_SOURCE_IMAGE=ghcr.io/pelican-dev/panel:latest
MARIADB_SOURCE_IMAGE=mariadb:11

usage() { sed -n '2,9p' "$0"; exit 2; }
while (( $# )); do
  case "$1" in
    --admin-email) ADMIN_EMAIL=${2:?missing value}; shift 2 ;;
    --execute) EXECUTE=true; shift ;;
    -h|--help) usage ;;
    *) printf 'Unknown argument: %s\n' "$1" >&2; usage ;;
  esac
done

[[ $EUID -eq 0 ]] || { printf 'Run this script with sudo/root.\n' >&2; exit 1; }
[[ $ADMIN_EMAIL == *@*.* ]] || { printf 'Provide an administrator email with --admin-email.\n' >&2; exit 1; }
command -v docker >/dev/null || { printf 'Docker is required.\n' >&2; exit 1; }
command -v openssl >/dev/null || { printf 'openssl is required.\n' >&2; exit 1; }
docker info >/dev/null || { printf 'Docker daemon is unavailable.\n' >&2; exit 1; }
docker network inspect selfhost_proxy >/dev/null || { printf 'selfhost_proxy network not found.\n' >&2; exit 1; }
docker inspect "$CADDY_CONTAINER" >/dev/null || { printf 'Central Caddy container not found.\n' >&2; exit 1; }
[[ -r $CADDY_ROOT/certs/yernau-origin.crt && -r $CADDY_ROOT/certs/yernau-origin.key ]] || {
  printf 'yernau Origin CA certificate is not installed in central Caddy.\n' >&2; exit 1;
}
[[ ! -e $DEPLOY/compose.yml && ! -e $DEPLOY/.env && ! -e $CADDY_ROOT/sites/pelican-panel.caddy ]] || {
  printf 'A Pelican deployment or Caddy site already exists; refusing to overwrite it.\n' >&2; exit 1;
}

caddy_ip=$(docker inspect "$CADDY_CONTAINER" --format '{{with index .NetworkSettings.Networks "selfhost_proxy"}}{{.IPAddress}}{{end}}')
[[ $caddy_ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || { printf 'Could not determine Caddy IP on selfhost_proxy.\n' >&2; exit 1; }

if ! $EXECUTE; then
  cat <<EOF
Dry run successful. The deployment will:
  - create $DEPLOY (root-owned, no host ports)
  - pull the official Panel and MariaDB images, resolve them to immutable digests
  - create an isolated MariaDB and expose only panel alias pelican-panel on selfhost_proxy
  - install and gracefully reload the new Caddy site panel.yernau.com
  - use Caddy central proxy IP $caddy_ip for trusted proxy handling
Run again with --execute to perform these actions.
EOF
  exit 0
fi

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root_dir=$(CDPATH= cd -- "$script_dir/.." && pwd)
compose_template=$root_dir/pelican/compose.yml.template
inner_caddy_template=$root_dir/pelican/Caddyfile.template
outer_caddy_template=$root_dir/caddy/panel.yernau.com.caddy.template
[[ -r $compose_template && -r $inner_caddy_template && -r $outer_caddy_template ]] || {
  printf 'Required deployment templates are missing beside this script.\n' >&2; exit 1;
}

install -d -o root -g root -m 0750 "$DEPLOY" "$DEPLOY/database"
# The official Panel image runs as Alpine www-data (UID/GID 82). Only its
# application data and logs are writable by that unprivileged user.
install -d -o 82 -g 82 -m 0750 "$DEPLOY/data" "$DEPLOY/logs"
install -o root -g root -m 0640 "$compose_template" "$DEPLOY/compose.yml"
sed "s/__CADDY_PROXY_IP__/$caddy_ip/g" "$inner_caddy_template" >"$DEPLOY/Caddyfile"
# The Panel container runs as UID 82 and must be able to read this non-secret
# Caddy configuration. It contains no credentials.
chmod 0644 "$DEPLOY/Caddyfile"

docker pull "$PANEL_SOURCE_IMAGE" >/dev/null
docker pull "$MARIADB_SOURCE_IMAGE" >/dev/null
panel_image=$(docker image inspect "$PANEL_SOURCE_IMAGE" --format '{{index .RepoDigests 0}}')
mariadb_image=$(docker image inspect "$MARIADB_SOURCE_IMAGE" --format '{{index .RepoDigests 0}}')
[[ $panel_image == ghcr.io/pelican-dev/panel@sha256:* && $mariadb_image == mariadb@sha256:* ]] || {
  printf 'Could not resolve one or both images to immutable digests.\n' >&2; exit 1;
}

umask 077
cat >"$DEPLOY/.env" <<EOF
PANEL_IMAGE=$panel_image
MARIADB_IMAGE=$mariadb_image
PANEL_ADMIN_EMAIL=$ADMIN_EMAIL
CADDY_PROXY_IP=$caddy_ip
MARIADB_DATABASE=pelican
MARIADB_USER=pelican
MARIADB_PASSWORD=$(openssl rand -base64 36 | tr -d '\n')
MARIADB_ROOT_PASSWORD=$(openssl rand -base64 36 | tr -d '\n')
EOF
chmod 0600 "$DEPLOY/.env"

if ! docker compose --project-directory "$DEPLOY" --env-file "$DEPLOY/.env" -f "$DEPLOY/compose.yml" config -q; then
  rm -f "$DEPLOY/.env" "$DEPLOY/compose.yml" "$DEPLOY/Caddyfile"
  printf 'Compose validation failed; deployment files were removed.\n' >&2
  exit 1
fi

docker compose --project-directory "$DEPLOY" --env-file "$DEPLOY/.env" -f "$DEPLOY/compose.yml" up -d
install -o root -g root -m 0644 "$outer_caddy_template" "$CADDY_ROOT/sites/pelican-panel.caddy"
if ! docker exec "$CADDY_CONTAINER" caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile; then
  rm -f "$CADDY_ROOT/sites/pelican-panel.caddy"
  printf 'Caddy validation failed; the new site file was removed. Panel containers remain internal only.\n' >&2
  exit 1
fi
docker exec "$CADDY_CONTAINER" caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile

sleep 5
status=$(curl --silent --show-error --insecure --resolve panel.yernau.com:443:127.0.0.1 --output /dev/null --write-out '%{http_code}' https://panel.yernau.com/installer || true)
printf 'Local HTTPS check for /installer returned HTTP %s.\n' "$status"
printf '%s\n' \
  'Next: visit https://panel.yernau.com/installer and select MySQL/MariaDB.' \
  "Database host: database; database: pelican; user: pelican." \
  "Retrieve its password only when needed: sudo awk -F= '/^MARIADB_PASSWORD=/{print \$2}' $DEPLOY/.env" \
  'After completing the installer, back up the generated APP_KEY outside this host.'
