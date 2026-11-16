#!/usr/bin/env bash
set -Eeuo pipefail

EXECUTE=false
ROOT=/opt/selfhost/outline
BACKUP_ROOT=/var/backups/outline-retired

while (($#)); do
  case "$1" in
    --execute) EXECUTE=true; shift ;;
    -h|--help) printf 'Usage: sudo %s [--execute]\n' "$0"; exit 0 ;;
    *) printf 'Unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done

[[ $EUID -eq 0 ]] || { echo 'Run with sudo/root.' >&2; exit 1; }
[[ -d "$ROOT" ]] || { echo "Nothing to remove: $ROOT does not exist."; exit 0; }

stamp=$(date -u +%Y%m%dT%H%M%SZ)
backup="$BACKUP_ROOT/$stamp"

if ! $EXECUTE; then
  cat <<EOF
Dry run successful. The deployment will:
  - create a root-only archive at $backup
  - stop and remove the Outline containers and networks (without deleting Docker volumes first)
  - remove the old Outline Caddy site, if present
  - remove $ROOT after the archive succeeds
It will not touch AFFiNE, Pelican, Gambito, Portfolio, Caddy itself, or DNS.
Run again with --execute to perform this irreversible cleanup.
EOF
  exit 0
fi

install -d -o root -g root -m 0700 "$backup"
tar -C /opt/selfhost -czf "$backup/outline-directory.tar.gz" outline
sha256sum "$backup/outline-directory.tar.gz" > "$backup/SHA256SUMS"

if [[ -f "$ROOT/compose.yml" && -f "$ROOT/.env" ]]; then
  docker compose --env-file "$ROOT/.env" -f "$ROOT/compose.yml" down --remove-orphans || true
fi

find /opt/selfhost/caddy/sites -maxdepth 1 -type f -name 'outline.caddy*' -delete 2>/dev/null || true
rm -rf -- "$ROOT"

echo "Outline removed. Recovery archive: $backup/outline-directory.tar.gz"
