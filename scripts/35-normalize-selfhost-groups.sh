#!/usr/bin/env bash
set -Eeuo pipefail

SELFHOST_ROOT=/opt/selfhost
TARGET_GROUP=selfhost
EXECUTE=false

while (($#)); do
  case "$1" in
    --execute) EXECUTE=true; shift ;;
    -h|--help)
      printf 'Usage: sudo %s [--execute]\n' "$0"
      printf 'Audits or normalizes group ownership below %s.\n' "$SELFHOST_ROOT"
      exit 0
      ;;
    *) printf 'Unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done

[[ $EUID -eq 0 ]] || { printf 'Run with sudo/root.\n' >&2; exit 1; }
[[ -d $SELFHOST_ROOT && $SELFHOST_ROOT != / ]] || { printf 'Refusing unsafe root: %s\n' "$SELFHOST_ROOT" >&2; exit 1; }
getent group "$TARGET_GROUP" >/dev/null || { printf 'Required group does not exist: %s\n' "$TARGET_GROUP" >&2; exit 1; }

# PostgreSQL owns this tree as its numeric container user. Timestamped copies
# made by --reset-database retain the same ownership for possible recovery.
find_scope() {
  find "$SELFHOST_ROOT" -xdev \
    \( -path "$SELFHOST_ROOT/gaming/postgres-data" \
       -o -path "$SELFHOST_ROOT/gaming/backups/postgres-data-*" \) -prune -o \
    "$@"
}

mapfile -d '' -t mismatches < <(find_scope ! -group "$TARGET_GROUP" -print0)

if ! $EXECUTE; then
  if ((${#mismatches[@]} == 0)); then
    printf 'Audit successful: every in-scope path already uses group %s.\n' "$TARGET_GROUP"
    exit 0
  fi
  printf 'Audit found %d path(s) outside group %s. Re-run with --execute to fix them:\n' "${#mismatches[@]}" "$TARGET_GROUP"
  printf '  %s\n' "${mismatches[@]}"
  exit 1
fi

# -h changes a symlink itself and never follows it. Existing user owners and
# permission bits are preserved; setgid on directories makes new children
# inherit the selfhost group.
find_scope -exec chgrp -h "$TARGET_GROUP" {} +
find_scope -type d -exec chmod g+s {} +

mapfile -d '' -t remaining < <(find_scope ! -group "$TARGET_GROUP" -print0)
if ((${#remaining[@]} != 0)); then
  printf 'Normalization incomplete; %d path(s) still have another group:\n' "${#remaining[@]}" >&2
  printf '  %s\n' "${remaining[@]}" >&2
  exit 1
fi

printf 'Normalized group ownership below %s to %s.\n' "$SELFHOST_ROOT" "$TARGET_GROUP"
printf 'Preserved user owners and skipped Gaming PostgreSQL data/current recovery copies.\n'
