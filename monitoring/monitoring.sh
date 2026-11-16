#!/usr/bin/env bash
# Global monitoring checks. Usage: ./monitoring.sh verify
set -Eeuo pipefail
cd "$(dirname "$0")"
URL=https://monitor.tail0ca86f.ts.net
TS=monitoring-monitor-ts-1
GRAFANA=monitoring-grafana-1

cmd_verify() {
  local failed=0 name
  check() { if "${@:2}" >/dev/null 2>&1; then printf 'OK    %s\n' "$1"; else printf 'FAIL  %s\n' "$1"; failed=1; fi; }
  no_host_ports() { [[ -z $(docker compose ps --format '{{.Publishers}}' | grep -E '"?PublishedPort"?:[1-9]|[0-9]+->' || true) ]] && ! docker ps --filter label=com.docker.compose.project=monitoring --format '{{.Ports}}' | grep -q -- '->'; }
  no_funnel() { ! docker exec "$TS" tailscale funnel status 2>/dev/null | grep -qi 'funnel on'; }
  no_key() { ! docker inspect "$TS" --format '{{range .Config.Env}}{{println .}}{{end}}' | grep -q '^TS_AUTHKEY=.'; }
  loopback_only() { docker exec "$GRAFANA" sh -c "! netstat -ltn | awk '{print \$4}' | grep -E '^(0\\.0\\.0\\.0:|:::)3000\$'"; }
  # A recreated node needs up to a minute to obtain its certificate.
  answers() { local _; for _ in {1..12}; do curl -fsS --max-time 10 "$URL/api/health" && return 0; sleep 5; done; return 1; }
  not_public() { ! curl -fsS --max-time 8 --resolve "monitor.tail0ca86f.ts.net:443:143.20.32.134" "$URL/api/health"; }
  vps_loopback() { ! ssh -o BatchMode=yes vps-proxy "ss -ltnH | awk '{print \$4}' | grep -E ':(9100|9115|8405)\$' | grep -v '^127\\.0\\.0\\.1:'"; }
  target_up() { docker exec monitoring-prometheus-1 wget -qO- "http://localhost:9090/api/v1/query?query=up{job=\"$1\"}" | python3 -I -c 'import json,sys; r=json.load(sys.stdin)["data"]["result"]; sys.exit(not (r and all(x["value"][1]=="1" for x in r)))'; }
  check 'no host ports in the stack' no_host_ports
  check 'Funnel is off' no_funnel
  check 'no auth key left in the container' no_key
  check 'Grafana listens on loopback only' loopback_only
  check 'Grafana answers over the tailnet' answers
  check 'Grafana does not answer through the VPS' not_public
  check 'VPS exporters listen on loopback only' vps_loopback
  for name in node cadvisor haproxy gaming-api gaming-worker gaming-postgres web tcp tls; do check "Prometheus scrapes $name" target_up "$name"; done
  return "$failed"
}

case ${1:-} in
  verify) cmd_verify ;;
  *) printf 'usage: %s verify\n' "$0" >&2; exit 2 ;;
esac
