# mail (Stalwart, csmak.com pilot)

```text
Entrada:  MTA ──25──► VPS HAProxy (PROXY v2) ─wg─► edge-tunnel ──► Stalwart 10.203.66.4
Clientes: 465 / 587 / 993 ──► mismo camino (TLS termina en Stalwart; cert Let's Encrypt por DNS-01)
Salida:   Stalwart ─► smtp.resend.com:2465 (= 10.203.66.2) ─► edge-tunnel ─wg─► VPS HAProxy 10.66.0.1:2465 ─► smtp.resend.com:465
```

- El VPS (Nolimithost) bloquea la salida al puerto 25 y no permite PTR: todo el correo
  saliente va por Resend (dominio csmak.com verificado, región eu-west-1). Resend solo ve la IP del VPS.
- Stalwart 1.0: `config.json` solo apunta a RocksDB; el resto vive en la base de datos y se
  declara en `plan.py` (idempotente): `./plan.py | ./scli apply --stdin`.
- `./scli` = stalwart-cli contra `127.0.0.1:8080` como `admin@csmak.com`. Panel web:
  `ssh -L 8080:127.0.0.1:8080 minipc` y abrir `http://127.0.0.1:8080/admin`.
- Secretos (`secrets/`, 600): `stalwart.env` (RESEND_SMTP_KEY = clave Resend solo de envío para
  csmak.com, CLOUDFLARE_DNS_TOKEN), `admin.pass`, `andrew.pass`. Clave admin de Resend en
  `~/.config/resend/api-key`.
- DNS: Stalwart publica MX, DKIM (rota claves) y TLS-RPT en Cloudflare. A mano: `mail` A (gris),
  SPF `include:amazonses.com -all`, DMARC `p=none`, registros de Resend (`resend._domainkey`,
  `send` MX/TXT, `rsend` CNAME) y SRV `_imaps` / `_submissions`.
- Cabecera `Received`: Stalwart solo la añade en el puerto 25, así que lo enviado por los
  usuarios no lleva su IP (ni la de casa).
- Logs: `docker compose logs -f` (tracer Stdout).

Webmail: Bulwark 1.21.2 (fijado por digest) en https://webmail.csmak.com; usa JMAP en
https://mail.csmak.com (Caddy → Stalwart :8080, `/admin` devuelve 404). Sitio Caddy: `mail.caddy`
(instalar con `~/hosting/scripts/45-install-caddy-site.sh mail.caddy mail.caddy`). Stalwart toma la IP
del cliente de `X-Forwarded-For` (1 salto): Caddy la fija, salvo para Bulwark (10.203.66.5), cuya
cabecera respeta. Los admins de Stalwart entran al panel de Bulwark (`STALWART_ADMIN_ACCESS=auto`).
Edición de documentos en Archivos: Collabora en `~/hosting/office` (`WOPI_CLIENT_URL`, https://office.csmak.com y
https://office.cottonstream.es para el Bulwark de cottonstream).

Cuentas: `andrew@csmak.com` (alias de rol en `ANDREW_ALIASES` de plan.py); `no-reply@csmak.com`
(+ alias notifications@) para envíos de aplicaciones, contraseña en `secrets/no-reply.pass`; `admin@csmak.com`
solo para administrar. Resto de buzones: lista local en `users` (no versionada).

Carpetas de `andrew` (desde 2026-11-03): filtro Sieve `kubo-alias-folders`, fuente en `andrew-filters.sieve`, con
carpetas Soporte, Facturación, Legal, Seguridad y Sistema; lo dirigido a `andrew@` queda en Inbox. Se instala por JMAP
(`SieveScript/set`) entrando como `andrew@csmak.com%admin@csmak.com` con `secrets/admin.pass`, sin tocar la contraseña de
andrew. Stalwart pone `X-Spam-Status: No` en correo a alias aunque puntúe spam: por eso el filtro mira también `X-Spam-Score`.

Buzones nuevos: `./new-user <nombre>[@dominio] ["descripción"]` (dominio por defecto csmak.com) (crea solo esa cuenta, genera `secrets/<nombre>.pass`,
la anota en `users`). Contraseña nueva: borrar su `.pass` y volver a ejecutarlo. Borrar: `./scli query Account` y
`./scli delete Account <id>`. Ojo: `secrets/andrew.pass` está vacío (contraseña cambiada a mano), así que
reaplicar `plan.py` entero dejaría a andrew sin contraseña: rellenarlo antes. Límite de Resend gratis: 100 correos/día, 3.000/mes. Pendiente: copias cifradas fuera de casa, OAuth de Bulwark (para 2FA), MTA-STS/autoconfig (necesitan
HTTPS en mail.csmak.com), DMARC a `quarantine` tras unas semanas de informes limpios.

## cottonstream.es (desde 2026-11-14)

Segundo dominio en el mismo Stalwart. Zona en Cloudflare (token
minipc-domains), dominio en Red.es vía Hostinger. `./plan.py cottonstream | ./scli apply --stdin` aplica solo sus
objetos (dominio, ruta `resend-cottonstream`, estrategia), sin tocar contraseñas.

- Salida por su **propia cuenta de Resend**: `MtaOutboundStrategy` elige `resend-cottonstream` cuando
  `sender_domain == 'cottonstream.es'` (clave solo de envío en `RESEND_SMTP_KEY_COTTONSTREAM`, stalwart.env).
- DNS: Stalwart publica DKIM y TLS-RPT; **MX a mano** (`mail.cottonstream.es`, porque `mailExchangers` es global),
  igual que SPF, DMARC `p=none`, CAA, SRV y los registros de Resend.
- Certificado `mail.cottonstream.es` por ACME de Stalwart (IMAP/SMTP por SNI); Caddy sirve el HTTPS de
  `mail.` (JMAP) y `webmail.`.
- Webmail: `bulwark-cottonstream` (10.203.66.6) en https://webmail.cottonstream.es, sin acceso al panel de Stalwart.
  La sesión JMAP anuncia `https://mail.csmak.com/jmap/` (URL global de Stalwart), así que el navegador llama ahí.
- Buzones: los `@cottonstream.es` de `users` (`./new-user nombre@cottonstream.es`, contraseña en
  `secrets/nombre@cottonstream.es.pass`). `postmaster@`, `abuse@`, `hostmaster@` y `webmaster@` son alias de andrew
  (`COTTON_ANDREW_ALIASES` en plan.py).
- Cambios en rutas o en `MtaOutboundStrategy` no se aplican en caliente: tras `scli apply`, `docker compose restart stalwart`
  (el 2026-11-14 el primer envío salió con la clave de csmak y Resend lo rechazó con 550).
- 2026-11-14: el relay del VPS estaba en `MAINT (resolution)` desde el 13 a las 16:31 (smtp.resend.com pasó a ser CNAME de
  un ELB solo IPv4); arreglado con `resolve-prefer ipv4` en `vps-proxy/etc/haproxy/haproxy.cfg`. Si deja de salir correo,
  mirar primero `show stat` de `resend_smtps` en el socket de HAProxy.
