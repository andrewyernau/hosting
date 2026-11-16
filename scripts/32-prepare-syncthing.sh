#!/usr/bin/env bash
set -Eeuo pipefail
EXECUTE=false; USER_NAME=andrew; SYNC_ROOT=/home/andrew/sync
while (($#)); do case "$1" in --execute) EXECUTE=true; shift;; -h|--help) echo "Usage: sudo $0 [--execute]"; exit 0;; *) echo "Unknown argument: $1" >&2; exit 2;; esac; done
[[ $EUID -eq 0 ]] || { echo 'Run with sudo/root.' >&2; exit 1; }
id "$USER_NAME" >/dev/null || exit 1
command -v tailscale >/dev/null || { echo 'Tailscale is required first.' >&2; exit 1; }
tailscale_ip=$(tailscale ip -4 | head -n1); [[ $tailscale_ip =~ ^100\. ]] || exit 1
if ! $EXECUTE; then
  echo "Dry run: install Syncthing, create $SYNC_ROOT/{code,work-setenova}, add .stignore, enable user service, keep GUI on 127.0.0.1:8384, no public ports. Run --execute to apply."
  exit 0
fi
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y syncthing
install -d -o "$USER_NAME" -g "$USER_NAME" -m 0750 "$SYNC_ROOT/code" "$SYNC_ROOT/work-setenova"
for dir in "$SYNC_ROOT/code" "$SYNC_ROOT/work-setenova"; do
  if [[ ! -e "$dir/.stignore" ]]; then
    printf '%s\n' 'node_modules' '.venv' 'venv' 'env' '__pycache__' '*.pyc' 'dist' 'build' '.next' '.nuxt' '.cache' 'coverage' '.parcel-cache' '.turbo' '.env' '.env.*' '!.env.example' '*.pem' '*.key' '*.p12' '*.log' '.DS_Store' 'Thumbs.db' '.idea' > "$dir/.stignore"
    chown "$USER_NAME:$USER_NAME" "$dir/.stignore"; chmod 0640 "$dir/.stignore"
  fi
done
systemctl enable --now "syncthing@${USER_NAME}.service"
echo "Syncthing preparado. GUI http://127.0.0.1:8384; Tailscale IPv4: $tailscale_ip"
echo "Carpetas: $SYNC_ROOT/code y $SYNC_ROOT/work-setenova"
