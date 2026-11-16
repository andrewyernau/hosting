#!/usr/bin/env bash
set -Eeuo pipefail

EXECUTE=false
REBUILD_GAMBITO=true
HOSTING_ROOT=/home/andrew/hosting
SEO_SOURCE="$HOSTING_ROOT/search-indexing"
CADDY_ROOT=/opt/selfhost/caddy
CADDY_SITES="$CADDY_ROOT/sites"
GAMBITO_ROOT=/home/andrew/src/gambito-web

while (($#)); do
  case "$1" in
    --execute) EXECUTE=true; shift ;;
    --skip-gambito-build) REBUILD_GAMBITO=false; shift ;;
    -h|--help)
      printf 'Usage: sudo %s [--execute] [--skip-gambito-build]\n' "$0"
      exit 0
      ;;
    *) printf 'Unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done

[[ $EUID -eq 0 ]] || { printf 'Run with sudo/root.\n' >&2; exit 1; }
for command in docker find getent install mktemp; do
  command -v "$command" >/dev/null || { printf '%s is required.\n' "$command" >&2; exit 1; }
done
getent group selfhost >/dev/null || { printf 'Required group does not exist: selfhost\n' >&2; exit 1; }

required_files=(
  "$SEO_SOURCE/yernau/robots.txt"
  "$SEO_SOURCE/yernau/sitemap.xml"
  "$SEO_SOURCE/yernau/sitemap-main.xml"
  "$SEO_SOURCE/yernau/f00e3679abae4fb38562d8f5f413e7b7.txt"
  "$SEO_SOURCE/gaming/7ee57b73e6304805ae216e643215eff3.txt"
  "$SEO_SOURCE/notes/robots.txt"
  "$SEO_SOURCE/gambito/robots.txt"
  "$SEO_SOURCE/gambito/sitemap.xml"
  "$SEO_SOURCE/gambito/BingSiteAuth.xml"
  "$SEO_SOURCE/gambito/f9b5b20bf7c446d2a29e893a52e046d9.txt"
  "$SEO_SOURCE/panel/robots.txt"
  "$SEO_SOURCE/panel/site.webmanifest"
  "$SEO_SOURCE/panel/favicon.ico"
  "$HOSTING_ROOT/caddy/calagopus-panel.caddy.template"
  "$HOSTING_ROOT/portfolio/Caddyfile.template"
  "$HOSTING_ROOT/kubo/Caddyfile.template"
  "$GAMBITO_ROOT/infra/caddy/gambito.caddy.example"
)
for required_file in "${required_files[@]}"; do
  [[ -f $required_file ]] || { printf 'Missing required file: %s\n' "$required_file" >&2; exit 1; }
done

caddy_container=$(docker ps --filter 'name=^/caddy-caddy-1$' --format '{{.Names}}' | head -n1)
[[ -n $caddy_container ]] || { printf 'Caddy container caddy-caddy-1 was not found.\n' >&2; exit 1; }

if $REBUILD_GAMBITO; then
  [[ -f "$GAMBITO_ROOT/.env" ]] || { printf 'Missing Gambito environment file: %s/.env\n' "$GAMBITO_ROOT" >&2; exit 1; }
  docker compose --env-file "$GAMBITO_ROOT/.env" -f "$GAMBITO_ROOT/docker-compose.yml" config >/dev/null
fi

if ! $EXECUTE; then
  cat <<EOF
Dry run successful. Deployment will:
  - publish canonical robots and sitemap files for yernau.com and ajgambitopt.com
  - keep kubo.csmak.com (ex gaming.yernau.com) as its own sitemap and include it from the Yernau index
  - keep panel.kubo.csmak.com out of search results and serve Kubo icons, manifest and robots there
  - redirect both www hosts permanently to their apex canonical host
  - $($REBUILD_GAMBITO && printf 'rebuild only the Gambito frontend to publish its metadata' || printf 'leave the Gambito frontend image unchanged')
  - validate and reload the existing central Caddy
No application data, database, DNS record or certificate will be modified.
EOF
  exit 0
fi

if $REBUILD_GAMBITO; then
  docker compose --env-file "$GAMBITO_ROOT/.env" -f "$GAMBITO_ROOT/docker-compose.yml" up -d --build --no-deps frontend
fi

backup_dir=$(mktemp -d)
rollback_needed=true
cleanup() {
  if $rollback_needed; then
    for site_file in yernau-portfolio.caddy yernau-gaming.caddy gambito.caddy calagopus-panel.caddy; do
      [[ -f "$backup_dir/$site_file" ]] && install -m 0644 -o root -g selfhost "$backup_dir/$site_file" "$CADDY_SITES/$site_file"
    done
  fi
  rm -rf -- "$backup_dir"
}
trap cleanup EXIT
for site_file in yernau-portfolio.caddy yernau-gaming.caddy gambito.caddy calagopus-panel.caddy; do
  [[ -f "$CADDY_SITES/$site_file" ]] && cp "$CADDY_SITES/$site_file" "$backup_dir/$site_file"
done

install -d -o root -g selfhost -m 2755 "$CADDY_SITES/seo"
for site in yernau gaming gambito panel; do
  install -d -o root -g selfhost -m 2755 "$CADDY_SITES/seo/$site"
  while IFS= read -r -d '' source_file; do
    install -m 0644 -o root -g selfhost "$source_file" "$CADDY_SITES/seo/$site/$(basename "$source_file")"
  done < <(find "$SEO_SOURCE/$site" -maxdepth 1 -type f -print0)
done

install -m 0644 -o root -g selfhost "$HOSTING_ROOT/portfolio/Caddyfile.template" "$CADDY_SITES/yernau-portfolio.caddy"
install -m 0644 -o root -g selfhost "$HOSTING_ROOT/kubo/Caddyfile.template" "$CADDY_SITES/yernau-gaming.caddy"
install -m 0644 -o root -g selfhost "$GAMBITO_ROOT/infra/caddy/gambito.caddy.example" "$CADDY_SITES/gambito.caddy"
install -m 0644 -o root -g selfhost "$HOSTING_ROOT/caddy/calagopus-panel.caddy.template" "$CADDY_SITES/calagopus-panel.caddy"

docker exec "$caddy_container" caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
docker exec "$caddy_container" caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile
rollback_needed=false

printf 'Search indexing configuration deployed. Verify the public URLs before submitting the sitemaps.\n'
