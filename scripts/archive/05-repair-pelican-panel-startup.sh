#!/usr/bin/env bash
# Repairs only the known initial Panel startup configuration.
# It does not delete databases, data, Caddy certificates or other services.
# sudo ./05-repair-pelican-panel-startup.sh --execute
set -Eeuo pipefail

deploy=/opt/selfhost/pelican
caddy_container=caddy-caddy-1
execute=false

[[ ${1:-} == --execute ]] && execute=true
[[ $# -eq 0 || ${1:-} == --execute ]] || { printf 'Usage: %s [--execute]\n' "$0" >&2; exit 2; }
[[ $EUID -eq 0 ]] || { printf 'Run this script with sudo/root.\n' >&2; exit 1; }
[[ -r $deploy/compose.yml && -r $deploy/.env ]] || { printf 'Pelican deployment files not found.\n' >&2; exit 1; }
docker inspect "$caddy_container" >/dev/null || { printf 'Central Caddy container not found.\n' >&2; exit 1; }
caddy_ip=$(docker inspect "$caddy_container" --format '{{with index .NetworkSettings.Networks "selfhost_proxy"}}{{.IPAddress}}{{end}}')
[[ $caddy_ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || { printf 'Could not determine central Caddy IP.\n' >&2; exit 1; }

if ! $execute; then
  printf 'Dry run: will grant UID/GID 82 write access only to %s/{data,logs}, add proxy settings, and recreate only pelican-panel-1.\n' "$deploy"
  exit 0
fi

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root_dir=$(CDPATH= cd -- "$script_dir/.." && pwd)
template=$root_dir/pelican/compose.yml.template
[[ -r $template ]] || { printf 'Updated compose template is missing.\n' >&2; exit 1; }

timestamp=$(date +%Y%m%d%H%M%S)
cp -a "$deploy/compose.yml" "$deploy/compose.yml.before-startup-fix-$timestamp"
install -o root -g root -m 0640 "$template" "$deploy/compose.yml"
chown -R 82:82 "$deploy/data" "$deploy/logs"
chmod 0750 "$deploy/data" "$deploy/logs"
# This is configuration, not a secret; the unprivileged Panel Caddy must read it.
chmod 0644 "$deploy/Caddyfile"
if grep -q '^CADDY_PROXY_IP=' "$deploy/.env"; then
  sed -i "s/^CADDY_PROXY_IP=.*/CADDY_PROXY_IP=$caddy_ip/" "$deploy/.env"
else
  printf '\nCADDY_PROXY_IP=%s\n' "$caddy_ip" >>"$deploy/.env"
fi
chmod 0600 "$deploy/.env"

compose=(docker compose --project-directory "$deploy" --env-file "$deploy/.env" -f "$deploy/compose.yml")
"${compose[@]}" config -q
"${compose[@]}" up -d --force-recreate panel
sleep 8
"${compose[@]}" ps
"${compose[@]}" logs --tail=80 panel
printf '%s\n' 'Repair complete. If the panel is running, open /installer; otherwise run 04-diagnose-pelican-panel.sh again.'
