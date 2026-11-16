# Vaultwarden (solo tailnet)

URL: **https://vault.tail0ca86f.ts.net**, accesible solo desde dispositivos de la tailnet.

## Arquitectura y fronteras

```text
dispositivo tailnet ──WireGuard──► nodo Tailscale "vault" (contenedor vault-ts, 100.124.230.2)
                                     └─ tailscale serve :443 (cert LE de ts.net)
                                          └─ http://127.0.0.1:8080 ─► vaultwarden (mismo netns)
```

- Es un **nodo Tailscale propio**, no el host: no usa ni toca el `tailscale serve` del host
  (`andrew-mn56:443` → T3 Code en 127.0.0.1:3773).
- Ningún puerto publicado en el host. No pasa por Caddy, `selfhost_proxy`, `edge_tunnel` ni el VPS.
  No tiene DNS en Cloudflare.
- vaultwarden escucha solo en `127.0.0.1:8080` del netns compartido. Tailscale corre en modo kernel
  con nftables (`TS_DEBUG_FIREWALL_MODE=nftables`); en modo userspace, netstack reenviaría cualquier
  puerto de la IP 100.x a localhost y expondría HTTP plano.
- Funnel desactivado. **No añadir `AllowFunnel` a `serve.json`, ni siquiera con `false`**: Tailscale
  solo mira si el mapa tiene entradas, pone `WireIngress=true` y publica el nombre en DNS público
  apuntando a sus relays de Funnel (los relays no reenvían, pero no queremos ni eso).
- Red `vaultwarden_egress` exclusiva, solo para salida (control plane/DERP de Tailscale e iconos).
- vaultwarden: usuario 10001, rootfs read-only, `cap_drop: ALL`, `no-new-privileges`, `UMASK=077`.
- Registros cerrados (`SIGNUPS_ALLOWED=false` por defecto), invitaciones desactivadas, sin pistas
  de contraseña. **Sin `ADMIN_TOKEN`**: `/admin` desactivado y sin `config.json` que pueda
  sobrescribir el entorno.
- Imágenes fijadas por digest. Volúmenes `vaultwarden_data` y `vaultwarden_ts_state` son
  `external`: `docker compose down -v` no los borra.

## Operación

```sh
./vault.sh verify          # 14 comprobaciones de exposición/config; ejecutar tras cualquier cambio
./vault.sh up              # aplica compose.yml (siempre con registros cerrados)
./vault.sh backup          # manual; el timer de usuario lo hace a diario a las 03:30
./vault.sh restore-drill   # restaura el último backup en un volumen temporal aislado y lo arranca
```

- Backups: `~/backups/vaultwarden/vaultwarden-<UTC>.tar.gz` (modo 600, se conservan 30). Contienen el
  snapshot SQLite (API de backup online, verificado con `integrity_check`), `rsa_key.pem`,
  adjuntos y sends. Timer: `systemctl --user list-timers vaultwarden-backup.timer`.
- Están en el mismo disco que el servicio: haz también una copia fuera de esta máquina (y de vez en
  cuando un export cifrado desde el propio cliente de Bitwarden).

## Alta de la cuenta (una sola vez)

1. `./vault.sh open-signups`
2. Desde un dispositivo de la tailnet, abre https://vault.tail0ca86f.ts.net y crea la cuenta.
3. `./vault.sh close-signups` y `./vault.sh verify` (debe salir "registros cerrados").

## Migrar desde Bitwarden

1. En bitwarden.com: Herramientas → Exportar caja fuerte → formato **.json (Encrypted)**, tipo
   "protegido por contraseña". Exporta también cada organización, si tienes.
2. En https://vault.tail0ca86f.ts.net: Herramientas → Importar datos → "Bitwarden (json)".
3. Comprueba recuento y adjuntos (el export **no incluye adjuntos**: descárgalos aparte), y borra el
   fichero exportado con seguridad.
4. Clientes (navegador, móvil, escritorio): en la pantalla de login, "Autoalojado" →
   URL del servidor `https://vault.tail0ca86f.ts.net`.
5. Activa 2FA (TOTP) en la cuenta nueva. Hasta comprobar que todo está, no borres la cuenta de bitwarden.com.

## Mantenimiento de Tailscale

- La auth key fue de un solo uso y no está en disco ni en el entorno del contenedor.
- **Desactiva "key expiry" del nodo `vault`** en el admin de Tailscale (Machines → vault → Disable key
  expiry); si no, a los 180 días el nodo cae y hay que volver a dar de alta con
  `./vault.sh login <fichero-authkey>`.
- Para volver a dar de alta: `docker compose down`, `docker volume rm vaultwarden_ts_state`,
  `./vault.sh init`, `./vault.sh login <fichero>`, `./vault.sh up`.

## Actualizar

Cambia tag y digest en `compose.yml` (`docker pull vaultwarden/server:<v>` y
`docker image inspect … --format '{{index .RepoDigests 0}}'`), haz `./vault.sh backup`, luego
`./vault.sh up` y `./vault.sh verify`. Lee el changelog de vaultwarden antes de saltar versiones mayores.

- Tras un reinicio, si el sidecar de Tailscale arranca después que Vaultwarden, este se queda sin red. El timer de usuario `heal-tailnet-sidecars.timer` (`../scripts/heal-tailnet-sidecars.sh`) lo detecta cada 2 minutos y lo recrea.
