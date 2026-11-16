#!/usr/bin/env bash
# Migrate panel.yernau.com from Pelican Panel + Wings to Calagopus Panel + Wings, keeping the
# Yernau Gaming integration and its Cloudflare DNS credentials intact.
#
# Every phase is a dry run unless --execute is given. Run the phases in order:
#
#   sudo ./40-migrate-pelican-to-calagopus.sh --phase deploy --execute
#   sudo ./40-migrate-pelican-to-calagopus.sh --phase import-check --execute
#   sudo ./40-migrate-pelican-to-calagopus.sh --phase import --execute
#   sudo ./40-migrate-pelican-to-calagopus.sh --phase cutover --execute
#   (sign in at https://panel.yernau.com and create the Gaming admin API key)
#   sudo ./40-migrate-pelican-to-calagopus.sh --phase connect-gaming --execute
#
#   sudo ./40-migrate-pelican-to-calagopus.sh --phase rollback --execute
set -Eeuo pipefail

PHASE=
EXECUTE=false
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
HOSTING_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)

PELICAN=/opt/selfhost/pelican
CALAGOPUS=/opt/selfhost/calagopus
CADDY_ROOT=/opt/selfhost/caddy
CADDY_CONTAINER=caddy-caddy-1
GAMING=/opt/selfhost/gaming
STATE=/var/backups/calagopus-migration
WINGS_CONFIG=/etc/pelican/config.yml
WINGS_BIN=/usr/local/bin/wings
NODE_FQDN=node-01.yernau.com
NODE_NAME=node-01

PANEL_SOURCE_IMAGE=ghcr.io/calagopus/panel:1.2.4
POSTGRES_SOURCE_IMAGE=ghcr.io/calagopus/pgautoupgrade:18-alpine
VALKEY_SOURCE_IMAGE=ghcr.io/calagopus/valkey:latest
WINGS_URL=https://github.com/calagopus/wings/releases/download/release-1.2.4/wings-rs-x86_64-linux
WINGS_SHA256=e55895b5b8a93537d8603e1bc4811fc00cfc91107a4f44a69e8939b4a7ddfeb1

usage() { sed -n '2,16p' "$0"; exit 2; }
while (( $# )); do
  case "$1" in
    --phase) PHASE=${2:?missing value}; shift 2 ;;
    --execute) EXECUTE=true; shift ;;
    -h|--help) usage ;;
    *) printf 'Unknown argument: %s\n' "$1" >&2; usage ;;
  esac
done

[[ $EUID -eq 0 ]] || { printf 'Run this script with sudo/root.\n' >&2; exit 1; }
for command in docker curl jq sha256sum openssl systemctl; do
  command -v "$command" >/dev/null || { printf '%s is required.\n' "$command" >&2; exit 1; }
done
docker info >/dev/null || { printf 'Docker daemon is unavailable.\n' >&2; exit 1; }

calagopus_compose() { docker compose --project-directory "$CALAGOPUS" --env-file "$CALAGOPUS/.env" -f "$CALAGOPUS/compose.yml" "$@"; }
pelican_compose() {
  local files=(-f "$PELICAN/compose.yml")
  [[ -f $PELICAN/compose.gaming-network.yml ]] && files+=(-f "$PELICAN/compose.gaming-network.yml")
  docker compose --project-directory "$PELICAN" --env-file "$PELICAN/.env" "${files[@]}" "$@"
}
gaming_compose() { docker compose --env-file "$GAMING/.env" -f "$GAMING/compose.production.yaml" "$@"; }
env_value() { awk -F= -v key="$2" '$1 == key { sub(/^[^=]*=/, ""); value=$0 } END { gsub(/^"|"$/, "", value); print value }' "$1"; }
marker() { [[ -f $STATE/$1.done ]]; }
mark() { date -u +%Y-%m-%dT%H:%M:%SZ >"$STATE/$1.done"; }
require_marker() { marker "$1" || { printf 'Run --phase %s first.\n' "$1" >&2; exit 1; }; }
plan() {
  printf 'Phase %s will:\n' "$PHASE"
  printf '  - %s\n' "$@"
  printf 'Dry run only. Re-run with --execute to perform it.\n'
  exit 0
}
reload_caddy() {
  docker exec "$CADDY_CONTAINER" caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null &&
    docker exec "$CADDY_CONTAINER" caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile
}
wait_for_panel() {
  for _ in $(seq 1 60); do
    # Ask from a container on the panel's internal network: the heavy image ships no wget/curl.
    if docker run --rm --network calagopus_backend oven/bun:1.3.8-alpine \
      bun -e 'process.exit((await fetch("http://web:8000/").catch(() => null))?.ok ? 0 : 1)' 2>/dev/null; then return 0; fi
    sleep 2
  done
  printf 'Calagopus Panel did not answer on port 8000. Inspect: docker logs calagopus-web-1\n' >&2
  return 1
}

# Build the importer's view of Pelican inside the Calagopus container only: secrets are piped
# through stdin, never written to the host or passed as process arguments.
with_pelican_source() {
  local pelican_env=$PELICAN/data/.env
  [[ -r $pelican_env ]] || { printf 'Missing %s.\n' "$pelican_env" >&2; exit 1; }
  docker inspect --format '{{.State.Running}}' pelican-database-1 2>/dev/null | grep -qx true || {
    printf 'The Pelican database must be running for the import.\n' >&2; exit 1;
  }
  docker network connect pelican_backend calagopus-web-1 2>/dev/null || true
  {
    printf 'APP_URL=%s\n' "$(env_value "$pelican_env" APP_URL)"
    printf 'APP_KEY=%s\n' "$(env_value "$pelican_env" APP_KEY)"
    printf 'DB_CONNECTION=%s\n' "$(env_value "$pelican_env" DB_CONNECTION)"
    printf 'DB_HOST=database\n'
    printf 'DB_PORT=%s\n' "$(env_value "$pelican_env" DB_PORT)"
    printf 'DB_DATABASE=%s\n' "$(env_value "$pelican_env" DB_DATABASE)"
    printf 'DB_USERNAME=%s\n' "$(env_value "$pelican_env" DB_USERNAME)"
    printf 'DB_PASSWORD=%s\n' "$(env_value "$pelican_env" DB_PASSWORD)"
    # Panel name and SMTP settings are carried over by the importer when present.
    grep -E '^(APP_NAME|MAIL_(MAILER|HOST|PORT|USERNAME|PASSWORD|SCHEME|ENCRYPTION|FROM_ADDRESS|FROM_NAME))=' "$pelican_env" || true
  } | docker exec -i calagopus-web-1 sh -c 'umask 077; cat >/tmp/pelican.env'
  local status=0
  "$@" || status=$?
  docker exec calagopus-web-1 rm -f /tmp/pelican.env
  docker network disconnect pelican_backend calagopus-web-1 2>/dev/null || true
  return "$status"
}

phase_deploy() {
  [[ -r $PELICAN/compose.yml && -r $PELICAN/.env ]] || { printf 'Pelican deployment not found under %s.\n' "$PELICAN" >&2; exit 1; }
  [[ -r $WINGS_CONFIG && -x $WINGS_BIN ]] || { printf 'Pelican Wings config or binary is missing.\n' >&2; exit 1; }
  [[ ! -e $CALAGOPUS/compose.yml && ! -e $CALAGOPUS/.env ]] || { printf '%s already exists; refusing to overwrite it.\n' "$CALAGOPUS" >&2; exit 1; }
  local caddy_ip node_ip
  caddy_ip=$(docker inspect "$CADDY_CONTAINER" --format '{{with index .NetworkSettings.Networks "selfhost_proxy"}}{{.IPAddress}}{{end}}')
  node_ip=$(docker network inspect selfhost_proxy --format '{{(index .IPAM.Config 0).Gateway}}')
  [[ $caddy_ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ && $node_ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || {
    printf 'Could not determine Caddy or selfhost_proxy gateway addresses.\n' >&2; exit 1;
  }
  $EXECUTE || plan \
    "back up the Pelican database (08-backup-pelican-panel.sh), Wings config/binary and Pelican Caddy site to $STATE" \
    "create $CALAGOPUS with Calagopus Panel 1.2.4, PostgreSQL and Valkey pinned to image digests" \
    "attach the panel to selfhost_proxy (calagopus-panel) and gaming_panel_api (calagopus-panel-api), no host ports" \
    "map $NODE_FQDN to $node_ip inside the panel and trust Caddy at $caddy_ip" \
    'leave Pelican, Wings, Caddy and Gaming untouched and serving traffic'

  install -d -o root -g root -m 0700 "$STATE"
  "$SCRIPT_DIR/08-backup-pelican-panel.sh" --destination "$STATE/pelican-panel" --execute
  install -o root -g root -m 0600 "$WINGS_CONFIG" "$STATE/wings-config.yml"
  install -o root -g root -m 0700 "$WINGS_BIN" "$STATE/wings-pelican.bin"
  install -o root -g root -m 0600 /etc/systemd/system/wings.service "$STATE/wings.service"

  docker network inspect gaming_panel_api >/dev/null 2>&1 || docker network create --internal gaming_panel_api >/dev/null
  local image pinned=()
  for image in "$PANEL_SOURCE_IMAGE" "$POSTGRES_SOURCE_IMAGE" "$VALKEY_SOURCE_IMAGE"; do
    docker pull -q "$image" >/dev/null
    pinned+=("$(docker image inspect "$image" --format '{{index .RepoDigests 0}}')")
  done
  [[ ${pinned[0]} == ghcr.io/calagopus/panel@sha256:* && ${pinned[1]} == ghcr.io/calagopus/pgautoupgrade@sha256:* && ${pinned[2]} == ghcr.io/calagopus/valkey@sha256:* ]] || {
    printf 'Could not resolve Calagopus images to immutable digests.\n' >&2; exit 1;
  }

  install -d -o root -g root -m 0750 "$CALAGOPUS"
  install -d -o root -g root -m 0700 "$CALAGOPUS/data" "$CALAGOPUS/logs" "$CALAGOPUS/postgres" "$CALAGOPUS/cache"
  install -o root -g root -m 0640 "$HOSTING_DIR/calagopus/compose.yml.template" "$CALAGOPUS/compose.yml"
  (
    umask 077
    cat >"$CALAGOPUS/.env" <<EOF
PANEL_IMAGE=${pinned[0]}
POSTGRES_IMAGE=${pinned[1]}
VALKEY_IMAGE=${pinned[2]}
POSTGRES_PASSWORD=$(openssl rand -hex 24)
APP_ENCRYPTION_KEY=$(openssl rand -hex 32)
CADDY_PROXY_IP=$caddy_ip
NODE_01_PRIVATE_IP=$node_ip
EOF
  )
  calagopus_compose config -q
  calagopus_compose up -d
  wait_for_panel
  mark deploy
  printf '%s\n' \
    'Calagopus is running internally. Do NOT open its setup (OOBE) screen: the import needs an empty database.' \
    "Save APP_ENCRYPTION_KEY from $CALAGOPUS/.env in your password manager; losing it makes stored secrets unreadable." \
    'Next: --phase import-check'
}

phase_import_check() {
  require_marker deploy
  $EXECUTE || plan \
    'temporarily connect the Calagopus container to the Pelican database network' \
    "run the Calagopus Pelican importer with --dry-run --on-invalid=fix and save the report to $STATE" \
    'write nothing to either panel'
  local report=/tmp/pelican-import-check.json
  with_pelican_source docker exec calagopus-web-1 calagopus-panel import pelican --environment /tmp/pelican.env \
    --dry-run --on-invalid=fix --report "$report"
  docker cp "calagopus-web-1:$report" "$STATE/import-check-report.json" >/dev/null
  chmod 0600 "$STATE/import-check-report.json"
  mark import-check
  printf 'Review the planned repairs (for example usernames Calagopus does not accept) in %s.\nNext: --phase import\n' "$STATE/import-check-report.json"
}

phase_import() {
  require_marker import-check
  ! marker import || { printf 'The import already completed; do not run it twice.\n' >&2; exit 1; }
  $EXECUTE || plan \
    'import users, nodes (with their Wings token), allocations, eggs and servers into Calagopus, applying the reviewed repairs' \
    'preserve the UUIDs of nodes, eggs and servers so Wings and Gaming orders keep matching' \
    'restart Calagopus; Pelican keeps serving panel.yernau.com until --phase cutover'
  local report=/tmp/pelican-import.json
  with_pelican_source docker exec calagopus-web-1 calagopus-panel import pelican --environment /tmp/pelican.env \
    --on-invalid=fix --yes --report "$report"
  docker cp "calagopus-web-1:$report" "$STATE/import-report.json" >/dev/null
  chmod 0600 "$STATE/import-report.json"
  calagopus_compose down
  calagopus_compose up -d
  wait_for_panel
  mark import
  printf 'Import complete. Next: --phase cutover\n'
}

phase_cutover() {
  require_marker import
  [[ -r $CADDY_ROOT/sites/pelican-panel.caddy ]] || { printf 'The Pelican Caddy site is not installed.\n' >&2; exit 1; }
  $EXECUTE || plan \
    'stop the Pelican Panel container (its database keeps running for rollback)' \
    'replace the panel.yernau.com Caddy site so it proxies to Calagopus' \
    "install Calagopus Wings 1.2.4 (sha256 $WINGS_SHA256) over $WINGS_BIN" \
    "restart Wings with its existing $WINGS_CONFIG: same node token, data in /srv/pelican, network pelican_nw" \
    'reinstall the game-port firewall so it follows the Wings bridge name'

  local tmp_bin
  tmp_bin=$(mktemp)
  trap 'rm -f "$tmp_bin"' RETURN
  curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 --output "$tmp_bin" "$WINGS_URL"
  printf '%s  %s\n' "$WINGS_SHA256" "$tmp_bin" | sha256sum --check --status || { printf 'Wings checksum mismatch; nothing changed.\n' >&2; exit 1; }
  chmod 0755 "$tmp_bin"
  "$tmp_bin" version >/dev/null 2>&1 || "$tmp_bin" --version >/dev/null 2>&1 || { printf 'The downloaded Wings binary does not run on this host.\n' >&2; exit 1; }

  pelican_compose stop panel
  install -o root -g root -m 0644 "$HOSTING_DIR/caddy/calagopus-panel.caddy.template" "$CADDY_ROOT/sites/calagopus-panel.caddy"
  mv "$CADDY_ROOT/sites/pelican-panel.caddy" "$STATE/pelican-panel.caddy"
  if ! reload_caddy; then
    mv "$STATE/pelican-panel.caddy" "$CADDY_ROOT/sites/pelican-panel.caddy"
    rm -f "$CADDY_ROOT/sites/calagopus-panel.caddy"
    pelican_compose start panel
    reload_caddy || true
    printf 'Caddy rejected the Calagopus site; Pelican was restored.\n' >&2
    exit 1
  fi

  systemctl stop wings
  install -o root -g root -m 0755 "$tmp_bin" "$WINGS_BIN"
  sed -i 's/^Description=Pelican Wings Daemon$/Description=Calagopus Wings Daemon/' /etc/systemd/system/wings.service
  install -o root -g root -m 0750 "$HOSTING_DIR/firewall/pelican-game-firewall" /usr/local/sbin/pelican-game-firewall
  systemctl daemon-reload
  systemctl restart pelican-game-firewall.service
  systemctl start wings
  sleep 5
  systemctl is-active --quiet wings || {
    journalctl -u wings -n 40 --no-pager >&2
    printf 'Calagopus Wings failed to start. Run --phase rollback --execute to restore Pelican.\n' >&2
    exit 1
  }
  mark cutover

  local panel_status wings_status
  panel_status=$(curl --silent --insecure --resolve panel.yernau.com:443:127.0.0.1 --output /dev/null --write-out '%{http_code}' https://panel.yernau.com/ || true)
  wings_status=$(curl --silent --resolve "$NODE_FQDN:8443:127.0.0.1" --output /dev/null --write-out '%{http_code}' "https://$NODE_FQDN:8443/api/system" || true)
  printf 'panel.yernau.com via local Caddy: HTTP %s; Wings API (unauthenticated): HTTP %s (401 expected).\n' "$panel_status" "$wings_status"
  journalctl -u wings -n 15 --no-pager
  printf '%s\n' \
    'Pelican TOTP secrets (80 bits) are rejected by Calagopus (minimum 128 bits): for each user with 2FA run' \
    '  docker exec calagopus-web-1 calagopus-panel users disable-2fa --user EMAIL' \
    'and have them enroll 2FA again from their account page.' \
    'Next, in https://panel.yernau.com: sign in with your Pelican credentials, confirm node-01 is online,' \
    'then create an admin API key for Yernau Gaming with these admin permissions:' \
    '  users.create users.read users.update servers.create servers.read servers.update servers.delete' \
    '  nodes.read nodes.allocations nests.create nests.read eggs.create eggs.read eggs.update' \
    "  and restrict its allowed IPs to the gaming_panel_api subnet: $(docker network inspect gaming_panel_api --format '{{(index .IPAM.Config 0).Subnet}}')" \
    'Then run: --phase connect-gaming'
}

phase_connect_gaming() {
  require_marker cutover
  [[ -r $GAMING/.env && -r $GAMING/compose.production.yaml ]] || { printf 'Yernau Gaming deployment not found.\n' >&2; exit 1; }
  $EXECUTE || plan \
    'ask for the Calagopus API key (hidden input) and resolve the node-01 UUID with it' \
    "back up the Gaming .env, compose file, release link and a PostgreSQL dump to $STATE" \
    'replace only the PELICAN_* settings in the Gaming .env with CALAGOPUS_*; Cloudflare, Stripe and SMTP values are kept as-is' \
    'deploy the current Gaming source (33-deploy-gaming.sh --execute), which applies migration 0001' \
    'resynchronize managed eggs and allocations and re-link existing users and orders (setup-panel.ts)'

  local api_key nodes node_uuid cloudflare_before cloudflare_after stage
  read -r -s -p 'Calagopus API key for Yernau Gaming (input hidden): ' api_key; printf '\n'
  [[ -n $api_key && $api_key != *[[:space:]]* ]] || { printf 'Empty or malformed API key.\n' >&2; exit 1; }
  # Query from gaming_panel_api, the same network and source range Gaming uses, so a key restricted
  # to that subnet is accepted. The key travels over stdin, never as a process argument.
  nodes=$(printf '%s' "$api_key" | docker run --rm -i --network gaming_panel_api oven/bun:1.3.8-alpine bun -e '
    const key = (await Bun.stdin.text()).trim();
    const response = await fetch("http://calagopus-panel-api:8000/api/admin/nodes?page=1&per_page=100", {headers: {Authorization: `Bearer ${key}`, Accept: "application/json"}});
    if (!response.ok) { console.error(`HTTP ${response.status}`); process.exit(1); }
    console.log(await response.text());') || { printf 'The API key was rejected, lacks nodes.read, or its allowed IPs exclude gaming_panel_api.\n' >&2; exit 1; }
  node_uuid=$(jq -r --arg name "$NODE_NAME" '.nodes.data[] | select(.name == $name) | .uuid' <<<"$nodes")
  [[ $node_uuid =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || { printf 'Node %s not found in Calagopus.\n' "$NODE_NAME" >&2; exit 1; }

  local backup="$STATE/gaming"
  install -d -o root -g root -m 0700 "$backup"
  install -o root -g root -m 0600 "$GAMING/.env" "$backup/env"
  install -o root -g root -m 0600 "$GAMING/compose.production.yaml" "$backup/compose.production.yaml"
  readlink -f "$GAMING/source" >"$backup/release"
  gaming_compose exec -T postgres sh -ec 'pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" --clean --if-exists' | gzip --no-name >"$backup/postgres.sql.gz"
  chmod 0600 "$backup/postgres.sql.gz"

  cloudflare_before=$(grep -E '^(CLOUDFLARE_|GAME_DNS_MODE=|GAME_ORIGIN_IPV4=)' "$GAMING/.env" | sha256sum)
  stage=$(mktemp "$GAMING/.env.XXXXXX")
  {
    grep -Ev '^PELICAN_' "$GAMING/.env"
    printf 'CALAGOPUS_MODE=%s\n' "$(env_value "$backup/env" PELICAN_MODE)"
    printf 'CALAGOPUS_BASE_URL=http://calagopus-panel-api:8000\n'
    printf 'CALAGOPUS_API_KEY=%s\n' "$api_key"
    printf 'CALAGOPUS_NODE_UUID=%s\n' "$node_uuid"
    printf 'CALAGOPUS_ALLOCATION_IP=%s\n' "$(env_value "$backup/env" PELICAN_ALLOCATION_IP)"
    printf 'CALAGOPUS_DOCKER_IMAGE=%s\n' "$(env_value "$backup/env" PELICAN_DOCKER_IMAGE)"
  } >"$stage"
  unset api_key
  chown root:selfhost "$stage"
  chmod 0640 "$stage"
  mv -f "$stage" "$GAMING/.env"
  cloudflare_after=$(grep -E '^(CLOUDFLARE_|GAME_DNS_MODE=|GAME_ORIGIN_IPV4=)' "$GAMING/.env" | sha256sum)
  [[ $cloudflare_before == "$cloudflare_after" ]] || { printf 'Cloudflare settings changed unexpectedly; restore %s/env.\n' "$backup" >&2; exit 1; }
  printf 'Gaming .env updated; Cloudflare DNS settings are byte-for-byte unchanged.\n'

  "$SCRIPT_DIR/33-deploy-gaming.sh" --execute
  gaming_compose exec -T worker bun src/cli/setup-panel.ts
  mark connect-gaming
  printf 'Yernau Gaming now provisions through Calagopus. Pelican data remains under %s until you remove it.\n' "$PELICAN"
}

phase_rollback() {
  marker deploy || { printf 'Nothing to roll back.\n' >&2; exit 1; }
  $EXECUTE || plan \
    'restore the Pelican Wings binary and unit, and restart Wings' \
    'restore the Pelican Caddy site and start the Pelican Panel container' \
    'stop Calagopus (its data under /opt/selfhost/calagopus is kept)' \
    "if Gaming was connected: restore its .env, compose file, previous release and PostgreSQL dump from $STATE/gaming"

  if marker cutover; then
    systemctl stop wings
    install -o root -g root -m 0755 "$STATE/wings-pelican.bin" "$WINGS_BIN"
    install -o root -g root -m 0644 "$STATE/wings.service" /etc/systemd/system/wings.service
    install -o root -g root -m 0600 "$STATE/wings-config.yml" "$WINGS_CONFIG"
    systemctl daemon-reload
    systemctl start wings
    [[ -f $STATE/pelican-panel.caddy ]] && mv "$STATE/pelican-panel.caddy" "$CADDY_ROOT/sites/pelican-panel.caddy"
    rm -f "$CADDY_ROOT/sites/calagopus-panel.caddy"
    pelican_compose start panel
    reload_caddy
  fi
  if marker connect-gaming; then
    install -o root -g selfhost -m 0640 "$STATE/gaming/env" "$GAMING/.env"
    install -o root -g selfhost -m 0640 "$STATE/gaming/compose.production.yaml" "$GAMING/compose.production.yaml"
    ln -sfn "$(cat "$STATE/gaming/release")" "$GAMING/source"
    gaming_compose stop api worker web
    gunzip -c "$STATE/gaming/postgres.sql.gz" | gaming_compose exec -T postgres sh -ec 'psql -q -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB"'
    gaming_compose up -d --build
  fi
  calagopus_compose stop
  rm -f "$STATE"/{cutover,connect-gaming}.done
  printf 'Pelican restored. Calagopus is stopped; its import is kept under %s.\n' "$CALAGOPUS"
}

case "$PHASE" in
  deploy) phase_deploy ;;
  import-check) phase_import_check ;;
  import) phase_import ;;
  cutover) phase_cutover ;;
  connect-gaming) phase_connect_gaming ;;
  rollback) phase_rollback ;;
  *) usage ;;
esac
