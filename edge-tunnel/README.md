# edge-tunnel

Extremo de casa del túnel WireGuard con [vps-proxy](../vps-proxy/README.md).
Contenedor sin capacidades salvo `NET_ADMIN` en su propio namespace de red,
sistema de ficheros de solo lectura y la clave como secreto (root 400).

Casa **marca** al VPS (keepalive 25 s), así que el router no necesita ningún
puerto abierto. Lo que llega por el túnel solo puede ir a:

| Puertos | Destino |
|---|---|
| 80, 443 | Caddy `10.203.66.3` en la red `edge_tunnel` (con PROXY v2) |
| 8443, 2022, 25550-25580 | MiniPC `192.168.0.111` (Wings, SFTP, juegos) |

Todo lo demás se descarta dentro del contenedor, y el contenedor no puede abrir
conexiones salvo hacia `143.20.32.134:51820/udp`.

`HOST_UDP_PORTS` (25550-25580) añade el UDP de juegos (Bedrock, GeyserMC): llega ya con DNAT
del VPS, con origen 10.66.0.1, y se reenvía al miniPC igual que el TCP. Wings publica cada
asignación en TCP y UDP.

```bash
docker compose up -d --build --wait     # desde este directorio
docker exec edge-tunnel-edge-1 wg show  # handshake reciente = sano
```

Dependencias:

- Caddy está conectado a `edge_tunnel` con IP fija mediante
  `~/.t3-repair/caddy-tailscale.override.yml` (red externa: este proyecto debe
  existir antes de recrear Caddy).
- `../caddy/Caddyfile` acepta PROXY protocol solo desde `10.203.66.2`; se
  instala con `../scripts/43-install-caddy-proxy-protocol.sh`.
