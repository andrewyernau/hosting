#!/usr/bin/env bash
# Prepares a Linux game node for a Calagopus Wings config (pairing code or generated YAML).
# It does NOT open ports, change firewall rules, create a panel node, or
# start Wings. Execute only on the intended node, for example:
# sudo ./10-bootstrap-game-node.sh \
#   --wings-url 'https://github.com/calagopus/wings/releases/download/release-X.Y.Z/wings-rs-x86_64-linux' \
#   --wings-sha256 '<asset digest shown by: gh api repos/calagopus/wings/releases/latest>' --execute
set -Eeuo pipefail

DATA_DIR=/srv/pelican
BACKUP_DIR=/srv/pelican/backups
WINGS_URL=
WINGS_SHA256=
EXECUTE=false

usage() {
  sed -n '2,11p' "$0"
  exit 2
}

while (( $# )); do
  case "$1" in
    --data-dir) DATA_DIR=${2:?missing value}; shift 2 ;;
    --backup-dir) BACKUP_DIR=${2:?missing value}; shift 2 ;;
    --wings-url) WINGS_URL=${2:?missing value}; shift 2 ;;
    --wings-sha256) WINGS_SHA256=${2:?missing value}; shift 2 ;;
    --execute) EXECUTE=true; shift ;;
    -h|--help) usage ;;
    *) printf 'Unknown argument: %s\n' "$1" >&2; usage ;;
  esac
done

[[ $EUID -eq 0 ]] || { printf 'Run this script with sudo/root.\n' >&2; exit 1; }
[[ -n $WINGS_URL && -n $WINGS_SHA256 ]] || { printf 'An explicit Wings URL and published SHA-256 are required.\n' >&2; exit 1; }
[[ $DATA_DIR = /* && $BACKUP_DIR = /* ]] || { printf 'Data and backup paths must be absolute.\n' >&2; exit 1; }
[[ $DATA_DIR != "$BACKUP_DIR" ]] || { printf 'Data and backup paths must differ.\n' >&2; exit 1; }
command -v docker >/dev/null || { printf 'Docker is not installed; install and validate Docker CE before continuing.\n' >&2; exit 1; }
docker info >/dev/null || { printf 'Docker daemon is unavailable; do not continue.\n' >&2; exit 1; }

data_probe=$DATA_DIR
backup_probe=$BACKUP_DIR
while [[ ! -e $data_probe && $data_probe != / ]]; do data_probe=$(dirname "$data_probe"); done
while [[ ! -e $backup_probe && $backup_probe != / ]]; do backup_probe=$(dirname "$backup_probe"); done
data_fs=$(df -P "$data_probe" | awk 'NR==2 {print $1}')
backup_fs=$(df -P "$backup_probe" | awk 'NR==2 {print $1}')
printf 'Data directory:   %s\nBackup directory: %s\n' "$DATA_DIR" "$BACKUP_DIR"
if [[ -n $data_fs && $data_fs == "$backup_fs" ]]; then
  printf 'WARNING: data and staging backups are on the same filesystem. Configure remote S3/NAS before public service.\n' >&2
fi

if ! $EXECUTE; then
  printf 'Dry run complete. Re-run with --execute after reviewing the paths and checksum.\n'
  exit 0
fi

install -d -o root -g root -m 0750 "$DATA_DIR/volumes" "$BACKUP_DIR" "$DATA_DIR/archives"
install -d -o root -g root -m 0750 /etc/pelican /var/run/wings

tmp_bin=$(mktemp)
trap 'rm -f "$tmp_bin"' EXIT
curl --fail --location --proto '=https' --tlsv1.2 --output "$tmp_bin" "$WINGS_URL"
printf '%s  %s\n' "$WINGS_SHA256" "$tmp_bin" | sha256sum --check --status
install -o root -g root -m 0755 "$tmp_bin" /usr/local/bin/wings

cat >/etc/systemd/system/wings.service <<'UNIT'
[Unit]
Description=Calagopus Wings Daemon
After=docker.service
Requires=docker.service
PartOf=docker.service

[Service]
User=root
WorkingDirectory=/etc/pelican
LimitNOFILE=4096
PIDFile=/var/run/wings/daemon.pid
ExecStart=/usr/local/bin/wings
Restart=on-failure
StartLimitIntervalSec=180
StartLimitBurst=30
RestartSec=5s

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
printf '%s\n' 'Wings installed but not enabled.' \
  'Next: create node-01 in Pelican, copy its generated config to /etc/pelican/config.yml,' \
  "set data_directory to $DATA_DIR/volumes and backup_directory to $BACKUP_DIR," \
  'validate the configuration, then enable Wings with: systemctl enable --now wings'
