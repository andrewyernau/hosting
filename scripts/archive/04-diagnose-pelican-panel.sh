#!/usr/bin/env bash
# Read-only diagnostics for a Panel deployment returning 502.
# sudo ./04-diagnose-pelican-panel.sh | tee ~/pelican-panel-diagnose.txt
set -Eeuo pipefail

deploy=/opt/selfhost/pelican
compose=(docker compose --project-directory "$deploy" --env-file "$deploy/.env" -f "$deploy/compose.yml")
section() { printf '\n===== %s =====\n' "$1"; }
run() { "$@" 2>&1 || true; }

[[ $EUID -eq 0 ]] || { printf 'Run this script with sudo/root.\n' >&2; exit 1; }
[[ -r $deploy/compose.yml && -r $deploy/.env ]] || { printf 'Pelican deployment files not found.\n' >&2; exit 1; }

section 'Compose state'
run "${compose[@]}" ps
run docker inspect pelican-panel-1 --format 'State={{.State.Status}} Exit={{.State.ExitCode}} Started={{.State.StartedAt}}'
run docker inspect pelican-database-1 --format 'State={{.State.Status}} Health={{if .State.Health}}{{.State.Health.Status}}{{end}}'

section 'Recent Panel logs'
run "${compose[@]}" logs --tail=200 panel

section 'Recent database logs'
run "${compose[@]}" logs --tail=100 database

section 'Panel internal webserver and PHP'
run docker exec pelican-panel-1 caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
run docker exec pelican-panel-1 sh -c 'ps aux; ss -lntp || netstat -lntp'
run docker exec pelican-panel-1 sh -c 'test -f /var/www/html/.env && echo app-env-present || echo app-env-missing'
run docker exec pelican-panel-1 sh -c 'wget -S -O /dev/null http://127.0.0.1/installer 2>&1 || true'

section 'Outer proxy path'
run docker exec caddy-caddy-1 sh -c 'wget -S -O /dev/null http://pelican-panel:80/installer 2>&1 || true'
run curl --silent --show-error --insecure --resolve panel.yernau.com:443:127.0.0.1 --output /dev/null --write-out 'origin HTTPS status: %{http_code}\n' https://panel.yernau.com/installer

printf '\nDiagnostics finished. No service, configuration or data was changed.\n'
