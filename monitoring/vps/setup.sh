#!/usr/bin/env bash
# Run as root on the VPS with the tunnel public key as $1. Exporters listen on loopback only;
# nftables input policy is drop, and metrics-tunnel may forward only to these three ports.
set -Eeuo pipefail
pub=${1:?public key}
apt-get install -y --no-install-recommends prometheus-node-exporter prometheus-blackbox-exporter
echo 'ARGS="--web.listen-address=127.0.0.1:9100 --collector.disable-defaults --collector.cpu --collector.meminfo --collector.filesystem --collector.loadavg --collector.netdev --collector.uname --collector.time --collector.stat"' > /etc/default/prometheus-node-exporter
echo 'ARGS="--web.listen-address=127.0.0.1:9115 --config.file=/etc/prometheus/blackbox.yml"' > /etc/default/prometheus-blackbox-exporter
cat > /etc/prometheus/blackbox.yml <<'YML'
modules:
  http_up:
    prober: http
    timeout: 10s
    http:
      method: GET
      preferred_ip_protocol: ip4
      fail_if_not_ssl: true
      # livesync answers 401 without credentials; that still proves the service is up.
      valid_status_codes: [200, 301, 302, 307, 308, 401]
      no_follow_redirects: true
      headers: {User-Agent: monitor-blackbox}
  tcp_up:
    prober: tcp
    timeout: 8s
    tcp: {preferred_ip_protocol: ip4}
  tls_up:
    prober: tcp
    timeout: 8s
    tcp: {preferred_ip_protocol: ip4, tls: true}
YML
id metrics-tunnel >/dev/null 2>&1 || useradd -m -s /usr/sbin/nologin metrics-tunnel
install -d -m 700 -o metrics-tunnel -g metrics-tunnel ~metrics-tunnel/.ssh
printf 'restrict,port-forwarding,permitopen="127.0.0.1:9100",permitopen="127.0.0.1:9115",permitopen="127.0.0.1:8405" %s\n' "$pub" > ~metrics-tunnel/.ssh/authorized_keys
chown metrics-tunnel: ~metrics-tunnel/.ssh/authorized_keys; chmod 600 ~metrics-tunnel/.ssh/authorized_keys
cat > /etc/ssh/sshd_config.d/91-metrics-tunnel.conf <<'CONF'
# Prometheus on the miniPC reaches loopback exporters through this user. Nothing else.
Match User metrics-tunnel
	AllowTcpForwarding local
	PermitOpen 127.0.0.1:9100 127.0.0.1:9115 127.0.0.1:8405
	X11Forwarding no
	AllowAgentForwarding no
	PermitTTY no
CONF
sed -i 's/^AllowUsers andrew restic-tunnel$/AllowUsers andrew restic-tunnel metrics-tunnel/' /etc/ssh/sshd_config.d/00-hardening.conf
sshd -t && systemctl reload ssh
grep -q 'frontend metrics' /etc/haproxy/haproxy.cfg || cat >> /etc/haproxy/haproxy.cfg <<'CFG'

# Prometheus exporter, loopback only (reached through the metrics-tunnel SSH user).
frontend metrics
	mode http
	bind 127.0.0.1:8405
	http-request use-service prometheus-exporter if { path /metrics }
	http-request deny
CFG
haproxy -c -f /etc/haproxy/haproxy.cfg && systemctl reload haproxy
systemctl restart prometheus-node-exporter prometheus-blackbox-exporter
systemctl enable prometheus-node-exporter prometheus-blackbox-exporter >/dev/null
