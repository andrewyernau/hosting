#!/usr/bin/env bash
# Copy a Cloudflare Origin CA certificate for yernau.com into central Caddy.
# The certificate must cover yernau.com and *.yernau.com. Example:
# sudo ./02-install-yernau-origin-cert.sh \
#   --certificate /secure/download/origin-yernau.pem \
#   --private-key /secure/download/origin-yernau.key
#
# This script does not reload Caddy and cannot affect live sites by itself.
set -Eeuo pipefail

CERT=
KEY=
DEST=/opt/selfhost/caddy/certs

usage() { sed -n '2,10p' "$0"; exit 2; }
while (( $# )); do
  case "$1" in
    --certificate) CERT=${2:?missing value}; shift 2 ;;
    --private-key) KEY=${2:?missing value}; shift 2 ;;
    --destination) DEST=${2:?missing value}; shift 2 ;;
    -h|--help) usage ;;
    *) printf 'Unknown argument: %s\n' "$1" >&2; usage ;;
  esac
done

[[ $EUID -eq 0 ]] || { printf 'Run this script with sudo/root.\n' >&2; exit 1; }
[[ -r $CERT && -r $KEY ]] || { printf 'Certificate and private-key files must be readable.\n' >&2; exit 1; }
command -v openssl >/dev/null || { printf 'openssl is required.\n' >&2; exit 1; }
[[ ! -e $DEST/yernau-origin.crt && ! -e $DEST/yernau-origin.key ]] || {
  printf 'Refusing to overwrite an existing yernau Origin CA certificate. Inspect it first.\n' >&2
  exit 1
}

openssl x509 -in "$CERT" -noout -checkend 0 >/dev/null
openssl x509 -in "$CERT" -noout -text | grep -Fq 'DNS:*.yernau.com' || {
  printf 'The certificate does not cover *.yernau.com. Abort.\n' >&2
  exit 1
}

cert_pub=$(openssl x509 -in "$CERT" -pubkey -noout | openssl pkey -pubin -outform DER | sha256sum | awk '{print $1}')
key_pub=$(openssl pkey -in "$KEY" -pubout -outform DER | sha256sum | awk '{print $1}')
[[ $cert_pub == "$key_pub" ]] || { printf 'Certificate and private key do not match.\n' >&2; exit 1; }

install -d -o root -g root -m 0750 "$DEST"
install -o root -g root -m 0644 "$CERT" "$DEST/yernau-origin.crt"
install -o root -g root -m 0600 "$KEY" "$DEST/yernau-origin.key"
openssl x509 -in "$DEST/yernau-origin.crt" -noout -subject -issuer -enddate -ext subjectAltName
printf '%s\n' 'Origin certificate installed. Caddy has not been reloaded and no site has been enabled.'
