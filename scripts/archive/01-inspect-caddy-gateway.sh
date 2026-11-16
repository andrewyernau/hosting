#!/usr/bin/env bash
# Read-only inspection of the shared Caddy gateway.
# Run on the real host and share the output before adding panel.yernau.com:
#   sudo ./01-inspect-caddy-gateway.sh | tee ~/caddy-gateway-inspection.txt
set -Eeuo pipefail

section() { printf '\n===== %s =====\n' "$1"; }
run() { "$@" 2>&1 || true; }

container=${CADDY_CONTAINER:-caddy-caddy-1}
root=${CADDY_ROOT:-/opt/selfhost/caddy}

section 'Caddy deployment'
run docker ps --filter "name=^/${container}$" --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'
run docker inspect "$container" --format 'Networks: {{range $name, $net := .NetworkSettings.Networks}}{{$name}}={{$net.IPAddress}} {{end}}'
run docker network inspect selfhost_proxy --format '{{range .Containers}}{{.Name}} {{.IPv4Address}}{{"\\n"}}{{end}}'

section 'Caddy configuration inventory (paths and public hostnames only)'
run find "$root" -maxdepth 2 -type f \( -name 'Caddyfile' -o -name '*.caddy' -o -name 'docker-compose.yml' -o -name 'compose.yml' \) -printf '%M %u:%g %p\\n'
run grep -RInE '^[[:space:]]*[^#[:space:]][^[:space:]]*[.]([[:alnum:]-]+[.][[:alpha:]]+)|reverse_proxy|tls[[:space:]]' "$root" --include='Caddyfile' --include='*.caddy' 2>/dev/null

section 'Effective Caddy configuration validation'
run docker exec "$container" caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
run docker exec "$container" caddy adapt --config /etc/caddy/Caddyfile --adapter caddyfile --pretty

section 'Port ownership and DNS resolution'
run ss -lntup '( sport = :80 or sport = :443 )'
run getent ahosts ajgambitopt.com
run getent ahosts yernau.com
run getent ahosts panel.yernau.com

printf '\nInspection finished. No configurations or containers were changed.\n'
