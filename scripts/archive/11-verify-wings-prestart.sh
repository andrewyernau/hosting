#!/usr/bin/env bash
# Read-only pre-start inspection for Wings. It never prints node credentials.
# sudo ./11-verify-wings-prestart.sh
set -Eeuo pipefail

config=/etc/pelican/config.yml
section() { printf '\n===== %s =====\n' "$1"; }
run() { "$@" 2>&1 || true; }

[[ $EUID -eq 0 ]] || { printf 'Run this script with sudo/root.\n' >&2; exit 1; }
[[ -x /usr/local/bin/wings ]] || { printf 'Wings is not installed at /usr/local/bin/wings.\n' >&2; exit 1; }
[[ -r $config ]] || { printf 'Missing readable configuration: %s\n' "$config" >&2; exit 1; }

section 'Wings binary and service unit'
run /usr/local/bin/wings version
run systemctl cat wings.service

section 'Configuration ownership and selected safe values (credentials redacted)'
run stat -c '%a %U:%G %n' "$config"
run grep -E '^(debug:|docker:|  host:|  port:|    enabled:|    cert:|    key:|  root_directory:|  data:|  archive_directory:|  backup_directory:|  bind_port:|  network:|    interface:|    IPv6:|    interfaces:|      v4:|      v6:|        subnet:|        gateway:|allowed_mounts:)' "$config"
if grep -qx 'allowed_mounts: \[\]' "$config"; then
  printf 'Host mounts: disabled (expected).\n'
else
  printf 'WARNING: allowed_mounts is not an empty list; do not start Wings until reviewed.\n' >&2
fi

section 'TLS material'
cert=$(sed -n 's/^    cert: //p' "$config" | head -n1)
key=$(sed -n 's/^    key: //p' "$config" | head -n1)
if [[ -n $cert && -n $key && -r $cert && -r $key ]]; then
  run stat -Lc '%a %U:%G %n' "$cert" "$key"
  run openssl x509 -in "$cert" -noout -subject -enddate
else
  printf 'TLS certificate/key paths are missing or unreadable.\n' >&2
fi

section 'Existing Docker subnets'
docker network ls -q | while read -r network; do
  docker network inspect --format '{{.Name}} {{range .IPAM.Config}}{{.Subnet}} {{end}}' "$network"
done
wings_interface=$(awk '
  /^docker:[[:space:]]*$/ { in_docker=1; next }
  in_docker && /^[^[:space:]]/ { in_docker=0 }
  in_docker && /^[[:space:]]+interface:[[:space:]]*/ { sub(/^[[:space:]]*interface:[[:space:]]*/, ""); print; exit }
' "$config")
wings_v4_subnet=$(awk '
  /^docker:[[:space:]]*$/ { in_docker=1; next }
  in_docker && /^[^[:space:]]/ { in_docker=0 }
  in_docker && /^[[:space:]]+subnet:[[:space:]]*/ { sub(/^[[:space:]]*subnet:[[:space:]]*/, ""); print; exit }
' "$config")
network_subnet_count=$(awk '
  /^docker:[[:space:]]*$/ { in_docker=1; next }
  in_docker && /^[^[:space:]]/ { in_docker=0 }
  in_docker && /^[[:space:]]+subnet:[[:space:]]*/ { count++ }
  END { print count + 0 }
' "$config")
network_gateway_count=$(awk '
  /^docker:[[:space:]]*$/ { in_docker=1; next }
  in_docker && /^[^[:space:]]/ { in_docker=0 }
  in_docker && /^[[:space:]]+gateway:[[:space:]]*/ { count++ }
  END { print count + 0 }
' "$config")
if [[ $network_subnet_count -ne 1 || $network_gateway_count -ne 1 || ! $(grep -c '^    IPv6: false$' "$config") -eq 1 ]]; then
  printf 'WARNING: expected exactly one IPv4 subnet/gateway and IPv6: false in the Docker network block. Do not start Wings.\n' >&2
elif [[ -z $wings_interface || -z $wings_v4_subnet ]]; then
  printf 'WARNING: Docker network interface and explicit IPv4 subnet are both required; do not start Wings yet.\n' >&2
elif [[ $wings_interface != 172.22.0.1 || $wings_v4_subnet != 172.22.0.0/16 ]]; then
  printf 'WARNING: unexpected Wings network values: interface=%s subnet=%s. Do not start Wings until reviewed.\n' "$wings_interface" "$wings_v4_subnet" >&2
else
  printf 'Configured Wings bridge: %s (%s)\n' "$wings_interface" "$wings_v4_subnet"
  if docker network ls -q | xargs -r docker network inspect --format '{{range .IPAM.Config}}{{.Subnet}} {{end}}' | grep -Fwq "$wings_v4_subnet"; then
    printf 'WARNING: the configured Wings subnet already exists. Do not start Wings.\n' >&2
  fi
fi
if [[ -z $wings_interface ]]; then
  printf 'WARNING: no explicit Docker network interface was found; Wings would use its default 172.18.0.1.\n' >&2
fi

section 'Port availability before Wings'
run ss -lntp '( sport = :8080 or sport = :2022 )'

printf '\nPre-start inspection finished. No configuration, service, firewall, Docker network or data was changed.\n'
