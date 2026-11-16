#!/usr/bin/env bash
# Read-only diagnostics when an installed Pelican panel still redirects to /installer.
# sudo ./07-diagnose-installer-redirect.sh
set -Eeuo pipefail

deploy=/opt/selfhost/pelican
compose=(docker compose --project-directory "$deploy" --env-file "$deploy/.env" -f "$deploy/compose.yml")
section() { printf '\n===== %s =====\n' "$1"; }
run() { "$@" 2>&1 || true; }

[[ $EUID -eq 0 ]] || { printf 'Run this script with sudo/root.\n' >&2; exit 1; }
[[ -r $deploy/.env ]] || { printf 'Pelican deployment files not found.\n' >&2; exit 1; }

root_password=$(awk -F= '/^MARIADB_ROOT_PASSWORD=/{print $2}' "$deploy/.env")
[[ -n $root_password ]] || { printf 'MariaDB root password was not found.\n' >&2; exit 1; }

section 'Panel configuration (no secrets)'
run docker exec pelican-panel-1 sh -c "grep -E '^(APP_INSTALLED|APP_URL|DB_CONNECTION|DB_DATABASE|DB_HOST|DB_PORT)=' /pelican-data/.env"

section 'Database installation state'
run docker exec pelican-database-1 mariadb -u root -p"$root_password" --batch --skip-column-names pelican -e "SELECT 'migrations', COUNT(*) FROM migrations UNION ALL SELECT 'users', COUNT(*) FROM users;"
run docker exec pelican-database-1 mariadb -u root -p"$root_password" --batch --skip-column-names pelican -e "SELECT id, username, email, root_admin FROM users ORDER BY id;"

section 'Relevant routes'
run docker exec pelican-panel-1 php artisan route:list --path=installer
run docker exec pelican-panel-1 php artisan route:list --path=admin

section 'Redirects from the origin'
run curl --silent --show-error --insecure --resolve panel.yernau.com:443:127.0.0.1 --head https://panel.yernau.com/
run curl --silent --show-error --insecure --resolve panel.yernau.com:443:127.0.0.1 --head https://panel.yernau.com/admin
run curl --silent --show-error --insecure --resolve panel.yernau.com:443:127.0.0.1 --head https://panel.yernau.com/installer

printf '\nDiagnostics finished. No user, database, configuration or service was changed.\n'
