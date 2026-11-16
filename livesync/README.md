# Obsidian Self-hosted LiveSync

Este despliegue sirve una instancia privada de CouchDB para el plugin
Self-hosted LiveSync. La URL prevista es `https://livesync.yernau.com`.

## Propiedades del despliegue

- CouchDB no publica `5984` en el host; sólo Caddy central puede alcanzarlo por
  la red Docker `selfhost_proxy`.
- Los datos persisten bajo `/opt/selfhost/livesync/data` y las credenciales bajo
  `/opt/selfhost/livesync/.env`, ambos propiedad de `root`.
- El script crea una cuenta administradora sólo para mantenimiento y una cuenta
  distinta, limitada a una única base de datos, para los dispositivos Obsidian.
- CORS está limitado a los orígenes oficiales de Obsidian móvil/escritorio.
- Los documentos viajan cifrados de extremo a extremo únicamente si se activa
  esa opción al configurar el primer dispositivo. Las credenciales de CouchDB
  por sí solas no sustituyen ese cifrado.

## Despliegue

1. Crea el registro `livesync.yernau.com` en Cloudflare apuntando a este host,
   **proxied**, y confirma que la zona usa SSL/TLS **Full (strict)**. El
   certificado Origin existente debe incluir `*.yernau.com`.
2. En el servidor, revisa y ejecuta:

   ```bash
   cd /home/andrew/hosting/scripts
   sudo ./39-deploy-obsidian-livesync.sh
   sudo ./39-deploy-obsidian-livesync.sh --execute
   ```

3. Recupera únicamente las credenciales de sincronización (no las de
   administración) desde consola local o SSH de confianza:

   ```bash
   sudo awk -F= '/^(LIVESYNC_USER|LIVESYNC_PASSWORD|LIVESYNC_DATABASE)=/ { print }' /opt/selfhost/livesync/.env
   ```

El primer arranque descarga la imagen oficial de CouchDB y guarda su digest
inmutable. El script deja creada una base vacía y restringida; el primer
dispositivo, mediante el asistente manual de LiveSync, inicializa el formato
de sincronización y sube el vault original.

Si un primer intento falla antes de que se publique Caddy y antes de incorporar
un vault, detén el proyecto y elimina solamente `/opt/selfhost/livesync` antes
de reintentar. No uses ese procedimiento tras haber sincronizado notas.

## Incorporar el vault existente

Haz una copia íntegra del vault del PC Windows antes de activar LiveSync. No
mantengas iCloud, Obsidian Sync, Syncthing u otro sincronizador escribiendo en
ese mismo vault mientras LiveSync esté activo.

En ese PC, instala y activa **Self-hosted LiveSync** para el vault que ya tiene
las notas. En su asistente elige *I am setting this up for the first time* y
*Configure a remote manually*. Introduce:

```text
URL:      https://livesync.yernau.com
Usuario:  valor de LIVESYNC_USER
Clave:    valor de LIVESYNC_PASSWORD
Base:     valor de LIVESYNC_DATABASE
```

La comprobación de requisitos del servidor es opcional: omítela si pide acceso
administrador, pues el usuario de sincronización está restringido de forma
intencionada a esta única base de datos.

Activa cifrado de extremo a extremo y guarda esa frase de paso en tu gestor de
contraseñas. Cuando el asistente avise que sobrescribirá el servidor, acepta
sólo tras confirmar que sigues en el vault original y que la copia de seguridad
existe. Espera a que se vacíen los indicadores de progreso y crea una nota de
prueba.

Desde este primer equipo ya sincronizado, ejecuta el comando de Obsidian
`Self-hosted LiveSync: Copy settings as a new Setup URI`. Guarda el URI y su
frase de paso por canales distintos. En iPhone y en cada PC posterior crea un
vault nuevo o previamente respaldado, instala el plugin, elige *I am adding a
device to an existing synchronisation setup* e importa ese nuevo Setup URI.
No reutilices el URI inicial ni introduzcas las credenciales manualmente en
cada dispositivo.

## Mantenimiento y recuperación

El directorio de datos no es por sí solo una estrategia de backup: cópialo de
forma coherente y cifrada a otra máquina o almacenamiento. Antes de actualizar
CouchDB, haz una copia de `/opt/selfhost/livesync/data` y de
`/opt/selfhost/livesync/.env`; sin la frase de paso de cifrado del vault, un
backup de CouchDB no será legible.

Para observar el servicio:

```bash
sudo docker compose --env-file /opt/selfhost/livesync/.env -f /opt/selfhost/livesync/compose.yml ps
sudo docker logs --tail 100 livesync-couchdb
```
