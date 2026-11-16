#!/usr/bin/env bash
# Create a consistent, root-only local recovery copy of the Pelican database
# and non-secret deployment configuration. This is staging, not off-host DR.
#
# sudo ./08-backup-pelican-panel.sh --execute
# sudo ./08-backup-pelican-panel.sh --destination /mnt/nas/pelican --execute
set -Eeuo pipefail

deploy=/opt/selfhost/pelican
destination=/var/backups/pelican
execute=false

usage() {
  sed -n '2,6p' "$0"
  exit 2
}

while (( $# )); do
  case "$1" in
    --destination) destination=${2:?missing value}; shift 2 ;;
    --execute) execute=true; shift ;;
    -h|--help) usage ;;
    *) printf 'Unknown argument: %s\n' "$1" >&2; usage ;;
  esac
done

[[ $EUID -eq 0 ]] || { printf 'Run this script with sudo/root.\n' >&2; exit 1; }
[[ $destination = /* ]] || { printf 'The destination must be an absolute path.\n' >&2; exit 1; }
[[ -r $deploy/compose.yml && -r $deploy/.env ]] || {
  printf 'Pelican deployment files not found under %s.\n' "$deploy" >&2
  exit 1
}
command -v docker >/dev/null || { printf 'Docker is required.\n' >&2; exit 1; }
docker inspect --format '{{.State.Running}}' pelican-database-1 2>/dev/null | grep -qx true || {
  printf 'The Pelican database container is not running; no backup was made.\n' >&2
  exit 1
}

printf '%s\n' \
  "Destination: $destination" \
  'The backup contains the Pelican MariaDB dump and non-secret configuration.' \
  'It intentionally does NOT copy APP_KEY or passwords; APP_KEY must remain in your password manager.'

if ! $execute; then
  printf 'Dry run complete. Re-run with --execute to write the backup.\n'
  exit 0
fi

install -d -o root -g root -m 0700 "$destination"
timestamp=$(date -u +%Y%m%dT%H%M%SZ)
backup_dir="$destination/$timestamp"
install -d -o root -g root -m 0700 "$backup_dir"

cleanup() {
  if [[ -d $backup_dir && ! -f $backup_dir/SHA256SUMS ]]; then
    rm -rf -- "$backup_dir"
  fi
}
trap cleanup ERR

# The password is expanded only inside the database container, never printed
# or placed in the host process arguments.
docker exec pelican-database-1 sh -ec \
  'exec mariadb-dump --single-transaction --routines --events --add-drop-table -uroot -p"$MARIADB_ROOT_PASSWORD" "$MARIADB_DATABASE"' \
  | gzip --no-name >"$backup_dir/pelican.sql.gz"

install -o root -g root -m 0600 /dev/null "$backup_dir/panel.env.nonsecret"
grep -Ev '^(APP_KEY|.*(PASSWORD|SECRET|TOKEN)|MARIADB_ROOT_PASSWORD)=' "$deploy/data/.env" \
  >"$backup_dir/panel.env.nonsecret"
install -o root -g root -m 0600 "$deploy/compose.yml" "$backup_dir/compose.yml"
install -o root -g root -m 0600 /opt/selfhost/caddy/sites/pelican-panel.caddy "$backup_dir/pelican-panel.caddy"

{
  printf 'created_utc=%s\n' "$timestamp"
  printf 'database_dump=pelican.sql.gz\n'
  printf 'app_key_location=external_password_manager\n'
  printf 'restore_note=Restore only into a compatible, stopped Pelican deployment; test in an isolated environment first.\n'
} >"$backup_dir/README.txt"
chmod 0600 "$backup_dir/README.txt"

(cd "$backup_dir" && sha256sum pelican.sql.gz panel.env.nonsecret compose.yml pelican-panel.caddy README.txt >SHA256SUMS)
chmod 0600 "$backup_dir/SHA256SUMS"

printf '%s\n' \
  "Backup complete: $backup_dir" \
  "Verify it with: sudo sh -c 'cd $backup_dir && sha256sum --check SHA256SUMS'" \
  'This copy remains on this machine. Copy it to an encrypted external destination before relying on it for disaster recovery.'
