# Infraestructura del miniPC

Todo el tráfico público entra por `vps-proxy` (ver [`vps-proxy/README.md`](vps-proxy/README.md) y
[`edge-tunnel/README.md`](edge-tunnel/README.md)); DNS en gris y certificados Let's Encrypt del Caddy central
([`caddy/`](caddy/)). Dominios actuales: Kubo `kubo.csmak.com` (panel `panel.kubo.csmak.com`, nodo
`es1.kubo.csmak.com`, servidores `<nombre>.kubo.csmak.com`), Nutria `nutria.csmak.com`, Kebab Oriental
`kebab-oriental.com`. Los antiguos `gaming.`, `panel.`, `comidas.` y `healthtracker.yernau.com` solo redirigen.

Para instalar un site: `scripts/45-install-caddy-site.sh`. Los scripts de `scripts/archive/` son históricos
(época Pelican, Outline, AFFiNE, dominios viejos): no volver a ejecutarlos tal cual.

## Mapa de carpetas del miniPC

- `~/src/<proyecto>`: código propio, un repo git por proyecto. Desplegados: `kubo`, `nutria`, `kebab-oriental`,
  `csmak-web`, `cottonstream-web`, `gambito-web`, `object-tracker`, `portfolio-web`. Herramientas:
  `kubo-brand`, `mc-poses`. Sus `.env` no van a git.
- `~/hosting`: este repo privado, infraestructura sin secretos. Los secretos locales viven en `*/secrets/`, ignorados.
- `/opt/selfhost`: runtime de lo desplegado desde aquí (Kubo, Calagopus, portfolio, LiveSync, Caddy). Propiedad de root, con `.env` y datos.
- `~/sync`: Syncthing con DESKTOP-PC y el portátil. `code/` (`projects/`, `uni/`, `learning/`, `docs/`) y
  `work-setenova/`. Borrar aquí borra en los otros dispositivos.
- `~/backups`: dumps puntuales previos a cambios. Entra en el backup diario.
- `~/tools`: binarios y clientes sueltos (`bin/ffmpeg`, `blender.py`).

Nombres internos antiguos que se mantienen a propósito para no mover datos:

- Proyectos compose `comidas-yernau` (Kebab Oriental), `yernau-gaming` (Kubo), `aj-gambito-pt` (`~/src/gambito-web`)
  y `tracker-yernau` (`~/src/object-tracker`); `/opt/selfhost/gaming`.
- Wings usa `/etc/wings`, `/srv/wings`, `wings_nw` y `wings-game-firewall` desde el 2 de noviembre de 2026.
  Docker espera a la LAN al arrancar: [`firewall/docker-wait-lan.conf`](firewall/docker-wait-lan.conf).
- Nutria (`~/src/nutria`) usa el proyecto compose `nutria` desde el 7 de noviembre de 2026 (antes `healthtracking`).

## Contenido

| Carpeta | Qué es |
|---|---|
| [`backup/`](backup/README.md) | Backup diario cifrado (restic) al VPS |
| [`caddy/`](caddy/) | Caddy central: imagen, override y plantillas de sites |
| [`calagopus/`](calagopus/) | Panel de juegos de Kubo (Calagopus) |
| [`kubo/`](kubo/README.md) | Despliegue de producción de Kubo (`scripts/33-deploy-gaming.sh`) |
| [`kubo-mirror/`](kubo-mirror/README.md) | Espejo de descargas de Kubo |
| [`firewall/`](firewall/) | Firewall de puertos de juego de Wings y espera de Docker a la LAN |
| [`edge-tunnel/`](edge-tunnel/README.md) | Túnel WireGuard del miniPC al VPS |
| [`vps-proxy/`](vps-proxy/README.md) | HAProxy y configuración del VPS |
| [`mail/`](mail/README.md) | Stalwart y Bulwark (csmak.com, cottonstream.es) |
| [`office/`](office/README.md) | Collabora para los dos Bulwark |
| [`crm/`](crm/README.md) | Twenty CRM de cottonstream.es |
| [`monitoring/`](monitoring/README.md) | Prometheus y Grafana, solo tailnet |
| [`vaultwarden/`](vaultwarden/README.md) | Gestor de contraseñas, solo tailnet |
| [`orbit/`](orbit/README.md) | Notas, solo tailnet |
| [`livesync/`](livesync/README.md) | CouchDB para Obsidian LiveSync |
| [`portfolio/`](portfolio/) | Producción de yernau.com (`scripts/26-deploy-portfolio.sh`) |
| [`object-tracker/`](object-tracker/README.md) | tracker.yernau.com |
| [`search-indexing/`](search-indexing/) | Sitemaps, robots e IndexNow (`scripts/37`, `scripts/38`) |
| [`stack-map/`](stack-map/) | Diagrama generado de la plataforma |
| [`docs/`](docs/) | Histórico: [diseño inicial](docs/diseno-inicial.md) y [plan Proxmox aplazado](docs/proxmox-plan.md) |
