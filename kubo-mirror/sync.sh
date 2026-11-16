#!/usr/bin/env bash
# Mirror third-party downloads that Spanish ISPs block during LaLiga matches (Cloudflare IPs)
# for Kubo egg installers. Each file is fetched through vps-proxy, verified against the
# publisher's SHA-256 and published at https://kubo.csmak.com/mirror/<project>/<file>.
set -Eeuo pipefail

TARGET=/opt/selfhost/caddy/sites/mirror   # root-owned, served read-only by Caddy
WORK=$(mktemp -d)

# One multiplexed SSH connection: the VPS rate-limits new SSH connections (6/min per source).
SSH=(ssh -o BatchMode=yes -o ConnectTimeout=15 -o ControlMaster=auto -o "ControlPath=$WORK/ssh.sock" -o ControlPersist=120 vps-proxy)
trap '"${SSH[@]}" -O exit 2>/dev/null; rm -rf "$WORK"' EXIT
via_vps() { "${SSH[@]}" "curl -fsSL --max-time 300 $(printf %q "$1")"; }

# GeyserMC build API: {"downloads": {"spigot": {"name": ..., "sha256": ...}}}
mirror_geysermc() {
  local project=$1 platform=$2 file=$3
  local api="https://download.geysermc.org/v2/projects/$project/versions/latest/builds/latest"
  local sha
  sha=$(via_vps "$api" | python3 -I -c "import json,sys; print(json.load(sys.stdin)['downloads']['$platform']['sha256'])")
  [[ $sha =~ ^[0-9a-f]{64}$ ]] || { printf '%s: bad checksum from API\n' "$project" >&2; return 1; }
  if [[ -f $WORK/current/geyser/$file ]] && sha256sum "$WORK/current/geyser/$file" | grep -q "^$sha "; then
    printf '%s: up to date\n' "$file"; return 0
  fi
  via_vps "$api/downloads/$platform" > "$WORK/$file"
  sha256sum "$WORK/$file" | grep -q "^$sha " || { printf '%s: checksum mismatch\n' "$file" >&2; return 1; }
  mkdir -p "$WORK/new/geyser"
  mv "$WORK/$file" "$WORK/new/geyser/$file"
  printf '%s: updated (%s)\n' "$file" "${sha:0:12}"
}

# Current files, to skip unchanged downloads (andrew cannot read the root-owned target directly).
mkdir -p "$WORK/current"
docker run --rm -v "$TARGET:/m:ro" -v "$WORK/current:/out" alpine:3.22 sh -c 'cp -a /m/. /out/ 2>/dev/null; chown -R '"$(id -u):$(id -g)"' /out' 2>/dev/null || true

mirror_geysermc geyser spigot geyser-spigot.jar
mirror_geysermc floodgate spigot floodgate-spigot.jar

# Publish only the verified new files; Caddy serves them as soon as they land.
if [[ -d $WORK/new ]]; then
  docker run --rm -v "$WORK/new:/in:ro" -v "$(dirname "$TARGET"):/sites" alpine:3.22 \
    sh -c 'mkdir -p /sites/mirror && cp -a /in/. /sites/mirror/ && chown -R root:root /sites/mirror && chmod -R a+rX /sites/mirror'
fi
