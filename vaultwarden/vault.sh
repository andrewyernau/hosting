#!/usr/bin/env bash
# Gestión de Vaultwarden (solo tailnet). Ver README.md.
#
#   ./vault.sh init                 crea volúmenes con el dueño correcto (idempotente)
#   ./vault.sh login <authkey-file> da de alta el nodo "vault" en la tailnet (una vez)
#   ./vault.sh up                   arranca/actualiza con registros CERRADOS
#   ./vault.sh open-signups         abre registros (solo para crear tu cuenta)
#   ./vault.sh close-signups        los vuelve a cerrar
#   ./vault.sh verify               comprueba exposición y configuración
#   ./vault.sh backup               copia a ~/backups/vaultwarden (conserva 30)
#   ./vault.sh restore-drill [tar]  restaura un backup en un volumen temporal y lo arranca aislado
set -euo pipefail
cd "$(dirname "$0")"

URL=https://vault.tail0ca86f.ts.net
UID_GID=10001:10001
ALPINE=alpine:3.22@sha256:2e0b81d60597f449baa56dc25d355367869d2dca4cd57e866f1e2b52af3eb55f
BACKUP_DIR="$HOME/backups/vaultwarden"
KEEP=30

compose() { docker compose "$@"; }

wait_healthy() {
  for _ in $(seq 1 60); do
    [ "$(docker inspect -f '{{.State.Health.Status}}' vaultwarden-vaultwarden-1 2>/dev/null)" = healthy ] && return 0
    sleep 2
  done
  echo "vaultwarden no llega a healthy" >&2; return 1
}

cmd_init() {
  docker volume create vaultwarden_data >/dev/null
  docker volume create vaultwarden_ts_state >/dev/null
  docker run --rm -v vaultwarden_data:/data "$ALPINE" \
    sh -c "chown $UID_GID /data && chmod 700 /data"
  docker run --rm -v vaultwarden_ts_state:/s "$ALPINE" chmod 700 /s
  echo "volúmenes listos"
}

cmd_login() {
  local keyfile=${1:?uso: ./vault.sh login <fichero-con-authkey>}
  TS_AUTHKEY="$(cat "$keyfile")" compose up -d vault-ts
  for _ in $(seq 1 30); do
    if docker exec vaultwarden-vault-ts-1 tailscale status --self --peers=false >/dev/null 2>&1; then break; fi
    sleep 2
  done
  # Recrea sin la clave en el entorno del contenedor (el estado ya está en el volumen).
  compose up -d --force-recreate vault-ts
  docker exec vaultwarden-vault-ts-1 tailscale status --self --peers=false
}

cmd_up() {
  compose up -d --force-recreate
  wait_healthy
  echo "arriba en $URL (registros cerrados)"
}

cmd_open_signups() {
  SIGNUPS_ALLOWED=true compose up -d --force-recreate vaultwarden
  wait_healthy
  echo "REGISTROS ABIERTOS en $URL — crea tu cuenta y ejecuta ./vault.sh close-signups"
}

cmd_close_signups() {
  compose up -d --force-recreate vaultwarden
  wait_healthy
  echo "registros cerrados"
}

cmd_verify() {
  local fail=0
  check() { if eval "$2"; then echo "OK   $1"; else echo "FAIL $1"; fail=1; fi; }

  local ts_ip
  ts_ip=$(docker exec vaultwarden-vault-ts-1 tailscale ip -4)

  check "sin puertos publicados en el host" \
    '[ -z "$(docker port vaultwarden-vault-ts-1)$(docker port vaultwarden-vaultwarden-1)" ]'
  check "solo en la red vaultwarden_egress" \
    '[ "$(docker inspect -f "{{range \$k,\$v := .NetworkSettings.Networks}}{{\$k}} {{end}}" vaultwarden-vault-ts-1)" = "vaultwarden_egress " ]'
  check "vaultwarden comparte netns con el sidecar" \
    '[ "$(docker inspect -f "{{.HostConfig.NetworkMode}}" vaultwarden-vaultwarden-1)" = "container:$(docker inspect -f "{{.Id}}" vaultwarden-vault-ts-1)" ]'
  check "vaultwarden escucha solo en 127.0.0.1:8080" \
    '[ "$(docker exec vaultwarden-vault-ts-1 netstat -tln | awk "\$4 ~ /:8080\$/ {print \$4}")" = "127.0.0.1:8080" ]'
  check "registros cerrados" \
    'docker exec vaultwarden-vaultwarden-1 printenv SIGNUPS_ALLOWED | grep -qx false'
  check "sin TS_AUTHKEY en el entorno del sidecar" \
    '[ -z "$(docker exec vaultwarden-vault-ts-1 printenv TS_AUTHKEY || true)" ]'
  check "sin config.json (nada sobrescribe el entorno)" \
    '! docker exec vaultwarden-vaultwarden-1 test -e /data/config.json'
  check "funnel desactivado" \
    '! docker exec vaultwarden-vault-ts-1 tailscale funnel status 2>&1 | grep -qi "funnel on\|(Funnel on)\|public"'
  check "HTTPS por la tailnet responde ($URL/alive)" \
    'curl -fsS --max-time 10 "$URL/alive" >/dev/null'
  check "panel /admin desactivado" \
    'curl -s --max-time 10 "$URL/admin" | grep -q "admin panel is disabled"'
  check "HTTP plano a $ts_ip:8080 rechazado" \
    '! curl -s --max-time 5 "http://$ts_ip:8080/alive" >/dev/null'
  check "HTTP plano a $ts_ip:80 rechazado" \
    '! curl -s --max-time 5 "http://$ts_ip:80/alive" >/dev/null'
  check "ningún socket del host usa la IP del nodo vault" \
    '! ss -tlnH | awk "{print \$4}" | grep -qF "$ts_ip"'
  check "tailscale serve del host intacto (443 -> 127.0.0.1:3773)" \
    'tailscale serve status 2>/dev/null | grep -q "proxy http://127.0.0.1:3773"'
  return $fail
}

cmd_backup() {
  umask 077
  mkdir -p "$BACKUP_DIR"
  local ts out snap
  ts=$(date -u +%Y%m%dT%H%M%SZ)
  out="$BACKUP_DIR/vaultwarden-$ts.tar.gz"
  # Copia consistente de SQLite (API de backup online) dentro del volumen.
  snap=$(docker exec vaultwarden-vaultwarden-1 /vaultwarden backup 2>&1 | grep -o 'db_[0-9_]*\.sqlite3' | tail -1)
  [ -n "$snap" ] || { echo "falló vaultwarden backup" >&2; return 1; }
  docker run --rm -v vaultwarden_data:/data:ro "$ALPINE" \
    tar -C /data -czf - --exclude='./db.sqlite3' --exclude='./db.sqlite3-*' \
      --exclude='./icon_cache' --exclude='./tmp' . > "$out.part"
  docker run --rm -v vaultwarden_data:/data "$ALPINE" sh -c 'rm -f /data/db_*.sqlite3' 
  mv "$out.part" "$out"
  # Verificación: la BD del backup abre y pasa integrity_check.
  python3 - "$out" "$snap" <<'PY'
import sqlite3, sys, tarfile, tempfile, os
tar_path, snap = sys.argv[1], sys.argv[2]
with tempfile.TemporaryDirectory() as d, tarfile.open(tar_path) as t:
    t.extract("./" + snap, d, filter="data")
    con = sqlite3.connect(os.path.join(d, snap))
    ok = con.execute("pragma integrity_check").fetchone()[0]
    users = con.execute("select count(*) from users").fetchone()[0]
    ciphers = con.execute("select count(*) from ciphers").fetchone()[0]
    con.close()
    if ok != "ok":
        sys.exit(f"integrity_check: {ok}")
    print(f"backup OK: {tar_path} (usuarios={users}, elementos={ciphers})")
PY
  ls -1t "$BACKUP_DIR"/vaultwarden-*.tar.gz | tail -n +$((KEEP + 1)) | xargs -r rm -f
}

cmd_restore_drill() {
  local tarball=${1:-$(ls -1t "$BACKUP_DIR"/vaultwarden-*.tar.gz | head -1)}
  local vol=vaultwarden_restore_drill name=vaultwarden-restore-drill
  docker rm -f "$name" >/dev/null 2>&1 || true
  docker volume rm "$vol" >/dev/null 2>&1 || true
  docker volume create "$vol" >/dev/null
  trap 'docker rm -f '"$name"' >/dev/null 2>&1; docker volume rm '"$vol"' >/dev/null 2>&1' RETURN
  docker run --rm -i -v "$vol":/data "$ALPINE" sh -c '
    tar -C /data -xzf - && cd /data && snap=$(ls db_*.sqlite3) && mv "$snap" db.sqlite3 \
    && chown -R 10001:10001 /data && chmod 700 /data' < "$tarball"
  docker run -d --name "$name" --network none --user 10001:10001 --read-only --tmpfs /tmp \
    --cap-drop ALL --security-opt no-new-privileges:true \
    -e ROCKET_ADDRESS=127.0.0.1 -e ROCKET_PORT=8080 -e SIGNUPS_ALLOWED=false \
    -v "$vol":/data "$(docker inspect -f '{{.Config.Image}}' vaultwarden-vaultwarden-1)" >/dev/null
  for _ in $(seq 1 30); do
    if docker exec "$name" curl -fsS http://127.0.0.1:8080/alive >/dev/null 2>&1; then
      echo "restore-drill OK: $tarball arranca y responde"; return 0
    fi
    sleep 2
  done
  docker logs "$name" 2>&1 | tail -20
  echo "restore-drill FALLÓ: $tarball" >&2; return 1
}

case "${1:-}" in
  init) cmd_init ;;
  login) shift; cmd_login "$@" ;;
  up) cmd_up ;;
  open-signups) cmd_open_signups ;;
  close-signups) cmd_close_signups ;;
  verify) cmd_verify ;;
  backup) cmd_backup ;;
  restore-drill) shift; cmd_restore_drill "$@" ;;
  *) sed -n '2,12p' "$0"; exit 2 ;;
esac
