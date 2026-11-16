# Orbit (solo tailnet)

Tareas, documentos y chat en https://orbit.tail0ca86f.ts.net (coollabsio/orbit, imagen fijada por digest en `compose.yml`).

Mismo modelo que Vaultwarden: nodo Tailscale propio `orbit`, Orbit comparte su netns y escucha en `127.0.0.1:8080`. Sin puertos en el host, sin Caddy, sin `selfhost_proxy` ni VPS. Tras cualquier cambio: `./orbit.sh verify`.

- Secretos: `secrets/orbit.env` (`ORBIT_APP_KEY`). Guardar una copia en Vaultwarden: sin ella, una restauración pierde el SMTP guardado y la 2FA. No regenerarla.
- Datos: volumen `orbit_data` (SQLite y adjuntos). `backup/backup.sh` lo pausa unos segundos y lo sube a restic. `orbit_backups` guarda las copias propias de Orbit (Admin, Storage) y las previas a migrar; es local.
- Actualizar: copia verificada en Admin, Backups; cambiar tag y digest en `compose.yml`; `./orbit.sh up`. Las migraciones no se deshacen y una versión antigua no abre una base migrada.
- Correo: Orbit no gestiona buzones aún (PR #36). SMTP saliente opcional en Admin, Settings, Email.
- `heal-tailnet-sidecars` recrea Orbit si el sidecar se reinicia después.
