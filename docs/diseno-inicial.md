# Diseño inicial del hosting (agosto-octubre de 2026)

> Documento histórico, sacado del README el 15 de noviembre de 2026. Describe el diseño original con
> Pelican y sus decisiones; muchos nombres, dominios y rutas ya no son los actuales. El estado vigente está
> en [`../README.md`](../README.md).

Este directorio contiene el diseño y los scripts de preparación para una
instalación Pelican + Wings. No contiene secretos, dominios, ni una política de
firewall aplicada automáticamente.

## Panel: migración de Pelican a Calagopus (octubre 2026)

`panel.yernau.com` pasa de Pelican Panel + Wings (PHP/Go) a
[Calagopus](https://calagopus.com) Panel + Wings 1.2.4 (Rust). El resto de este
documento describe el diseño original con Pelican: las fronteras (Caddy único
en 80/443, Wings con TLS propio en `node-01.yernau.com:8443`, datos en
`/srv/pelican`, red `pelican_nw`, firewall de puertos de juego) se mantienen.

Qué se conserva gracias al importador oficial de Calagopus:

- UUIDs de nodo, eggs y servidores, y el token del nodo: Wings conserva
  `/etc/pelican/config.yml` (Calagopus Wings lo lee como ruta heredada) y solo
  se sustituye el binario. Los volúmenes de `/srv/pelican` no se mueven.
- Usuarios y sus contraseñas, allocations, variables, nombre del panel y SMTP.
  Los usernames con `-` se renombran con `_` (Calagopus solo admite
  `[a-zA-Z0-9_]`, 3-15 caracteres); el login por email no cambia.
- Las API keys **no** migran: Gaming usa una nueva admin API key de Calagopus.
- El `.env` de Gaming solo cambia sus claves `PELICAN_*` por `CALAGOPUS_*`; el
  token de Cloudflare y el resto de valores se copian byte a byte (el script lo
  comprueba con un hash antes y después).

Procedimiento, cada fase en dry-run salvo `--execute`
([`scripts/archive/40-migrate-pelican-to-calagopus.sh`](../scripts/archive/40-migrate-pelican-to-calagopus.sh)):

1. `--phase deploy`: backup de Pelican (BD, config y binario de Wings) en
   `/var/backups/calagopus-migration` y despliegue interno de Calagopus en
   `/opt/selfhost/calagopus` (imágenes fijadas por digest). **No abrir** su
   pantalla de configuración inicial (OOBE). Guardar `APP_ENCRYPTION_KEY` de
   `/opt/selfhost/calagopus/.env` en el gestor de contraseñas.
2. `--phase import-check`: importación en dry-run con informe.
3. `--phase import`: importación real.
4. `--phase cutover`: para el Panel de Pelican (su BD sigue para rollback),
   cambia el site de Caddy, instala Calagopus Wings verificando su SHA-256 y
   reinicia Wings. Después: entrar en el panel, comprobar `node-01` online y
   crear la API key de Gaming con los permisos que lista el script.
5. `--phase connect-gaming`: pide la API key (oculta), reescribe el `.env` de
   Gaming, hace dump de su PostgreSQL, despliega Gaming (migración `0001`) y
   ejecuta `setup-panel.ts`.

`--phase rollback --execute` restaura Wings, Caddy y el Panel de Pelican y, si
Gaming ya se había conectado, su `.env`, release anterior y dump de BD. El
ensayo completo de importación y de la API de Gaming se hizo contra copias de
las bases de datos en una red Docker aislada antes de escribir este
procedimiento. Backup continuo del nuevo panel:
`scripts/41-backup-calagopus-panel.sh --execute`.

## Decisión para la primera etapa

Se usará **Ubuntu bare metal** para el MVP, con una separación lógica clara y
sin migrar los servicios que ya funcionan. Proxmox VE queda aplazado como una
mejora futura si se necesitan VMs privadas, snapshots o una frontera adicional
para servicios sensibles.

```text
Internet
  ├─ HTTPS ─────► Caddy central ─► Pelican Panel (plano de control)
  └─ TCP/UDP ───────────────────► Wings ─► contenedores de juegos

Pelican Panel ── TLS autenticado ──► Wings
```

Pelican administra usuarios, permisos, allocations, backups y límites por
servidor. Wings es el único componente autorizado a hablar con Docker en el
nodo de juego. Cada servidor es un contenedor con sus límites de CPU, RAM,
disco, PID y puertos configurados desde Pelican.

No se usará `network_mode: host`, contenedores privilegiados, `docker.sock`, ni
mounts de host para ningún Egg de cliente. `allowed_mounts` permanecerá vacío.

En esta única máquina el plano de control y el nodo comparten kernel, por lo
que se limita inicialmente a uso privado, amistades y pruebas. Antes de aceptar
clientes externos, el primer nodo Wings público se moverá a una máquina física
dedicada (o VM KVM dedicada) y el Panel quedará fuera de él. Esa separación
reduce de forma más efectiva el radio de impacto que dividir prematuramente
este MiniPC.

## Estado observado (2026-08-14)

- Ubuntu 26.04 LTS; es una versión soportada por la documentación actual de
  Pelican/Wings.
- AMD Ryzen 7 8745HS (8 núcleos / 16 hilos), 30 GiB de RAM y NVMe de 477 GB
  (aprox. 418 GB libres): suficiente para el MVP privado.
- Docker 29 está activo, con Caddy central en el contenedor `caddy-caddy-1`
  como único publicador actual de 80/443. Gambito usa servicios y redes Docker
  independientes; su estado se conserva antes de la migración.
- Proxmox no está instalado y no es requisito para el MVP. La configuración
  actual de Caddy y sus certificados Origin CA permanece en el host actual.

El único NVMe actual puede alojar los datos de ejecución temporalmente en
`/srv/pelican`, pero los backups locales **no son recuperación ante pérdida de
disco**. Se adoptará S3 compatible, NAS o una segunda máquina antes de dar
servicio a terceros.

## Topología objetivo

```text
Control plane (actualmente compartido; futuro host/VM independiente)
  ├─ Caddy central: único publicador de 80/443
  ├─ Pelican Panel + DB
  └─ copias de la base de datos y APP_KEY fuera del nodo

Game node N
  ├─ Wings (root, API sólo para el Panel)
  ├─ Docker bridge pelican_nw
  ├─ /srv/pelican/volumes    datos persistentes de servidores
  ├─ /srv/pelican/backups    staging local, no backup definitivo
  └─ allocations TCP/UDP explícitas por juego
```

Al añadir un nodo no se copia Docker ni datos entre hosts a mano: se instala el
SO, se ejecuta el bootstrap de nodo, se crea el nodo en Pelican, se pega su
configuración generada y se definen allocations. El Panel será siempre el
inventario de recursos y la API que usará después el servicio de provisioning.

## Convención de dominios

`ajgambitopt.com` queda reservado exclusivamente a la asociación de ajedrez.
`yernau.com` es el dominio técnico propio para servicios personales y de
hosting. La primera propuesta operativa para Pelican es `panel.yernau.com`;
el nombre del nodo (`node-01.yernau.com`) queda solo para administración,
Wings y certificados, no como marca pública.

Los servicios no relacionados con juegos son otra unidad operativa: cada uno
tiene su propio compose, red privada, datos y backup. Puede usar un dominio
del cliente (`cloud.cliente.tld`) o, si no lo tiene, un subdominio explícito
como `cloud-cliente.yernau.com`. Caddy central puede atender todos estos
FQDNs en la misma IP, pero el propietario de un servicio no recibe acceso a
Caddy, Docker, Pelican ni al host.

## Notas personales sincronizadas

AFFiNE (`notes.yernau.com`) se retiró el 9 de noviembre de 2026: lo sustituye Orbit, solo por tailnet
([`orbit/README.md`](../orbit/README.md)). La sincronización de vaults
Obsidian se despliega por separado en `livesync.yernau.com` mediante CouchDB y
el plugin Self-hosted LiveSync; nunca se publica su puerto 5984 en el host. El
script [`scripts/39-deploy-obsidian-livesync.sh`](../scripts/39-deploy-obsidian-livesync.sh)
crea un despliegue nuevo, con credenciales distintas para administración y
sincronización y con acceso de los dispositivos limitado a una sola base de
datos. El procedimiento de servidor y de incorporación del PC Windows/iPhone
está en [`livesync/README.md`](../livesync/README.md).

El gateway actual usa certificados Cloudflare Origin CA y tiene HTTPS
automático desactivado intencionadamente. Por ello cada zona de Cloudflare
requiere su propio certificado Origin CA y fichero Caddy. El de
`ajgambitopt.com` solo cubre la asociación y no se reutiliza. Para
`panel.yernau.com`, mantener el registro de Cloudflare **proxied** y usar
Full (strict); no crear un registro AAAA mientras el host no tenga IPv6 global
y filtrado correctamente. Los puertos de juego y SFTP no pasan por el proxy de
Cloudflare.

## Redes y exposición

| Tráfico | Destino | Política |
|---|---|---|
| 80/443 TCP | Caddy central / Panel | Público; TLS y rate limiting |
| 8080 TCP (Wings) | Game node | Solo IP/red del Panel, TLS |
| 2022 TCP (SFTP Wings) | Game node | Solo si se habilita; preferiblemente clientes autenticados y rate limited |
| Rangos TCP/UDP de juego | Game node | Público, pero únicamente allocations aprobadas |
| SSH / métricas / DB | Administración | VPN o CIDR administrativo; nunca público |

No se debe usar el proxy HTTP para puertos de juego. El router debe hacer NAT
del rango de juego hacia el nodo correspondiente y el firewall del host debe
ser coherente con Docker: la política de tráfico publicado se aplica también en
`DOCKER-USER`/nftables, no solo en UFW.

Para la primera máquina no hace falta una VLAN si no hay equipamiento que la
soporte. Sí se reserva desde ya la distinción de nombres y reglas:
`panel.example`, `node-01.example`, `mgmt` y `game allocations`. Al tener un
switch/router con VLANs, el Panel y Wings se unen a la VLAN de gestión y se
publican los rangos de juego en la interfaz/VLAN pública.

## Secuencia de despliegue del MVP

1. Ejecutar `scripts/00-preflight-host.sh` con `sudo` en el host real y guardar
   el informe fuera de este repositorio si contiene IPs públicas.
2. Elegir FQDN para panel y node-01; crear sus DNS y reservar en el router los
   puertos 80/443, 8080, 2022 (si procede) y los rangos de juego.
3. Conectar almacenamiento de backup externo. Hasta entonces los backups solo
   pueden considerarse copias locales de conveniencia.
4. Ejecutar `scripts/archive/10-bootstrap-game-node.sh` para preparar directorios,
   binario Wings y su unidad systemd. No activa Wings todavía.
5. Desplegar el Panel como proyecto Docker aislado usando el script incluido.
   La imagen oficial se resuelve a un digest inmutable durante el despliegue;
   usa Caddy central como proxy, no publica otro 80/443 y no reutiliza bases
   de datos de otros servicios. Pelican sigue recomendando su despliegue
   estándar mientras su modo Docker está en evolución, por lo que las futuras
   actualizaciones se harán manualmente y con backup probado.
6. Crear `node-01` en Pelican, copiar la configuración que genera, cambiar sus
   rutas a `/srv/pelican/{volumes,backups}`, validar YAML y activar Wings.
7. Definir allocations exactas, importar Eggs oficiales revisados, crear un
   servidor de prueba de bajo riesgo y comprobar límites, consola, SFTP,
   backup/restore y que no hay mounts.
8. Crear usuarios y asignarles únicamente servidores, nunca permisos de
   administrador ni acceso al host.

Tras completar el instalador, ejecutar
`scripts/archive/08-backup-pelican-panel.sh --execute` para obtener el primer dump
consistente de MariaDB y la configuración no secreta. El destino por defecto
`/var/backups/pelican` es solo staging local: copiar el directorio resultante
a un medio externo cifrado antes de tratarlo como recuperación ante desastre.

Para el nodo `node-01`, `scripts/archive/09-issue-wings-tls-cert.sh` crea un
certificado público propio mediante DNS-01. El registro `node-01.yernau.com`
debe permanecer DNS-only; el certificado Origin CA de Caddy no sirve para
Wings ni debe compartirse con él.

La configuración generada del nodo contiene un token: se copia con `sudoedit`
directamente a `/etc/pelican/config.yml`, nunca al repositorio ni a un chat.
Antes de arrancar Wings, se fijan `system.data`, `system.archive_directory` y
`system.backup_directory` bajo `/srv/pelican`, se mantiene
`allowed_mounts: []`, y se revisa con `scripts/archive/11-verify-wings-prestart.sh`.

## Controles operativos obligatorios

- Mantener Panel y Wings en versiones compatibles; actualizar primero un nodo
  de prueba y guardar backup de DB + `APP_KEY` antes de actualizar Panel.
- Exigir 2FA a administradores y usar cuentas separadas para administración.
- Limitar PID, memoria, CPU, disco y número de backups por servidor; reservar
  capacidad host (al menos 4 GiB de RAM y 15–20 % de disco al comienzo).
- No importar Eggs de fuentes no revisadas: sus imágenes, comandos de
  instalación y variables son código con privilegio operativo.
- Sin mounts de host, sin imágenes `privileged`, sin `CAP_SYS_ADMIN`, sin
  Docker socket, y sin modo host. Revisar estas propiedades en cada Egg.
- Guardar secretos solo en archivos de root/gestor de secretos; hacer copia
  cifrada de `APP_KEY`, base de datos y credenciales S3 fuera del host.
- Probar restauración cada trimestre. Un backup no probado no es un backup.

## Evolución sin reescritura

Cuando llegue `node-02`, se repiten los pasos de nodo y se registran sus
allocations. Los nuevos servidores se colocan manualmente por capacidad al
principio. Después, una aplicación propia podrá consultar inventario y límites
con la Application API de Pelican, crear recursos y asignar el usuario. No
debe modificar la base de datos de Pelican directamente.

No se introduce Kubernetes/Agones hasta que haya cargas efímeras, matchmaking,
fleets o autoscaling. Para servidores persistentes tradicionales, Pelican +
Wings mantiene una operación y recuperación mucho más simples.

## Documentación de referencia

- [Instalación de Wings](https://pelican.dev/docs/wings/install/)
- [Configuración adicional de Wings](https://pelican.dev/docs/wings/optional-config/)
- [Panel y dependencias](https://pelican.dev/docs/panel/getting-started/)
- [Backups S3/locales](https://pelican.dev/docs/panel/optional-config/)
- [API de Pelican](https://pelican.dev/docs/panel/advanced/api-docs/)

## Storefront Yernau Gaming

La implementación de `gaming.yernau.com` vive en
[`/home/andrew/src/kubo`](/home/andrew/src/kubo). Su
configuración de producción, Caddy, red privada con el panel y procedimiento de
despliegue están documentados en
[`kubo/README.md`](../kubo/README.md). El script
`scripts/33-deploy-gaming.sh` empieza siempre en modo dry-run y despliega con
Stripe y Calagopus desactivados hasta que se aporten y validen sus credenciales.

## Indexación pública

Los archivos coordinados de robots y sitemap para `yernau.com`,
`gaming.yernau.com` y `ajgambitopt.com` se mantienen en
`search-indexing/`. El script `scripts/37-deploy-search-indexing.sh` los publica
desde Caddy, fuerza los hosts canónicos sin `www` y reconstruye únicamente el frontend público de Gambito para aplicar
sus metadatos. El script es un dry-run salvo que se añada `--execute`.

También publica `search-indexing/panel` en `panel.kubo.csmak.com`: iconos,
manifest y robots de Kubo en lugar de los de Calagopus, y `X-Robots-Tag:
noindex` porque el panel es una aplicación tras login. Para no reconstruir
Gambito: `--skip-gambito-build`.

Después de publicar las claves de IndexNow, `scripts/38-submit-indexnow.sh`
extrae las URLs de los sitemaps de Yernau y Gambito y las notifica por lotes.
También es un dry-run salvo que se añada `--execute`.

## Object Tracker

`tracker.yernau.com` sirve el editor local de selección y seguimiento de objetos.
La aplicación, modelos y WASM se entregan desde un servicio independiente detrás
del Caddy global; fotos, vídeos e inferencia permanecen en el navegador.
Despliegue y rutas operativas: [object-tracker/README.md](../object-tracker/README.md).
