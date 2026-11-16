#!/usr/bin/env bash
set -Eeuo pipefail

EXECUTE=false
ROOT=/home/andrew/hosting
BACKUP_ROOT=/home/andrew/hosting-migration-backups/outline-scaffolding

while (($#)); do
  case "$1" in
    --execute) EXECUTE=true; shift ;;
    -h|--help) printf 'Usage: sudo %s [--execute]\n' "$0"; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

[[ $EUID -eq 0 ]] || { echo 'Run with sudo/root.' >&2; exit 1; }
[[ -d "$ROOT/outline" || -f "$ROOT/scripts/27-deploy-outline.sh" ]] || { echo 'No Outline scaffolding found.'; exit 0; }
stamp=$(date -u +%Y%m%dT%H%M%SZ)
backup="$BACKUP_ROOT/$stamp"

if ! $EXECUTE; then
  cat <<EOF
Dry run successful. The deployment will:
  - archive hosting/outline and scripts/27-deploy-outline.sh under $backup
  - remove the local Outline templates and historical deployment script
It will not touch AFFiNE, /opt/selfhost, Caddy, Docker, DNS, or other services.
Run again with --execute to perform this cleanup.
EOF
  exit 0
fi

install -d -o root -g root -m 0700 "$backup"
tar -C "$ROOT" -czf "$backup/outline-scaffolding.tar.gz" outline scripts/27-deploy-outline.sh
sha256sum "$backup/outline-scaffolding.tar.gz" > "$backup/SHA256SUMS"
rm -rf -- "$ROOT/outline" "$ROOT/scripts/27-deploy-outline.sh"
echo "Outline scaffolding removed. Archive: $backup/outline-scaffolding.tar.gz"
