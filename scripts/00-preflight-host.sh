#!/usr/bin/env bash
# Read-only host inventory. Run with sudo on the real host:
#   sudo ./00-preflight-host.sh | tee ~/pelican-host-preflight-$(date +%F).txt
set -Eeuo pipefail

section() { printf '\n===== %s =====\n' "$1"; }
run() { "$@" 2>&1 || true; }

section 'Identity and platform'
run id
run uname -a
run systemd-detect-virt
run cat /etc/os-release

section 'CPU, RAM and storage'
run lscpu
run free -h
run lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS,MODEL
run findmnt -T / -o TARGET,SOURCE,FSTYPE,OPTIONS
run df -hT

section 'Network and listeners'
run ip -brief address
run ip route
run ss -lntup

section 'Docker (do not print registry credentials)'
run docker version
run docker info
run docker ps -a --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'
run docker network ls

section 'Reverse proxies and active services'
run systemctl --no-pager --type=service --state=running
run systemctl is-enabled docker nginx caddy ufw nftables
run nginx -t
run caddy validate --config /opt/selfhost/caddy/Caddyfile --adapter caddyfile

section 'Firewall and kernel limits'
run ufw status verbose
run nft list ruleset
run iptables -S
run iptables -S DOCKER-USER
run sysctl net.ipv4.ip_forward vm.swappiness fs.inotify.max_user_instances
run grep -E '(^| )swapaccount=|^GRUB_CMDLINE_LINUX' /etc/default/grub

section 'Update and backup capability'
run systemctl is-enabled unattended-upgrades
run systemctl status --no-pager unattended-upgrades
run findmnt -rno TARGET,SOURCE,FSTYPE /mnt /media /srv 2>/dev/null

printf '\nPreflight finished. Treat this report as sensitive: it can contain public IPs and service names.\n'
