#!/usr/bin/env bash
# Create a consistent, root-only local recovery copy of the Calagopus database and
# non-secret deployment configuration. This is staging, not off-host DR.
#
# sudo ./41-backup-calagopus-panel.sh --execute
# sudo ./41-backup-calagopus-panel.sh --destination /mnt/nas/calagopus --execute
set -Eeuo pipefail

deploy=/opt/selfhost/calagopus
destination=/var/backups/calagopus
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
  printf 'Calagopus deployment files not found under %s.\n' "$deploy" >&2
  exit 1
}
command -v docker >/dev/null || { printf 'Docker is required.\n' >&2; exit 1; }
docker inspect --format '{{.State.Running}}' calagopus-db-1 2>/dev/null | grep -qx true || {
  printf 'The Calagopus database container is not running; no backup was made.\n' >&2
  exit 1
}

printf '%s\n' \
  "Destination: $destination" \
  'The backup contains the Calagopus PostgreSQL dump and non-secret configuration.' \
  'It intentionally does NOT copy APP_ENCRYPTION_KEY; keep it in your password manager, the dump is unusable without it.'

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

docker exec calagopus-db-1 sh -ec 'exec pg_dump -U calagopus -d panel --clean --if-exists' \
  | gzip --no-name >"$backup_dir/calagopus.sql.gz"
install -o root -g root -m 0600 /dev/null "$backup_dir/calagopus.env.nonsecret"
grep -Ev '^(APP_ENCRYPTION_KEY|.*(PASSWORD|SECRET|TOKEN))=' "$deploy/.env" >"$backup_dir/calagopus.env.nonsecret"
install -o root -g root -m 0600 "$deploy/compose.yml" "$backup_dir/compose.yml"
install -o root -g root -m 0600 /opt/selfhost/caddy/sites/calagopus-panel.caddy "$backup_dir/calagopus-panel.caddy"
{
  printf 'created_utc=%s\n' "$timestamp"
  printf 'database_dump=calagopus.sql.gz\n'
  printf 'encryption_key_location=external_password_manager\n'
  printf 'restore_note=Restore only into a stopped Calagopus deployment of the same release with the original APP_ENCRYPTION_KEY; test in an isolated environment first.\n'
} >"$backup_dir/README.txt"
chmod 0600 "$backup_dir/README.txt"
(cd "$backup_dir" && sha256sum calagopus.sql.gz calagopus.env.nonsecret compose.yml calagopus-panel.caddy README.txt >SHA256SUMS)
chmod 0600 "$backup_dir/SHA256SUMS"
printf 'Backup written to %s\n' "$backup_dir"
