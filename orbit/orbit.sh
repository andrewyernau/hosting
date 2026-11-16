#!/usr/bin/env bash
# Gestión de Orbit (solo tailnet). Ver README.md.
#
#   ./orbit.sh init        crea volúmenes y la clave de la app (idempotente)
#   ./orbit.sh login <f>   da de alta el nodo con una auth key en un fichero (una vez)
#   ./orbit.sh up          arranca o actualiza
#   ./orbit.sh setup-url   genera y guarda un enlace de alta único en secrets/setup-url
#   ./orbit.sh verify      comprueba exposición y configuración
set -Eeuo pipefail
cd "$(dirname "$0")"

URL=https://orbit.tail0ca86f.ts.net
TS=orbit-orbit-ts-1
APP=orbit-orbit-1
UID_GID=65532:65532
ALPINE=alpine:3.22@sha256:2e0b81d60597f449baa56dc25d355367869d2dca4cd57e866f1e2b52af3eb55f

cmd_init() {
  local v
  for v in orbit_data orbit_backups orbit_ts_state; do docker volume create "$v" >/dev/null; done
  docker run --rm -v orbit_data:/d -v orbit_backups:/b "$ALPINE" sh -c "chown $UID_GID /d /b && chmod 700 /d /b"
  docker run --rm -v orbit_ts_state:/s "$ALPINE" chmod 700 /s
  # La clave no se regenera nunca: sin ella no se leen los secretos guardados ni la 2FA.
  [[ -s secrets/orbit.env ]] || (umask 077; printf 'ORBIT_APP_KEY=%s\n' "$(openssl rand -base64 32)" >secrets/orbit.env)
  echo 'listo'
}

cmd_login() {
  local keyfile=${1:?uso: ./orbit.sh login <fichero-con-authkey>} _
  TS_AUTHKEY="$(cat "$keyfile")" docker compose up -d --force-recreate orbit-ts
  for _ in {1..30}; do
    docker exec "$TS" tailscale status --self --peers=false >/dev/null 2>&1 && break
    sleep 2
  done
  # Recrea sin la clave en el entorno del contenedor (el estado ya está en el volumen).
  docker compose up -d --force-recreate orbit-ts
  docker compose up -d --force-recreate --no-deps --wait orbit
}

cmd_setup_url() {
  # Rota el token de alta (invalida el anterior); con SQLite exige parar Orbit.
  local out
  docker compose stop orbit
  out=$(docker compose run --rm --no-deps orbit setup-token rotate 2>&1)
  (umask 077; grep -oE 'https://[^" ]*setup\?token=[^" ]*' <<<"$out" | tail -n 1 >secrets/setup-url)
  docker compose up -d --no-deps --wait orbit
  [[ -s secrets/setup-url ]] && echo 'guardado en secrets/setup-url'
}

cmd_verify() {
  local failed=0
  check() { if "${@:2}" >/dev/null 2>&1; then printf 'OK    %s\n' "$1"; else printf 'FAIL  %s\n' "$1"; failed=1; fi; }
  no_host_ports() { ! docker ps --filter label=com.docker.compose.project=orbit --format '{{.Ports}}' | grep -q -- '->'; }
  no_funnel() { ! docker exec "$TS" tailscale funnel status 2>/dev/null | grep -qi 'funnel on'; }
  no_allowfunnel() { ! grep -q AllowFunnel serve.json; }
  isolated() { [[ $(docker inspect "$TS" --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}') == 'orbit_egress ' ]]; }
  loopback_only() { [[ -z $(docker exec "$TS" netstat -ltn | awk '{print $4}' | grep -E ':8080$' | grep -v '^127\.0\.0\.1:') ]] && docker exec "$TS" netstat -ltn | grep -q '127.0.0.1:8080'; }
  healthy() { [[ $(docker inspect -f '{{.State.Health.Status}}' "$APP") == healthy ]]; }
  answers() { local _; for _ in {1..12}; do curl -fsS --max-time 10 "$URL/health/ready" && return 0; sleep 5; done; return 1; }
  not_public() { ! curl -fsS --max-time 8 --resolve "orbit.tail0ca86f.ts.net:443:143.20.32.134" "$URL/health/ready"; }
  no_dns() { [[ -z $(dig +short @1.1.1.1 orbit.tail0ca86f.ts.net A | grep -v '^100\.') ]]; }
  check 'no host ports in the stack' no_host_ports
  check 'Funnel is off' no_funnel
  check 'serve.json has no AllowFunnel' no_allowfunnel
  check 'sidecar is only on orbit_egress' isolated
  check 'Orbit listens on loopback only' loopback_only
  check 'Orbit is healthy' healthy
  check 'Orbit answers over the tailnet' answers
  check 'Orbit does not answer through the VPS' not_public
  check 'public DNS has no non-tailnet address' no_dns
  return "$failed"
}

case ${1:-} in
  init) cmd_init ;;
  login) shift; cmd_login "$@" ;;
  up) docker compose up -d --wait ;;
  setup-url) cmd_setup_url ;;
  verify) cmd_verify ;;
  *) sed -n 2,9p "$0" >&2; exit 2 ;;
esac
