#!/usr/bin/env bash
# Read-only inspection of a ZIP stored in a Pelican server volume.
# It never extracts, modifies, or moves the archive.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  sudo 25-inspect-zip-before-extract.sh --file /absolute/path/to/archive.zip --limit-mib 20000
  sudo 25-inspect-zip-before-extract.sh --server UUID --limit-mib 20000

The command reads the ZIP directory only. It reports its compressed and
uncompressed totals, which Wings checks before allowing "Unarchive".
EOF
}

FILE=''
LIMIT_MIB=''
SERVER=''

while (($#)); do
  case "$1" in
    --file) FILE=${2:?missing value for --file}; shift 2 ;;
    --server) SERVER=${2:?missing value for --server}; shift 2 ;;
    --limit-mib) LIMIT_MIB=${2:?missing value for --limit-mib}; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'Unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ -n $LIMIT_MIB ]] || { usage >&2; exit 2; }
if [[ -n $FILE && -n $SERVER ]]; then
  printf 'Use either --file or --server, not both.\n' >&2
  exit 2
fi
if [[ -n $SERVER ]]; then
  [[ $SERVER =~ ^[0-9a-fA-F-]{36}$ ]] || { printf 'The server UUID has an invalid format.\n' >&2; exit 2; }
  mapfile -d '' matches < <(find "/srv/pelican/volumes/$SERVER" -maxdepth 1 -type f -iname '*.zip' -print0 2>/dev/null)
  if ((${#matches[@]} != 1)); then
    printf 'Expected exactly one ZIP in this server root; found %s. Use --file to select it explicitly.\n' "${#matches[@]}" >&2
    exit 1
  fi
  FILE=${matches[0]}
fi
[[ -n $FILE ]] || { usage >&2; exit 2; }
[[ $FILE == /srv/pelican/volumes/* ]] || { printf 'Refusing a file outside /srv/pelican/volumes.\n' >&2; exit 2; }
[[ -f $FILE ]] || { printf 'ZIP file does not exist: %s\n' "$FILE" >&2; exit 1; }
[[ $LIMIT_MIB =~ ^[0-9]+$ ]] || { printf 'The limit must be an integer number of MiB.\n' >&2; exit 2; }
command -v zipinfo >/dev/null || { printf 'zipinfo is missing; install the unzip package first.\n' >&2; exit 1; }

printf '%s\n' '===== ZIP totals (read-only) ====='
printf 'Archive: %s\n' "$FILE"
zipinfo -t -- "$FILE"

printf '%s\n' '===== Relevant Wings quota ====='
printf 'Configured server limit: %s MiB\n' "$LIMIT_MIB"
printf '%s\n' 'Wings must fit the archive contents inside the server quota, in addition to files already present.'
printf '%s\n' 'If the uncompressed total approaches or exceeds this limit, Unarchive will correctly refuse it even when the host disk has plenty of free space.'
