#!/usr/bin/env bash
# Rename what Calagopus Wings inherited from Pelican: /etc/pelican, /srv/pelican, /var/log/pelican, user pelican,
# network pelican_nw and the game firewall unit, script and chain. Server files are moved, not copied.
# Game containers are removed and Wings recreates them on the next start; start the servers from the panel.
#
#   sudo ./47-rename-wings-from-pelican.sh             checks only
#   sudo ./47-rename-wings-from-pelican.sh --execute
#   sudo ./47-rename-wings-from-pelican.sh --rollback  back to the old names, using the saved copy
set -Eeuo pipefail

MODE=${1:-check}
[[ $# -le 1 && $MODE =~ ^(check|--execute|--rollback)$ ]] || { printf 'Usage: sudo %s [--execute|--rollback]\n' "$0" >&2; exit 2; }
[[ $EUID -eq 0 ]] || { printf 'Run with sudo/root.\n' >&2; exit 1; }

HERE=$(cd "$(dirname "$0")" && pwd)
FIREWALL_SRC=$HERE/../firewall
SD=/etc/systemd/system
SNAP=/var/backups/wings-rename.tar
OLD_ETC=/etc/pelican NEW_ETC=/etc/wings OLD_SRV=/srv/pelican NEW_SRV=/srv/wings
OLD_LOG=/var/log/pelican NEW_LOG=/var/log/wings
OLD_NET=pelican_nw NEW_NET=wings_nw
OLD_UNIT=pelican-game-firewall NEW_UNIT=wings-game-firewall
OLD_CHAIN=PELICAN-GAME-INGRESS NEW_CHAIN=WINGS-GAME-INGRESS
UUID_RE='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'

say() { printf '== %s\n' "$*"; }
game_containers() { docker ps -a --filter "network=$1" --format '{{.Names}}'; }
assert_only_game_containers() {
  local c
  for c in $(game_containers "$1"); do
    [[ $c =~ $UUID_RE ]] || { printf 'Unexpected container on %s: %s\n' "$1" "$c" >&2; exit 1; }
  done
}
drop_network() {  # name, chain: remove game containers, the bridge and the firewall chain
  local net=$1 chain=$2 c bridge
  bridge=$(docker network inspect "$net" --format '{{index .Options "com.docker.network.bridge.name"}}' 2>/dev/null || true)
  [[ -n $bridge ]] || bridge=$net
  for c in $(game_containers "$net"); do docker rm -f "$c" >/dev/null; done
  docker network rm "$net" >/dev/null 2>&1 || true
  while iptables -w -D DOCKER-USER -o "$bridge" -j "$chain" 2>/dev/null; do :; done
  iptables -w -F "$chain" 2>/dev/null || true
  iptables -w -X "$chain" 2>/dev/null || true
}
verify() {  # network, chain
  local code=000
  for _ in {1..30}; do
    systemctl is-active --quiet wings && code=$(curl -sk -o /dev/null --max-time 3 -w '%{http_code}' https://127.0.0.1:8443/ || true)
    [[ $code != 000 ]] && break
    sleep 2
  done
  [[ $code != 000 ]] || { printf 'Wings API is not answering on 8443.\n' >&2; return 1; }
  docker network inspect "$1" >/dev/null || return 1
  iptables -w -S DOCKER-USER | grep -q -- "-j $2" || { printf 'Firewall chain %s is not hooked.\n' "$2" >&2; return 1; }
  say "OK: Wings answers on 8443 (HTTP $code), network $1, chain $2"
}

if [[ $MODE == --rollback ]]; then
  if [[ -d $OLD_ETC && ! -e $NEW_ETC ]]; then  # failed before the move: only the services are down
    systemctl enable "$OLD_UNIT.service"
    systemctl start "$OLD_UNIT.service" wings
    verify "$OLD_NET" "$OLD_CHAIN"
    say 'Services restarted with the old names. Start the servers from the panel.'
    exit 0
  fi
  [[ -f $SNAP && -d $NEW_ETC && ! -e $OLD_ETC ]] || { printf 'Nothing to roll back.\n' >&2; exit 1; }
  assert_only_game_containers "$NEW_NET"
  systemctl stop wings
  drop_network "$NEW_NET" "$NEW_CHAIN"
  systemctl disable --now "$NEW_UNIT.service" 2>/dev/null || true
  rm -f "$SD/$NEW_UNIT.service" "/usr/local/sbin/$NEW_UNIT"
  mv "$NEW_ETC" "$OLD_ETC"; mv "$NEW_SRV" "$OLD_SRV"; [[ -d $NEW_LOG ]] && mv "$NEW_LOG" "$OLD_LOG"
  id wings >/dev/null 2>&1 && { usermod -l pelican -d /home/pelican wings; groupmod -n pelican wings; }
  tar -xpf "$SNAP" -C /
  systemctl daemon-reload
  systemctl enable "$OLD_UNIT.service"
  systemctl start "$OLD_UNIT.service" wings
  verify "$OLD_NET" "$OLD_CHAIN"
  say 'Rolled back. Start the servers from the panel.'
  exit 0
fi

# Checks
for p in "$OLD_ETC/config.yml" "$OLD_SRV/volumes" "$SD/wings.service" "$SD/$OLD_UNIT.service" "/usr/local/sbin/$OLD_UNIT" \
    "$FIREWALL_SRC/$NEW_UNIT" "$FIREWALL_SRC/$NEW_UNIT.service" "$FIREWALL_SRC/wings-game-firewall.conf"; do
  [[ -e $p ]] || { printf 'Missing %s\n' "$p" >&2; exit 1; }
done
for p in "$NEW_ETC" "$NEW_SRV" "$NEW_LOG"; do [[ ! -e $p ]] || { printf 'Already exists: %s\n' "$p" >&2; exit 1; }; done
! id wings >/dev/null 2>&1 || { printf 'User wings already exists.\n' >&2; exit 1; }
! docker network inspect "$NEW_NET" >/dev/null 2>&1 || { printf 'Network %s already exists.\n' "$NEW_NET" >&2; exit 1; }
! findmnt -rn -o TARGET | grep -q "^$OLD_SRV/volumes" || { printf 'Something is mounted under %s/volumes.\n' "$OLD_SRV" >&2; exit 1; }
assert_only_game_containers "$OLD_NET"
say "Checks OK. Game containers to remove: $(game_containers "$OLD_NET" | wc -l)"
if [[ $MODE == check ]]; then
  say 'Nothing changed. Run with --execute.'
  exit 0
fi

trap 'printf "FAILED at line %s. Fix it or run: sudo %s --rollback\n" "$LINENO" "$0" >&2' ERR

say 'Saving a copy of the configuration'
(umask 077; tar -cpf "$SNAP" -C / "${OLD_ETC#/}" "${SD#/}/wings.service" "${SD#/}/wings.service.d" "${SD#/}/$OLD_UNIT.service" \
  "usr/local/sbin/$OLD_UNIT")

say 'Stopping Wings and removing the game containers and old network'
systemctl stop wings
drop_network "$OLD_NET" "$OLD_CHAIN"
systemctl disable --now "$OLD_UNIT.service"

# Left over from the retired healthtracker-cloudflare-only unit files, gone from disk already.
systemctl stop healthtracker-cloudflare-only.timer 2>/dev/null || true

say 'Moving directories and renaming the user'
mv "$OLD_ETC" "$NEW_ETC"; mv "$OLD_SRV" "$NEW_SRV"; [[ -d $OLD_LOG ]] && mv "$OLD_LOG" "$NEW_LOG"
usermod -l wings -d /home/wings pelican   # same uid and gid, so file ownership does not change
groupmod -n wings pelican

say 'Updating configuration and units'
sed -i -E "s#$OLD_SRV#$NEW_SRV#g; s#$OLD_LOG#$NEW_LOG#g; s#/tmp/pelican#/tmp/wings#g; s#^app_name: pelican\$#app_name: kubo#; \
  s#^(\s*username: )pelican\$#\1wings#; s#$OLD_NET#$NEW_NET#g" "$NEW_ETC/config.yml"
! grep -q pelican "$NEW_ETC/config.yml" || { printf 'config.yml still mentions pelican.\n' >&2; false; }
sed -i -E "s#^WorkingDirectory=.*#WorkingDirectory=$NEW_ETC#; s#^ExecStart=/usr/local/bin/wings\$#ExecStart=/usr/local/bin/wings -c $NEW_ETC/config.yml#" "$SD/wings.service"
install -o root -g root -m 0750 "$FIREWALL_SRC/$NEW_UNIT" "/usr/local/sbin/$NEW_UNIT"
install -o root -g root -m 0644 "$FIREWALL_SRC/$NEW_UNIT.service" "$SD/$NEW_UNIT.service"
install -o root -g root -m 0644 "$FIREWALL_SRC/wings-game-firewall.conf" "$SD/wings.service.d/20-game-firewall.conf"
rm -f "$SD/$OLD_UNIT.service" "/usr/local/sbin/$OLD_UNIT"
systemctl daemon-reload
systemctl reset-failed 2>/dev/null || true
systemctl enable "$NEW_UNIT.service"

say 'Starting the firewall and Wings'
systemctl start "$NEW_UNIT.service"
systemctl start wings
for _ in {1..30}; do docker network inspect "$NEW_NET" >/dev/null 2>&1 && break; sleep 2; done
docker network inspect "$NEW_NET" >/dev/null   # Wings creates it on startup
systemctl restart "$NEW_UNIT.service"          # now hooks the bridge Docker really created
verify "$NEW_NET" "$NEW_CHAIN"
say "Done. Copy of the old configuration: $SNAP. Start the servers from the panel."
