# office (Collabora Online, editor de Bulwark)

https://office.csmak.com y https://office.cottonstream.es · Collabora CODE 26.04.6.1.1 (fijado por digest) · compose project `office`.

```text
navegador ─443─► VPS HAProxy ─wg─► Caddy (office.caddy) ─► office-collabora:9980 (selfhost_proxy, HTTP)
coolwsd ─► https://webmail.<dominio>/api/wopi/... (sale por la IP pública del VPS: no cabe en edge_tunnel, /29 lleno)
Bulwark ─► https://office.<dominio>/hosting/discovery (extra_hosts → Caddy 10.203.66.3)
```

- Un solo coolwsd para los dos dominios: `server_name` vacío, así que construye sus URLs con el Host de cada petición.
  Cada Bulwark apunta al suyo con `WOPI_CLIENT_URL` en `~/hosting/mail/compose.yaml`. Los documentos no se mezclan:
  cada Bulwark solo emite tokens WOPI para sus propios usuarios y coolwsd abre cada documento en su propio proceso aislado.
- Configuración en `coolwsd.xml`, generado por `./office.sh config` (`render-config.py` parchea el XML por defecto de
  la imagen): `alias_groups` en modo `groups` (solo webmail.csmak.com y webmail.cottonstream.es), SSL en Caddy
  (`termination`), sin consola de administración, `post_allow` solo loopback (nada de convert-to público), `lok_allow`
  vacío (un documento no puede leer de la LAN ni de redes Docker), `mount_jail_tree` off.
- Contenedor con `cap_drop: ALL` + `CHOWN, FOWNER, SYS_CHROOT` (jails por chroot). `no-new-privileges` rompe
  `coolforkit-caps`, por eso no se pone. Los ERR de arranque sobre CLONE_NEWUSER/coolmount son el fallback esperado.
- Sin estado: no hay volúmenes ni copias. Los archivos viven en Stalwart (Archivos de Bulwark).
- `./office.sh verify` (11 checks) después de cada cambio. Actualizar: cambiar tag y digest en `compose.yml`,
  `./office.sh config`, revisar el diff de `coolwsd.xml` y `./office.sh up`.
- Límite de CODE: unas 20 conexiones/10 documentos a la vez (aviso en pantalla si se pasa). Pide hasta `mem_limit: 2g`.
- Pendiente: clave de prueba WOPI (proof key) no generada; Bulwark no la exige.
