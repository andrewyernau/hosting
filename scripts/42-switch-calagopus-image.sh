#!/usr/bin/env bash
# Switch the Calagopus Panel between the regular image and the heavy image required to install
# extensions, keeping the same database, volumes and APP_ENCRYPTION_KEY (which lives in .env and
# is never rewritten). A database backup is taken first with 41-backup-calagopus-panel.sh.
#
# sudo ./42-switch-calagopus-image.sh --variant heavy             # dry run
# sudo ./42-switch-calagopus-image.sh --variant heavy --execute
# sudo ./42-switch-calagopus-image.sh --variant regular --execute # revert
set -Eeuo pipefail

VARIANT=
EXECUTE=false
VERSION=1.2.4
SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
HOSTING_DIR=$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd)
DEPLOY=/opt/selfhost/calagopus

usage() { sed -n '2,9p' "$0"; exit 2; }
while (( $# )); do
  case "$1" in
    --variant) VARIANT=${2:?missing value}; shift 2 ;;
    --version) VERSION=${2:?missing value}; shift 2 ;;
    --execute) EXECUTE=true; shift ;;
    -h|--help) usage ;;
    *) printf 'Unknown argument: %s\n' "$1" >&2; usage ;;
  esac
done

[[ $EUID -eq 0 ]] || { printf 'Run this script with sudo/root.\n' >&2; exit 1; }
case "$VARIANT" in
  heavy) source_image=ghcr.io/calagopus/panel:$VERSION-heavy ;;
  regular) source_image=ghcr.io/calagopus/panel:$VERSION ;;
  *) usage ;;
esac
[[ $VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { printf 'Invalid version: %s\n' "$VERSION" >&2; exit 1; }
[[ -r $DEPLOY/compose.yml && -r $DEPLOY/.env ]] || { printf 'Calagopus deployment not found under %s.\n' "$DEPLOY" >&2; exit 1; }
grep -q '^APP_ENCRYPTION_KEY=.\{32,\}$' "$DEPLOY/.env" || { printf 'APP_ENCRYPTION_KEY is missing from %s; refusing to continue.\n' "$DEPLOY/.env" >&2; exit 1; }

compose() { docker compose --project-directory "$DEPLOY" --env-file "$DEPLOY/.env" -f "$DEPLOY/compose.yml" "$@"; }
current=$(awk -F= '$1 == "PANEL_IMAGE" { sub(/^[^=]*=/, ""); print }' "$DEPLOY/.env")

if ! $EXECUTE; then
  cat <<EOF
Dry run. Switching the Calagopus Panel to the $VARIANT image will:
  - back up the panel database with 41-backup-calagopus-panel.sh
  - pull $source_image and pin it by digest (current: $current)
  - install the compose template with the heavy build volumes under $DEPLOY/build
  - change only PANEL_IMAGE in $DEPLOY/.env; APP_ENCRYPTION_KEY and all secrets stay as they are
  - recreate only the web container (brief panel downtime; Wings and game servers keep running)
Re-run with --execute to apply it.
EOF
  exit 0
fi

"$SCRIPT_DIR/41-backup-calagopus-panel.sh" --execute
docker pull -q "$source_image" >/dev/null
pinned=$(docker image inspect "$source_image" --format '{{index .RepoDigests 0}}')
[[ $pinned == ghcr.io/calagopus/panel@sha256:* ]] || { printf 'Could not pin %s to a digest.\n' "$source_image" >&2; exit 1; }

stamp=$(date -u +%Y%m%dT%H%M%SZ)
cp -a "$DEPLOY/.env" "$DEPLOY/.env.before-image-switch.$stamp"
cp -a "$DEPLOY/compose.yml" "$DEPLOY/compose.yml.before-image-switch.$stamp"
install -d -o root -g root -m 0700 "$DEPLOY/build" "$DEPLOY/build/binaries" "$DEPLOY/build/translations" "$DEPLOY/build/extensions" "$DEPLOY/build/extension-migrations"
install -o root -g root -m 0640 "$HOSTING_DIR/calagopus/compose.yml.template" "$DEPLOY/compose.yml"
sed -i "s|^PANEL_IMAGE=.*|PANEL_IMAGE=$pinned|" "$DEPLOY/.env"

restore() {
  printf 'Restoring the previous image and compose file.\n' >&2
  cp -a "$DEPLOY/.env.before-image-switch.$stamp" "$DEPLOY/.env"
  cp -a "$DEPLOY/compose.yml.before-image-switch.$stamp" "$DEPLOY/compose.yml"
  compose up -d web || true
}
if ! compose config -q || ! compose up -d web; then restore; exit 1; fi

# Probe through central Caddy from the host: the heavy image ships no wget/curl, and Caddy answers
# 502 until the panel listens. Installed extensions may compile on startup, so allow several minutes.
panel_status() { curl --silent --insecure --max-time 5 --resolve panel.kubo.csmak.com:443:192.168.0.111 --output /dev/null --write-out '%{http_code}' https://panel.kubo.csmak.com/ || true; }
for _ in $(seq 1 150); do
  if [[ $(panel_status) == 200 ]]; then
    printf 'Calagopus Panel is running on %s (%s).\n' "$source_image" "$pinned"
    printf 'Previous .env and compose kept as %s.*.before-image-switch.%s\n' "$DEPLOY" "$stamp"
    exit 0
  fi
  sleep 2
done
docker logs --tail 40 calagopus-web-1 >&2
restore
exit 1
