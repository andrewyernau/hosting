#!/usr/bin/env bash
# Read-only verification after completing the Pelican web installer.
# sudo ./06-verify-pelican-install.sh
set -Eeuo pipefail

deploy=/opt/selfhost/pelican
compose=(docker compose --project-directory "$deploy" --env-file "$deploy/.env" -f "$deploy/compose.yml")
section() { printf '\n===== %s =====\n' "$1"; }
run() { "$@" 2>&1 || true; }

[[ $EUID -eq 0 ]] || { printf 'Run this script with sudo/root.\n' >&2; exit 1; }
[[ -r $deploy/compose.yml && -r $deploy/.env ]] || { printf 'Pelican deployment files not found.\n' >&2; exit 1; }

section 'Service state'
run "${compose[@]}" ps

section 'Installed configuration (no secrets)'
run docker exec pelican-panel-1 sh -c "grep -E '^(APP_INSTALLED|DB_CONNECTION|DB_HOST|DB_PORT|DB_DATABASE|APP_URL)=' /pelican-data/.env || true"

section 'HTTP checks through local Caddy origin'
run curl --silent --show-error --insecure --resolve panel.yernau.com:443:127.0.0.1 --output /dev/null --write-out 'root: %{http_code} %{redirect_url}\n' https://panel.yernau.com/
run curl --silent --show-error --insecure --resolve panel.yernau.com:443:127.0.0.1 --output /dev/null --write-out 'installer: %{http_code} %{redirect_url}\n' https://panel.yernau.com/installer

section 'Recent Panel log'
run "${compose[@]}" logs --tail=80 panel

printf '\nVerification finished. No configuration or data was changed.\n'
