#!/usr/bin/env bash
# Collabora Online for Bulwark. Usage: ./office.sh config | up | verify | logs
# config regenerates coolwsd.xml from the pinned image's default (run after changing the image or render-config.py).
set -Eeuo pipefail
cd "$(dirname "$0")"
IMAGE=$(sed -n 's/^ *image: *//p' compose.yml)
HOSTS=(office.csmak.com office.cottonstream.es)

case ${1:-} in
config)
  cid=$(docker create "$IMAGE"); trap 'docker rm "$cid" >/dev/null' EXIT
  docker cp "$cid:/etc/coolwsd/coolwsd.xml" - | tar -xO | ./render-config.py > coolwsd.xml.new
  mv coolwsd.xml.new coolwsd.xml; echo "coolwsd.xml rendered; ./office.sh up to apply" ;;
up)
  docker compose up -d --wait --remove-orphans ;;
verify)
  ok=0; fail=0
  check() { if eval "$2" >/dev/null 2>&1; then echo "ok   $1"; ok=$((ok+1)); else echo "FAIL $1"; fail=$((fail+1)); fi; }
  check "collabora healthy" "[ \"\$(docker inspect -f '{{.State.Health.Status}}' office-collabora-1)\" = healthy ]"
  check "no host ports"     "! docker port office-collabora-1 | grep -q ."
  check "groups mode"       "grep -q 'mode=\"groups\"' coolwsd.xml"
  for h in "${HOSTS[@]}"; do
    check "$h discovery"        "curl -fsS --max-time 15 --resolve $h:443:143.20.32.134 https://$h/hosting/discovery | grep -cF https://$h/browser/"
    check "$h admin blocked"    "[ \"\$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 --resolve $h:443:143.20.32.134 https://$h/browser/dist/admin/admin.html)\" = 404 ]"
    check "$h convert blocked"  "[ \"\$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 -X POST --resolve $h:443:143.20.32.134 https://$h/cool/convert-to/pdf)\" = 404 ]"
  done
  check "bulwark csmak sees editor"       "docker exec mail-bulwark-1 node -e \"fetch('https://office.csmak.com/hosting/discovery').then(r=>process.exit(r.ok?0:1),()=>process.exit(1))\""
  check "bulwark cottonstream sees editor" "docker exec mail-bulwark-cottonstream-1 node -e \"fetch('https://office.cottonstream.es/hosting/discovery').then(r=>process.exit(r.ok?0:1),()=>process.exit(1))\""
  echo "$ok ok, $fail failed"; [[ $fail -eq 0 ]] ;;
logs)
  docker compose logs -f --tail 100 ;;
*) echo "usage: $0 config | up | verify | logs" >&2; exit 2 ;;
esac
