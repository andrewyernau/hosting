# crm (Twenty, cottonstream.es)

https://crm.cottonstream.es · Twenty v2.58.2 (fijado por digest) · compose project `crm`.

```text
navegador ─443─► VPS HAProxy ─wg─► Caddy (crm.caddy) ─► cottonstream-crm:3000 (selfhost_proxy)
crm-server / crm-worker ─► crm-db (Postgres 16) + crm-redis (sin persistencia), red interna del proyecto
```

- `./crm.sh init` crea `secrets/db.env` y `secrets/twenty.env` una sola vez. **`ENCRYPTION_KEY` no se cambia nunca**
  (cifra las credenciales IMAP/SMTP guardadas); si hubiera que rotarla, la vieja va a `FALLBACK_ENCRYPTION_KEY`.
- `./crm.sh up` arranca y espera a healthy; `./crm.sh verify` (6 checks) después de cada cambio.
- Configuración solo por entorno (`IS_CONFIG_VARIABLES_IN_DB_ENABLED=false`), en `compose.yml`.
- Un solo workspace (`IS_MULTIWORKSPACE_ENABLED=false`): el primer registro crea el workspace y su admin; después
  solo se entra por invitación. Mientras no existe, `crm.caddy` deja pasar solo la IP de casa (bloque BOOTSTRAP).
- Correo del sistema (invitaciones, recuperar contraseña): `no-reply@cottonstream.es` por SMTP 465 a
  `mail.cottonstream.es` (Stalwart → Resend de cottonstream). La contraseña se copia de
  `~/hosting/mail/secrets/no-reply@cottonstream.es.pass` a `twenty.env` en `init`: si cambia, editar `twenty.env`.
- Buzones en el CRM: Ajustes › Cuentas › IMAP/SMTP con `mail.cottonstream.es` (IMAP 993, SMTP 465). Resuelve a la IP
  pública del VPS, así que la protección SSRF de Twenty no lo bloquea.
- Copias: `backup.sh` vuelca `crm-crm-db-1` (pg_dumpall) y guarda el volumen `crm_server_data` (adjuntos).
- Actualizar: copia verificada antes; las migraciones de Twenty no tienen vuelta atrás. Cambiar tag y digest en
  `compose.yml` y `./crm.sh up`.
