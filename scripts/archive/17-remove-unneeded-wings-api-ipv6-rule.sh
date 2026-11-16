#!/usr/bin/env bash
# The first UFW rule for Wings was added before deciding not to use IPv6 on
# this first node. Remove only that documented public IPv6 exception; IPv4
# connectivity and the private Panel-to-Wings rule remain intact.

set -Eeuo pipefail

EXECUTE=false

usage() {
  sed -n '2,7p' "$0"
  printf 'Usage: sudo %s [--execute]\n' "$0"
  exit 2
}

while (( $# )); do
  case "$1" in
    --execute) EXECUTE=true; shift ;;
    -h|--help) usage ;;
    *) printf 'Unknown argument: %s\n' "$1" >&2; usage ;;
  esac
done

[[ $EUID -eq 0 ]] || { printf 'Run this script with sudo/root.\n' >&2; exit 1; }
command -v ufw >/dev/null || { printf 'UFW is required.\n' >&2; exit 1; }

mapfile -t matching_rules < <(ufw status numbered | sed -n 's/^[[:space:]]*\[\([0-9][0-9]*\)\].*8080\/tcp (v6).*Pelican Wings client API.*/\1/p')

if [[ ${#matching_rules[@]} -eq 0 ]]; then
  printf 'No matching public IPv6 Wings API rule exists; nothing to change.\n'
  exit 0
fi
[[ ${#matching_rules[@]} -eq 1 ]] || {
  printf 'Found multiple matching IPv6 Wings API rules; refusing to delete by number.\n' >&2; exit 1;
}

rule_number=${matching_rules[0]}
if ! $EXECUTE; then
  cat <<EOF
Dry run successful. The deployment will remove only UFW rule [$rule_number]:
  public IPv6 TCP 8080 for "Pelican Wings client API"
IPv4 TCP 8080 and the private 172.21.0.0/16 Panel-to-Wings rule are unchanged.
Run again with --execute to remove this unneeded IPv6 exception.
EOF
  exit 0
fi

ufw --force delete "$rule_number"
ufw status numbered
