#!/usr/bin/env bash
set -Eeuo pipefail

EXECUTE=false
SEO_ROOT=/home/andrew/hosting/search-indexing
INDEXNOW_ENDPOINT=https://api.indexnow.org/indexnow

while (($#)); do
  case "$1" in
    --execute) EXECUTE=true; shift ;;
    -h|--help)
      printf 'Usage: %s [--execute]\n' "$0"
      exit 0
      ;;
    *) printf 'Unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done

for command in curl sed; do
  command -v "$command" >/dev/null || { printf '%s is required.\n' "$command" >&2; exit 1; }
done

submit_sitemap() {
  local host=$1 key=$2 sitemap=$3 key_location=$4
  local -a urls=()

  [[ -f $sitemap ]] || { printf 'Missing sitemap: %s\n' "$sitemap" >&2; exit 1; }
  mapfile -t urls < <(sed -n 's|.*<loc>\(https://[^<]*\)</loc>.*|\1|p' "$sitemap")
  ((${#urls[@]} > 0)) || { printf 'No URLs found in %s\n' "$sitemap" >&2; exit 1; }

  printf '%s: %d URL(s)\n' "$host" "${#urls[@]}"
  printf '  %s\n' "${urls[@]}"
  $EXECUTE || return 0

  {
    printf '{"host":"%s","key":"%s","keyLocation":"%s","urlList":[' "$host" "$key" "$key_location"
    local separator=''
    local url
    for url in "${urls[@]}"; do
      printf '%s"%s"' "$separator" "$url"
      separator=,
    done
    printf ']}\n'
  } | curl --fail-with-body --silent --show-error \
    --request POST \
    --header 'Content-Type: application/json; charset=utf-8' \
    --data-binary @- \
    "$INDEXNOW_ENDPOINT"
  printf 'IndexNow accepted the %s submission.\n' "$host"
}

submit_sitemap \
  yernau.com \
  f00e3679abae4fb38562d8f5f413e7b7 \
  "$SEO_ROOT/yernau/sitemap-main.xml" \
  https://yernau.com/f00e3679abae4fb38562d8f5f413e7b7.txt

submit_sitemap \
  kubo.csmak.com \
  7ee57b73e6304805ae216e643215eff3 \
  /home/andrew/src/kubo/frontend/public/sitemap.xml \
  https://kubo.csmak.com/7ee57b73e6304805ae216e643215eff3.txt

submit_sitemap \
  ajgambitopt.com \
  f9b5b20bf7c446d2a29e893a52e046d9 \
  "$SEO_ROOT/gambito/sitemap.xml" \
  https://ajgambitopt.com/f9b5b20bf7c446d2a29e893a52e046d9.txt

if ! $EXECUTE; then
  printf 'Dry run only. Deploy the key files first, then re-run with --execute.\n'
fi
