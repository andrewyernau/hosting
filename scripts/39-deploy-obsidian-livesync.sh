#!/usr/bin/env bash
# Deploy one private CouchDB database for Obsidian Self-hosted LiveSync.
# It deliberately has a dry-run default and does not create DNS records.
set -Eeuo pipefail

EXECUTE=false
ROOT=/opt/selfhost/livesync
FQDN=livesync.yernau.com
DATABASE=obsidian
COMPOSE_SOURCE=/home/andrew/hosting/livesync/compose.yml
INI_SOURCE=/home/andrew/hosting/livesync/local.ini
CADDY_SOURCE=/home/andrew/hosting/livesync/Caddyfile.template

usage() {
  cat <<EOF
Usage: sudo $0 [--execute] [--fqdn livesync.yernau.com] [--database obsidian]

Creates a fresh, single-vault CouchDB instance. It refuses to overwrite an
existing deployment. Create the Cloudflare DNS record and verify Full (strict)
before --execute.
EOF
}

while (($#)); do
  case "$1" in
    --execute) EXECUTE=true; shift ;;
    --fqdn) FQDN=${2:?missing value for --fqdn}; shift 2 ;;
    --database) DATABASE=${2:?missing value for --database}; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'Unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ $EUID -eq 0 ]] || { printf 'Run this script with sudo/root.\n' >&2; exit 1; }
for command in docker openssl install sed; do
  command -v "$command" >/dev/null || { printf '%s is required.\n' "$command" >&2; exit 1; }
done
[[ $FQDN =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ && $FQDN == *.yernau.com ]] || {
  printf 'FQDN must be a valid yernau.com hostname: %s\n' "$FQDN" >&2; exit 2;
}
[[ $DATABASE =~ ^[a-z][a-z0-9_$()+/-]*$ ]] || {
  printf 'Database must be a valid lowercase CouchDB database name.\n' >&2; exit 2;
}
for source_file in "$COMPOSE_SOURCE" "$INI_SOURCE" "$CADDY_SOURCE"; do
  [[ -f $source_file ]] || { printf 'Missing source file: %s\n' "$source_file" >&2; exit 1; }
done
docker network inspect selfhost_proxy >/dev/null 2>&1 || {
  printf 'Docker network selfhost_proxy is missing.\n' >&2; exit 1;
}
[[ -f /opt/selfhost/caddy/certs/yernau-origin.crt && -f /opt/selfhost/caddy/certs/yernau-origin.key ]] || {
  printf 'The existing yernau.com Origin CA certificate is required.\n' >&2; exit 1;
}
[[ ! -e $ROOT ]] || { printf 'Refusing to overwrite existing path: %s\n' "$ROOT" >&2; exit 1; }
CADDY_SITE=/opt/selfhost/caddy/sites/livesync.caddy
[[ ! -e $CADDY_SITE ]] || { printf 'Refusing to overwrite existing Caddy site: %s\n' "$CADDY_SITE" >&2; exit 1; }
caddy_container=$(docker ps --filter 'name=^/caddy-caddy-1$' --format '{{.Names}}' | head -n1)
[[ -n $caddy_container ]] || { printf 'Caddy container caddy-caddy-1 was not found.\n' >&2; exit 1; }

if ! $EXECUTE; then
  cat <<EOF
Dry run successful. The deployment will:
  - create $ROOT with a single-node CouchDB database named $DATABASE
  - expose no CouchDB port on the host; central Caddy will publish only https://$FQDN
  - use the existing wildcard yernau.com Origin CA certificate and selfhost_proxy network
  - generate a root-only CouchDB administrator plus a separate user limited to $DATABASE
  - create CouchDB system databases and the empty LiveSync database internally
  - validate and reload Caddy only after CouchDB provisioning succeeds

Before execution, create the Cloudflare record for $FQDN as proxied and ensure
SSL/TLS mode is Full (strict). Run again with --execute to apply.
EOF
  exit 0
fi

couchdb_tag=couchdb:3.5.2.1
docker pull "$couchdb_tag"
couchdb_image=$(docker image inspect --format '{{index .RepoDigests 0}}' "$couchdb_tag")
[[ $couchdb_image == couchdb@sha256:* ]] || { printf 'Could not resolve CouchDB to an immutable digest.\n' >&2; exit 1; }

admin_password=$(openssl rand -base64 36 | tr -d '\n')
sync_password=$(openssl rand -base64 36 | tr -d '\n')
couchdb_secret=$(openssl rand -hex 32)
admin_user=obsidian_admin
sync_user=obsidian_sync

install -d -o root -g root -m 0750 "$ROOT" "$ROOT/config"
# `install -o 5984` expects a host account named "5984" on some coreutils
# versions. CouchDB runs with this numeric UID inside its container, so create
# the directory first and then assign the numeric uid/gid explicitly.
install -d -o root -g root -m 0700 "$ROOT/data"
chown 5984:5984 "$ROOT/data"
install -m 0644 -o root -g root "$COMPOSE_SOURCE" "$ROOT/compose.yml"
install -m 0644 -o root -g root "$INI_SOURCE" "$ROOT/config/livesync.ini"
umask 077
cat > "$ROOT/.env" <<EOF
COUCHDB_IMAGE=$couchdb_image
COUCHDB_ADMIN_USER=$admin_user
COUCHDB_ADMIN_PASSWORD=$admin_password
COUCHDB_SECRET=$couchdb_secret
LIVESYNC_USER=$sync_user
LIVESYNC_PASSWORD=$sync_password
LIVESYNC_DATABASE=$DATABASE
EOF
unset admin_password sync_password couchdb_secret
chmod 0600 "$ROOT/.env"
set -a
# shellcheck disable=SC1090
source "$ROOT/.env"
set +a

docker compose --env-file "$ROOT/.env" -f "$ROOT/compose.yml" config >/dev/null
docker compose --env-file "$ROOT/.env" -f "$ROOT/compose.yml" up -d

wait_for_couchdb() {
  local attempt health_status
  for attempt in {1..30}; do
    health_status=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}unknown{{end}}' livesync-couchdb)
    if [[ $health_status == healthy ]]; then
      return 0
    fi
    sleep 2
  done
  return 1
}

wait_for_couchdb || {
  printf 'CouchDB did not become ready; inspect: docker logs livesync-couchdb\n' >&2; exit 1;
}

# Create the system databases and an empty remote. The first LiveSync client
# initialises its database-version document and synchronisation settings during
# the supported manual onboarding path.
couchdb_put_database() {
  local database_name=$1 status
  status=$(docker exec livesync-couchdb sh -ec \
    'curl -sS -o /dev/null -w "%{http_code}" -u "$COUCHDB_USER:$COUCHDB_PASSWORD" -X PUT "http://127.0.0.1:5984/$1"' \
    sh "$database_name")
  [[ $status == 201 || $status == 412 ]] || {
    printf 'Could not create CouchDB database %s (HTTP %s).\n' "$database_name" "$status" >&2
    return 1
  }
}
for database_name in _users _replicator _global_changes "$DATABASE"; do
  couchdb_put_database "$database_name"
done

# Devices receive only this member account, never the server administrator.
status=$(docker exec -e LIVESYNC_USER -e LIVESYNC_PASSWORD livesync-couchdb sh -ec \
  'curl -sS -o /dev/null -w "%{http_code}" -u "$COUCHDB_USER:$COUCHDB_PASSWORD" -X PUT -H "Content-Type: application/json" "http://127.0.0.1:5984/_users/org.couchdb.user:$LIVESYNC_USER" --data "{\"name\":\"$LIVESYNC_USER\",\"password\":\"$LIVESYNC_PASSWORD\",\"roles\":[],\"type\":\"user\"}"')
[[ $status == 201 || $status == 202 || $status == 409 ]] || {
  printf 'Could not create the LiveSync CouchDB user (HTTP %s).\n' "$status" >&2; exit 1;
}
status=$(docker exec -e LIVESYNC_USER -e DATABASE="$DATABASE" livesync-couchdb sh -ec \
  'curl -sS -o /dev/null -w "%{http_code}" -u "$COUCHDB_USER:$COUCHDB_PASSWORD" -X PUT -H "Content-Type: application/json" "http://127.0.0.1:5984/$DATABASE/_security" --data "{\"admins\":{\"names\":[\"$COUCHDB_USER\"],\"roles\":[]},\"members\":{\"names\":[\"$LIVESYNC_USER\"],\"roles\":[]}}"')
[[ $status == 200 || $status == 201 ]] || {
  printf 'Could not restrict the LiveSync database to its device user (HTTP %s).\n' "$status" >&2; exit 1;
}

install -d -o root -g selfhost -m 2755 /opt/selfhost/caddy/sites
sed "s/__LIVESYNC_FQDN__/$FQDN/g" "$CADDY_SOURCE" > "$CADDY_SITE"
chown root:selfhost "$CADDY_SITE"
chmod 0644 "$CADDY_SITE"
docker exec "$caddy_container" caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
docker exec "$caddy_container" caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile

printf 'LiveSync deployed at https://%s.\n' "$FQDN"
printf 'Retrieve only LIVESYNC_USER, LIVESYNC_PASSWORD and LIVESYNC_DATABASE from %s/.env.\n' "$ROOT"
printf 'Use the existing Windows vault as the first device only after making a full backup.\n'
