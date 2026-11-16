#!/bin/sh
# Home end of the vps-proxy tunnel. Dials the VPS, then forwards only the
# allowlisted TCP ports (and the game UDP range) to the miniPC. Everything else (LAN, other hosts,
# Tailscale, Docker networks) is dropped inside this network namespace.
set -eu

: "${VPS_ENDPOINT:?}" "${VPS_PUBLIC_KEY:?}" "${WEB_TARGET_IP:?}" "${WEB_PORTS:?}" "${HOST_TARGET_IP:?}" "${HOST_PORTS:?}"
: "${MAIL_TARGET_IP:?}" "${MAIL_PORTS:?}" "${RELAY_PORT:?}" "${HOST_UDP_PORTS:?}"
TUNNEL_ADDR=${TUNNEL_ADDR:-10.66.0.2/30}
VPS_TUNNEL_IP=${VPS_TUNNEL_IP:-10.66.0.1}
VPS_IP=${VPS_ENDPOINT%:*}
VPS_PORT=${VPS_ENDPOINT##*:}

ip link del wg0 2>/dev/null || true
ip link add wg0 type wireguard
wg set wg0 private-key /run/secrets/wg_home_key \
  peer "$VPS_PUBLIC_KEY" endpoint "$VPS_ENDPOINT" \
  allowed-ips "$VPS_TUNNEL_IP/32" persistent-keepalive 25
ip addr add "$TUNNEL_ADDR" dev wg0
ip link set wg0 mtu 1420 up

nft -f - <<NFT
flush ruleset
table ip edge {
	chain prerouting {
		type nat hook prerouting priority dstnat; policy accept;
		iifname "wg0" tcp dport { $WEB_PORTS } dnat to $WEB_TARGET_IP
		iifname "wg0" tcp dport { $HOST_PORTS } dnat to $HOST_TARGET_IP
		# Game UDP arrives already DNATed (not proxied) by the VPS, sourced from its tunnel IP.
		iifname "wg0" ip saddr $VPS_TUNNEL_IP udp dport { $HOST_UDP_PORTS } dnat to $HOST_TARGET_IP
		iifname "wg0" tcp dport { $MAIL_PORTS } dnat to $MAIL_TARGET_IP
		# Outbound relay: Stalwart -> here -> VPS HAProxy -> Resend, so Resend sees the VPS IP.
		iifname "eth0" ip saddr $MAIL_TARGET_IP tcp dport $RELAY_PORT dnat to $VPS_TUNNEL_IP
	}
	chain postrouting {
		type nat hook postrouting priority srcnat; policy accept;
		oifname "eth0" ip daddr { $WEB_TARGET_IP, $HOST_TARGET_IP, $MAIL_TARGET_IP } masquerade
		oifname "wg0" ip daddr $VPS_TUNNEL_IP tcp dport $RELAY_PORT masquerade
	}
	chain forward {
		type filter hook forward priority filter; policy drop;
		ct state established,related accept
		iifname "wg0" oifname "eth0" ip daddr $WEB_TARGET_IP tcp dport { $WEB_PORTS } ct state new accept
		iifname "wg0" oifname "eth0" ip daddr $HOST_TARGET_IP tcp dport { $HOST_PORTS } ct state new accept
		iifname "wg0" oifname "eth0" ip daddr $HOST_TARGET_IP udp dport { $HOST_UDP_PORTS } ct state new accept
		iifname "wg0" oifname "eth0" ip daddr $MAIL_TARGET_IP tcp dport { $MAIL_PORTS } ct state new accept
		iifname "eth0" oifname "wg0" ip saddr $MAIL_TARGET_IP ip daddr $VPS_TUNNEL_IP tcp dport $RELAY_PORT ct state new accept
		limit rate 5/minute log prefix "edge-drop-fwd: "
	}
	chain input {
		type filter hook input priority filter; policy drop;
		ct state established,related accept
		iif lo accept
		iifname "wg0" icmp type echo-request accept
	}
	chain output {
		type filter hook output priority filter; policy drop;
		ct state established,related accept
		oif lo accept
		oifname "eth0" ip daddr $VPS_IP udp dport $VPS_PORT accept
		oifname "wg0" ip daddr $VPS_TUNNEL_IP accept
	}
}
NFT

echo "edge-tunnel up: $VPS_ENDPOINT -> $WEB_TARGET_IP { $WEB_PORTS }, $HOST_TARGET_IP { $HOST_PORTS } udp { $HOST_UDP_PORTS }, $MAIL_TARGET_IP { $MAIL_PORTS }; relay $MAIL_TARGET_IP -> $VPS_TUNNEL_IP:$RELAY_PORT"
trap 'ip link del wg0 2>/dev/null; exit 0' TERM INT
while :; do sleep 3600 & wait $!; done
