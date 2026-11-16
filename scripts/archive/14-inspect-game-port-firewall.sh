#!/usr/bin/env bash
# Read-only inspection of the firewall path Docker uses for Wings allocations.
# Docker-published game ports traverse DOCKER-USER before Docker's own accept
# rules, whereas host services continue to be governed by UFW INPUT rules.

set -Eeuo pipefail

NETWORK=pelican_nw

[[ $EUID -eq 0 ]] || { printf 'Run this script with sudo/root.\n' >&2; exit 1; }
command -v docker >/dev/null || { printf 'Docker is required.\n' >&2; exit 1; }
docker network inspect "$NETWORK" >/dev/null || { printf 'Wings network %s is missing.\n' "$NETWORK" >&2; exit 1; }

bridge=$(docker network inspect "$NETWORK" --format '{{index .Options "com.docker.network.bridge.name"}}')
[[ -n $bridge ]] || { printf 'Could not determine the Linux bridge for %s.\n' "$NETWORK" >&2; exit 1; }

printf '%s\n' '===== Wings Docker bridge ====='
docker network inspect "$NETWORK" --format 'name={{.Name}} bridge={{index .Options "com.docker.network.bridge.name"}} internal={{.Internal}} icc={{index .Options "com.docker.network.bridge.enable_icc"}} {{range .IPAM.Config}}subnet={{.Subnet}} gateway={{.Gateway}}{{end}}'
ip -brief link show "$bridge" || true

printf '%s\n' '===== Docker packet-filter chains ====='
iptables -w -V
iptables -w -S FORWARD
iptables -w -S DOCKER-USER
iptables -w -S DOCKER-FORWARD || true

printf '%s\n' '===== Host firewall summary ====='
ufw status verbose

printf '%s\n' 'Inspection finished. No firewall, Docker network, port, or service was changed.'
