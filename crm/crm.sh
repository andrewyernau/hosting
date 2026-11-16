#!/usr/bin/env bash
# Twenty CRM (cottonstream.es). Usage: ./crm.sh init | up | verify | logs
# init creates secrets/db.env and secrets/twenty.env once (never overwrites; ENCRYPTION_KEY must never change).
set -Eeuo pipefail
cd "$(dirname "$0")"
SMTP_PASS=$HOME/hosting/mail/secrets/no-reply@cottonstream.es.pass

case ${1:-} in
init)
  umask 077
  if [[ ! -s secrets/db.env ]]; then
    printf 'POSTGRES_PASSWORD=%s\n' "$(openssl rand -hex 32)" > secrets/db.env
  fi
  if [[ ! -s secrets/twenty.env ]]; then
    pg=$(sed -n 's/^POSTGRES_PASSWORD=//p' secrets/db.env)
    { printf 'PG_DATABASE_URL=postgres://twenty:%s@crm-db:5432/twenty\n' "$pg"
      printf 'ENCRYPTION_KEY=%s\n' "$(openssl rand -base64 32 | tr -d '\n')"
      printf 'EMAIL_SMTP_PASSWORD=%s\n' "$(cat "$SMTP_PASS")"; } > secrets/twenty.env
    unset pg
  fi
  echo "secrets: $(ls secrets | tr '\n' ' ')" ;;
up)
  docker compose up -d --wait --remove-orphans ;;
verify)
  ok=0; fail=0
  check() { if eval "$2" >/dev/null 2>&1; then echo "ok   $1"; ok=$((ok+1)); else echo "FAIL $1"; fail=$((fail+1)); fi; }
  check "server healthy"      "[ \"\$(docker inspect -f '{{.State.Health.Status}}' crm-crm-server-1)\" = healthy ]"
  check "worker running"      "[ \"\$(docker inspect -f '{{.State.Running}}' crm-crm-worker-1)\" = true ]"
  check "db ready"            "docker exec crm-crm-db-1 pg_isready -U twenty -d twenty"
  check "secrets mode 600"    "[ \"\$(stat -c %a secrets/twenty.env secrets/db.env | sort -u)\" = 600 ]"
  check "public healthz"      "curl -fsS --max-time 10 --resolve crm.cottonstream.es:443:143.20.32.134 https://crm.cottonstream.es/healthz"
  check "db not published"    "! docker port crm-crm-db-1 | grep -q ."
  echo "$ok ok, $fail failed"; [[ $fail -eq 0 ]] ;;
logs)
  docker compose logs -f --tail 100 ;;
*) echo "usage: $0 init | up | verify | logs" >&2; exit 2 ;;
esac
