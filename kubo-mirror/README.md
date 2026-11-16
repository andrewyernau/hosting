# kubo-mirror

Espejo de descargas que los instaladores de eggs de Kubo necesitan y que los ISP españoles
bloquean durante los partidos de LaLiga (IPs de Cloudflare). Hoy: `geyser-spigot.jar` y
`floodgate-spigot.jar` para el egg **Purpur + GeyserMC**.

- `sync.sh` descarga **a través de `vps-proxy`** (una sola conexión SSH multiplexada: el VPS
  limita SSH a 6 conexiones nuevas/min), comprueba el SHA-256 que publica la API de GeyserMC y
  solo publica ficheros verificados en `/opt/selfhost/caddy/sites/mirror/` (root, escrito con
  un contenedor alpine efímero).
- Caddy los sirve en `https://kubo.csmak.com/mirror/geyser/<fichero>` (bloque `handle /mirror/*`
  de `../kubo/Caddyfile.template`).
- El egg de Geyser (parche en `api/src/services/calagopus.ts` del repo de Kubo) instala desde
  el espejo, cae al origen oficial si el espejo falla y aborta la instalación si no obtiene un
  `.jar` válido, en lugar de dejar un servidor sin Geyser.

Timer de usuario (linger activo para `andrew`):

```bash
ln -sf ~/hosting/kubo-mirror/kubo-mirror.{service,timer} ~/.config/systemd/user/
systemctl --user daemon-reload && systemctl --user enable --now kubo-mirror.timer
systemctl --user start kubo-mirror.service; journalctl --user -u kubo-mirror -n 20
```
