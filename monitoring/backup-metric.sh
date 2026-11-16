#!/usr/bin/env bash
# ExecStartPost of the backup units: runs only after a successful backup.
set -Eeuo pipefail
dir=$HOME/hosting/monitoring/textfile
tmp=$(mktemp "$dir/.tmp.XXXXXX")
printf 'backup_last_success_timestamp_seconds{backup="%s"} %s\n' "$1" "${2:-$(date +%s)}" > "$tmp"
chmod 644 "$tmp"
mv -f "$tmp" "$dir/backup-$1.prom"
