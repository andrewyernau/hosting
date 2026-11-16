#!/usr/bin/env bash
# Read-only storage diagnostics for a failed server archive extraction.
# It reports host free space, per-server usage, archive sizes, and the Panel's
# stored disk limits without printing database credentials or application keys.

set -Eeuo pipefail

VOLUMES=/srv/pelican/volumes
ARCHIVES=/srv/pelican/archives
BACKUPS=/srv/pelican/backups
DATABASE_CONTAINER=pelican-database-1

[[ $EUID -eq 0 ]] || { printf 'Run this script with sudo/root.\n' >&2; exit 1; }
command -v docker >/dev/null || { printf 'Docker is required.\n' >&2; exit 1; }
[[ -d $VOLUMES && -d $ARCHIVES && -d $BACKUPS ]] || { printf 'Expected Pelican storage directories are missing.\n' >&2; exit 1; }

printf '%s\n' '===== Host filesystem capacity ====='
df -h "$VOLUMES" "$ARCHIVES" "$BACKUPS" /tmp
df -i "$VOLUMES" "$ARCHIVES" "$BACKUPS" /tmp

printf '%s\n' '===== Per-server volume usage ====='
find "$VOLUMES" -mindepth 1 -maxdepth 1 -type d -print0 | xargs -0 -r du -sh

printf '%s\n' '===== Archive files inside server volumes ====='
find "$VOLUMES" -type f \( -iname '*.zip' -o -iname '*.tar' -o -iname '*.tar.gz' -o -iname '*.tgz' \) -printf '%s bytes\t%p\n' | sort -n || true

printf '%s\n' '===== Panel server disk limits (MiB) ====='
if docker inspect "$DATABASE_CONTAINER" >/dev/null 2>&1; then
  docker exec "$DATABASE_CONTAINER" sh -c '
    mariadb -N -u root -p"$MARIADB_ROOT_PASSWORD" "$MARIADB_DATABASE" \
      -e "SELECT uuid, name, disk FROM servers ORDER BY id;"
  ' || printf '%s\n' 'Could not query stored limits; inspect them in Panel instead.'
else
  printf '%s\n' 'Pelican database container was not found.'
fi

printf '%s\n' 'Diagnostics finished. No data, limits, files, services, or configuration was changed.'
