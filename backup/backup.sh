#!/usr/bin/env bash
# Daily encrypted backup of the miniPC to the VPS (restic over an SSH tunnel, append-only server).
# See README.md. Usage: backup.sh run | snapshots | check | restic <args...> | archive <tag> <volume...>
set -Eeuo pipefail

VPS_HOST=${VPS_HOST:-vps-proxy}
TUNNEL_PORT=18000
PASS_FILE=$HOME/.config/restic/minipc.pass
SSH_KEY=$HOME/.ssh/backup_vps_ed25519
STATE=$HOME/.local/state/backup
STAGING=$STATE/staging
IMAGE=restic/restic:0.18.1
ALERT_TO=contact@csmak.com
SMTP_PASS_FILE=$HOME/hosting/mail/secrets/no-reply.pass

PG_CONTAINERS=(nutria-postgres-1 comidas-yernau-postgres-1 aj-gambito-pt-postgres-1
  yernau-gaming-postgres-1 portfolio-postgres-1 calagopus-db-1 crm-crm-db-1)
VOLUMES=(nutria_miniodata aj-gambito-pt_minio_data comidas-yernau_s3_data mail_etc
  mail_bulwark_settings mail_bulwark_admin mail_bulwark_state mail_bulwark_cs_settings vaultwarden_ts_state orbit_ts_state
  crm_server_data)
# Stalwart keeps RocksDB files: it is paused only while they are tarred, which takes seconds.
MAIL_CONTAINER=mail-stalwart-1
MAIL_VOLUME=mail_data
# Orbit keeps a live SQLite file: same treatment.
ORBIT_CONTAINER=orbit-orbit-1
ORBIT_VOLUME=orbit_data

tunnel_pid=''
close_tunnel() { [[ -n $tunnel_pid ]] && kill "$tunnel_pid" 2>/dev/null || true; tunnel_pid=''; }
open_tunnel() {
  ssh -i "$SSH_KEY" -l restic-tunnel -o IdentitiesOnly=yes -o BatchMode=yes -o ExitOnForwardFailure=yes \
    -o ServerAliveInterval=30 -N -L "127.0.0.1:$TUNNEL_PORT:127.0.0.1:8000" "$VPS_HOST" &
  tunnel_pid=$!
  for _ in {1..20}; do (exec 3<>"/dev/tcp/127.0.0.1/$TUNNEL_PORT") 2>/dev/null && return 0; sleep 1; done
  echo 'tunnel did not come up' >&2; return 1
}
restic_run() {  # extra docker args until "--", then restic args
  local docker_args=()
  while [[ $1 != -- ]]; do docker_args+=("$1"); shift; done; shift
  docker run --rm --network host --hostname minipc \
    -e RESTIC_REPOSITORY="rest:http://127.0.0.1:$TUNNEL_PORT/minipc" -e RESTIC_PASSWORD_FILE=/run/restic.pass \
    -v "$PASS_FILE:/run/restic.pass:ro" -v restic_cache:/root/.cache/restic "${docker_args[@]}" "$IMAGE" "$@"
}
alert() {
  local msg=$1 pw
  [[ -r $SMTP_PASS_FILE ]] || return 0
  pw=$(<"$SMTP_PASS_FILE")
  printf 'From: no-reply@csmak.com\r\nTo: %s\r\nSubject: [backup miniPC] FALLO\r\nDate: %s\r\n\r\n%s\r\n' \
      "$ALERT_TO" "$(date -R)" "$msg" |
    curl -sS --max-time 30 --url smtps://mail.csmak.com:465 --mail-from no-reply@csmak.com --mail-rcpt "$ALERT_TO" \
      --user "no-reply@csmak.com:$pw" -T - >/dev/null || echo 'alert mail failed' >&2
}
cleanup() { docker unpause "$MAIL_CONTAINER" "$ORBIT_CONTAINER" >/dev/null 2>&1 || true; close_tunnel; rm -rf "$STAGING"; }

dump_all() {
  rm -rf "$STAGING"; (umask 077; mkdir -p "$STAGING/pg")
  local c
  for c in "${PG_CONTAINERS[@]}"; do
    docker exec "$c" sh -c 'pg_dumpall -U "$POSTGRES_USER"' >"$STAGING/pg/$c.sql"
    tail -n 5 "$STAGING/pg/$c.sql" | grep -q 'PostgreSQL database cluster dump complete' || { echo "incomplete dump: $c" >&2; return 1; }
  done
  docker pause "$MAIL_CONTAINER" >/dev/null
  docker run --rm -v "$MAIL_VOLUME:/v:ro" alpine:3 tar -C /v -cf - . >"$STAGING/$MAIL_VOLUME.tar"
  docker unpause "$MAIL_CONTAINER" >/dev/null
  docker pause "$ORBIT_CONTAINER" >/dev/null
  docker run --rm -v "$ORBIT_VOLUME:/v:ro" alpine:3 tar -C /v -cf - . >"$STAGING/$ORBIT_VOLUME.tar"
  docker unpause "$ORBIT_CONTAINER" >/dev/null
}
do_backup() {
  local args=(-v /opt/selfhost:/data/opt-selfhost:ro -v /etc/wings:/data/wings-etc:ro -v /srv/wings:/data/wings-srv:ro
    -v "$HOME/hosting:/data/hosting:ro" -v "$HOME/src:/data/src:ro" -v "$HOME/backups:/data/backups:ro"
    -v "$STAGING:/data/staging:ro")
  local v
  for v in "${VOLUMES[@]}"; do args+=(-v "$v:/data/volumes/$v:ro"); done
  restic_run "${args[@]}" -- backup --host minipc --tag daily --one-file-system=false \
    --exclude node_modules --exclude .venv --exclude target --exclude dist --exclude .next --exclude .turbo \
    --exclude .expo --exclude __pycache__ \
    --exclude /data/opt-selfhost/gaming/postgres-data --exclude /data/opt-selfhost/portfolio/postgres-data \
    --exclude /data/opt-selfhost/calagopus/postgres \
    /data
}

case ${1:-} in
  run)
    trap 'rc=$?; [[ $rc -eq 0 ]] || alert "backup.sh salio con codigo $rc en $(date -Is). journalctl --user -u minipc-backup"; cleanup; exit $rc' EXIT
    open_tunnel
    dump_all
    do_backup
    restic_run -- check --read-data-subset=2%
    date -Is >"$STATE/last-ok"
    ;;
  snapshots|check) trap cleanup EXIT; open_tunnel; restic_run -- "$1" ;;
  restic) shift; trap cleanup EXIT; open_tunnel; restic_run -- "$@" ;;
  archive)  # one-off copy of volumes about to be removed: archive <tag> <volume...>
    tag=$2; shift 2; trap cleanup EXIT; open_tunnel
    args=(); for v in "$@"; do args+=(-v "$v:/archive/$v:ro"); done
    restic_run "${args[@]}" -- backup --host minipc --tag "$tag" /archive
    ;;
  init) trap cleanup EXIT; open_tunnel; restic_run -- init ;;
  *) echo "usage: $0 run|snapshots|check|restic <args>|archive <tag> <volume...>|init" >&2; exit 2 ;;
esac
