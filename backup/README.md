# Backup del miniPC

`backup.sh run` corre cada día (`minipc-backup.timer`, unidad de usuario, 04:15) y copia al VPS, cifrado con restic:

- `pg_dumpall` de todos los Postgres, el volumen de Stalwart (pausa de segundos) y los volúmenes de MinIO/S3.
- `/opt/selfhost`, la configuración y los datos de Wings, `~/hosting`, `~/src` (sin `sync` ni artefactos de build) y `~/backups`.

No incluye `~/sync` (Syncthing) ni `~/Documents`.

## Modelo de seguridad

- La clave está en `~/.config/restic/minipc.pass` y nunca sale del miniPC: el VPS solo guarda datos cifrados.
- **Hace falta una copia offline de la clave.** Sin ella el backup es irrecuperable si se pierde el miniPC, y Vaultwarden no sirve de único sitio porque también está dentro del backup.
- `rest-server` corre en modo `--append-only` en `127.0.0.1:8000` del VPS, con el repo en `/srv/backups` (disco `vdb`). Un miniPC comprometido no puede borrar snapshots.
- Se llega por túnel SSH con el usuario `restic-tunnel`, que solo puede reenviar a ese puerto. Sin puertos públicos nuevos.
- Si `run` falla, avisa por correo a `contact@csmak.com`. Si el miniPC está apagado no llega aviso: mirar `~/.local/state/backup/last-ok`.

## Uso

```sh
./backup.sh snapshots
./backup.sh restic ls latest
./backup.sh restic restore latest --target /restore --include /data/staging   # montar /restore a mano
```

Probar una restauración: cargar `staging/pg/<contenedor>.sql` con `psql -f` en un Postgres temporal de la misma imagen.

Retención: el modo solo añadir no borra nada. Para podar hay que hacerlo desde el VPS con la clave a mano y de forma puntual.
