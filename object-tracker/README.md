# Yernau Tracker

Servicio público: https://tracker.yernau.com

Proyecto y documentación: [/home/andrew/src/object-tracker](/home/andrew/src/object-tracker/README.md).

- Compose: `/home/andrew/src/object-tracker/compose.yml`.
- Servicio Docker: `tracker-yernau-web-1`, alias de red `tracker-web`, puerto interno 8080.
- Red compartida: `selfhost_proxy`; sin puertos de host publicados.
- Caddy global: `/opt/selfhost/caddy/sites/tracker.caddy`.
- Fuente del sitio: `/home/andrew/src/object-tracker/deploy/tracker.yernau.com.caddy`.
- Despliegue: `/home/andrew/src/object-tracker/scripts/deploy.sh`.
- Salud pública: `https://tracker.yernau.com/api/health`.

El servidor solo entrega frontend TypeScript, modelos SAM 2.1 y WASM. Toda selección, seguimiento y exportación se ejecuta en el cliente. No hay base de datos ni archivos de usuario que respaldar. El hostname se añade mediante registro A igual que los demás servicios del stack.
