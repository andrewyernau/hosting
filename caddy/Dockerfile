# Central Caddy with the Cloudflare DNS provider, for ACME DNS-01 (Let's Encrypt)
# behind grey-cloud records. Base images pinned by digest.
FROM caddy:2.11.4-builder-alpine@sha256:0aa610043dab5da82ad0a0268e46bb852785e6f5160f12f1c6fe3f42903d7e1b AS build
RUN xcaddy build v2.11.4 --with github.com/caddy-dns/cloudflare@v0.2.4

FROM caddy:2.11.4-alpine@sha256:5f5c8640aae01df9654968d946d8f1a56c497f1dd5c5cda4cf95ab7c14d58648
COPY --from=build /usr/bin/caddy /usr/bin/caddy
