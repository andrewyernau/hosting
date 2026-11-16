#!/usr/bin/env bash
set -Eeuo pipefail

EXECUTE=false
OLD=/home/andrew/hosting
NEW=/home/andrew/hosting
BACKUP_ROOT=/home/andrew/hosting-migration-backups
GAMBITO=/home/andrew/src/aj-gambito-pt

while (($#)); do
  case "$1" in
    --execute) EXECUTE=true; shift ;;
    -h|--help) printf 'Usage: sudo %s [--execute]\n' "$0"; exit 0 ;;
    *) printf 'Unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done

[[ $EUID -eq 0 ]] || { echo 'Run with sudo/root.' >&2; exit 1; }
[[ -d "$OLD" ]] || { echo "Missing source directory: $OLD" >&2; exit 1; }
[[ ! -e "$NEW" ]] || { echo "Destination already exists: $NEW" >&2; exit 1; }

stamp=$(date -u +%Y%m%dT%H%M%SZ)
backup="$BACKUP_ROOT/$stamp"

if ! $EXECUTE; then
  cat <<EOF
Dry run successful. The migration will:
  - create a compressed backup of $OLD at $backup
  - record Docker, systemd, Git, and Compose state
  - stop the Gambito Compose project only (no volumes removed)
  - rename $OLD to $NEW
  - update internal references from $OLD to $NEW
  - validate all deployment scripts and the central Caddy configuration
  - start Gambito again with its existing Compose project
It will not move /opt/selfhost, delete data, reset Git, or modify DNS/firewall rules.
Run again with --execute to apply the migration.
EOF
  exit 0
fi

mkdir -p "$backup"
tar -C /home/andrew -czf "$backup/gaming-hosting.tar.gz" gaming-hosting
sha256sum "$backup/gaming-hosting.tar.gz" > "$backup/SHA256SUMS"
{
  date -Is
  echo '===== docker ps ====='; docker ps
  echo '===== Gambito compose ps ====='; docker compose -f "$GAMBITO/docker-compose.yml" ps || true
  echo '===== Caddy status ====='; docker ps --filter 'name=^/caddy-caddy-1$'
  echo '===== git status ====='; git -C "$OLD" status --short --branch || true
} > "$backup/state.txt"

if [[ -f "$GAMBITO/docker-compose.yml" ]]; then
  docker compose -f "$GAMBITO/docker-compose.yml" down --remove-orphans
fi

mv -- "$OLD" "$NEW"
find "$NEW" -type f -not -path '*/.git/*' -print0 \
  | xargs -0 -r sed -i "s#${OLD}#${NEW}#g"

while IFS= read -r -d '' script; do
  bash -n "$script"
done < <(find "$NEW/scripts" -maxdepth 1 -type f -name '*.sh' -print0)

docker exec caddy-caddy-1 caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
docker exec caddy-caddy-1 caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile

if [[ -f "$GAMBITO/docker-compose.yml" ]]; then
  docker compose -f "$GAMBITO/docker-compose.yml" up -d
  docker compose -f "$GAMBITO/docker-compose.yml" ps
fi

echo "Migration complete. New path: $NEW"
echo "Recovery backup: $backup/gaming-hosting.tar.gz"
