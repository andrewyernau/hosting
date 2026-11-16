# vps-proxy (143.20.32.134)

Borde público delante del MiniPC. Oculta la IP de casa y absorbe DDoS (protección
del proveedor). No termina TLS: los certificados siguen en casa.

```text
Cloudflare ──443/80──► HAProxy ─┐ (PROXY v2)
Internet ───8443, 2022─► HAProxy ─┤
Internet ───25550-25580─► HAProxy ┤  WireGuard 10.66.0.1 ◄── casa inicia la conexión
Internet ───25565───────► mc-router┘            │
Internet ═══25550-25580/udp═► DNAT + masquerade ═╡ (nftables, sin proxy)
                                                ▼
                         edge-tunnel (contenedor, 10.66.0.2 / 10.203.66.2)
                           ├─ 80, 443  ─► Caddy 10.203.66.3 (red edge_tunnel)
                           └─ 8443, 2022, 25550-25580 (tcp y udp) ─► 192.168.0.111
```

Debian 13, 1 vCPU, 1 GB. `ssh vps-proxy` (usuario `andrew`, solo clave, sudo
sin contraseña). Root no entra por SSH; la consola del proveedor sigue usando la
contraseña de root.

## Fronteras de seguridad

- **SSH**: solo clave, `AllowUsers andrew`, sin forwarding; nftables limita
  conexiones nuevas por IP (6/min).
- **nftables** (`etc/nftables.conf`): todo cerrado salvo 22, 51820/udp, 80/443
  **solo desde rangos de Cloudflare** (`cloudflare_v4`, refresco semanal), 8443,
  2022, 25565 y 25550-25580 con límite de conexiones por IP.
- **UDP de juegos** (desde 2026-11-01, Bedrock y GeyserMC): `table ip nat` hace DNAT de
  `25550-25580/udp` a 10.66.0.2 y masquerade a 10.66.0.1 (casa solo enruta respuestas al
  VPS). La cadena `forward` solo deja pasar ese rango, con un presupuesto de 60 flujos nuevos/min
  por IP; `net.ipv4.ip_forward = 1` solo sirve para esto. Los servidores ven 10.66.0.1, igual que
  con TCP. No se anuncia protección DDoS para UDP.
- **Salida al túnel**: el VPS solo puede abrir hacia 10.66.0.2 los puertos de
  `etc/nftables.d/tunnel.nft`. Casa vuelve a filtrar lo mismo (doble barrera).
- **Casa no confía en el VPS**: el contenedor `edge-tunnel` solo hace DNAT a la
  lista blanca; no hay ruta a la LAN, a Tailscale ni a otros contenedores, y el
  propio contenedor no puede salir a ningún sitio salvo al endpoint WireGuard.
- **Servicios**: HAProxy (chroot, usuario haproxy) y mc-router (systemd
  DynamicUser, exposición 1.4). Sin Docker en el VPS.
- **Actualizaciones**: unattended-upgrades con reinicio automático a las 05:30.

## Correo

- `25` (SMTP) y `465/587/993` se reenvían con PROXY v2 a Stalwart (`10.203.66.4`, ver
  `../mail/README.md`). Límites por IP en nftables y HAProxy.
- Salida: HAProxy escucha en `10.66.0.1:2465` (solo desde 10.66.0.2) y reenvía a
  `smtp.resend.com:465`. El proveedor bloquea la salida al 25 y no ofrece PTR.
- `haproxy.service.d/10-after-wg.conf`: HAProxy arranca tras `wg-quick@wg0` (bind en 10.66.0.1).

## Minecraft

- `25550-25580` se reenvían tal cual: los registros SRV que crea Gaming siguen
  funcionando y también `host:puerto`.
- `25565` es mc-router: enruta por subdominio. Sus rutas las genera
  `mc-routes-sync` cada minuto a partir de los SRV `_minecraft._tcp.*` de
  Cloudflare (token **solo lectura** en `/etc/mc-router/cloudflare-dns-read.token`,
  root 600). Sin token, el timer no hace nada.
- Los servidores ven la IP del túnel, no la del jugador (no se envía PROXY
  protocol porque los servidores no lo aceptan por defecto).

## Operación

```bash
ssh vps-proxy 'sudo wg show; systemctl is-active haproxy mc-router nftables'
ssh vps-proxy 'echo "show servers state" | sudo socat - /run/haproxy/admin.sock'
ssh vps-proxy 'sudo journalctl -k | grep nft-drop | tail'   # descartes
```

Cambios: editar aquí, copiar al VPS, `sudo nft -c -f /etc/nftables.conf` o
`sudo haproxy -c -f /etc/haproxy/haproxy.cfg` y recargar. Para nftables usar la
red de seguridad:
`sudo systemd-run --unit=nft-rollback --on-active=120 /usr/sbin/nft flush ruleset`
antes de aplicar y `sudo systemctl stop nft-rollback.timer` tras comprobar SSH.

Este directorio es un espejo sin secretos. Las claves privadas viven solo en
`/etc/wireguard/vps.key` (VPS) y `../edge-tunnel/secrets/wg-home.key` (casa).
