#!/usr/bin/env bash
set -Eeuo pipefail

GAMING_ROOT=/opt/selfhost/gaming
GAMING_ENV=$GAMING_ROOT/.env

[[ $EUID -eq 0 ]] || { printf 'Run with sudo/root.\n' >&2; exit 1; }
[[ -f $GAMING_ENV ]] || { printf 'Gaming environment not found.\n' >&2; exit 1; }

read -r -p 'SMTP host [smtppro.zoho.eu]: ' SMTP_HOST_INPUT
SMTP_HOST_INPUT=${SMTP_HOST_INPUT:-smtppro.zoho.eu}
[[ $SMTP_HOST_INPUT =~ ^[A-Za-z0-9.-]+$ ]] || { printf 'Invalid SMTP hostname.\n' >&2; exit 2; }
read -r -p 'SMTP port [465]: ' SMTP_PORT_INPUT
SMTP_PORT_INPUT=${SMTP_PORT_INPUT:-465}
[[ $SMTP_PORT_INPUT =~ ^[0-9]+$ ]] && ((SMTP_PORT_INPUT >= 1 && SMTP_PORT_INPUT <= 65535)) || { printf 'Invalid SMTP port.\n' >&2; exit 2; }
read -r -p 'SMTP username [no-reply@yernau.com]: ' SMTP_USER_INPUT
SMTP_USER_INPUT=${SMTP_USER_INPUT:-no-reply@yernau.com}
[[ $SMTP_USER_INPUT =~ ^[^[:space:]@]+@[^[:space:]@]+$ ]] || { printf 'Invalid SMTP username.\n' >&2; exit 2; }
read -r -s -p 'SMTP password or Zoho app password: ' SMTP_PASSWORD_INPUT
printf '\n'
[[ -n $SMTP_PASSWORD_INPUT ]] || { printf 'Password cannot be empty.\n' >&2; exit 2; }

update_env_value() {
  local smtp_file=$1 smtp_key=$2 smtp_value=$3 smtp_stage smtp_found=false smtp_line
  [[ $smtp_value != *$'\n'* && $smtp_value != *$'\r'* ]] || { printf 'Newlines are not allowed in environment values.\n' >&2; exit 2; }
  smtp_stage=$(mktemp "${smtp_file}.XXXXXX")
  while IFS= read -r smtp_line || [[ -n $smtp_line ]]; do
    if [[ $smtp_line == "$smtp_key="* ]]; then
      printf '%s=%s\n' "$smtp_key" "$smtp_value" >> "$smtp_stage"
      smtp_found=true
    else
      printf '%s\n' "$smtp_line" >> "$smtp_stage"
    fi
  done < "$smtp_file"
  $smtp_found || printf '%s=%s\n' "$smtp_key" "$smtp_value" >> "$smtp_stage"
  chown --reference="$smtp_file" "$smtp_stage"
  chmod --reference="$smtp_file" "$smtp_stage"
  mv -f "$smtp_stage" "$smtp_file"
}

update_env_value "$GAMING_ENV" SMTP_MODE smtp
update_env_value "$GAMING_ENV" SMTP_HOST "$SMTP_HOST_INPUT"
update_env_value "$GAMING_ENV" SMTP_PORT "$SMTP_PORT_INPUT"
update_env_value "$GAMING_ENV" SMTP_SECURE true
update_env_value "$GAMING_ENV" SMTP_USER "$SMTP_USER_INPUT"
update_env_value "$GAMING_ENV" SMTP_PASSWORD "$SMTP_PASSWORD_INPUT"
# Values containing whitespace must remain quoted in dotenv files. Compose and
# Bun strip these quotes when loading the resulting environment variable.
update_env_value "$GAMING_ENV" SMTP_FROM '"Kubo <no-reply@yernau.com>"'

unset SMTP_PASSWORD_INPUT

docker compose --project-directory "$GAMING_ROOT" --env-file "$GAMING_ENV" -f "$GAMING_ROOT/compose.production.yaml" up -d --force-recreate api worker

printf 'SMTP configured for Gaming. The secret was read interactively and was not passed as a command-line argument.\n'
# Calagopus stores its mail settings in the database; the Pelican importer carries them over.
printf 'Change the panel mailer in https://panel.kubo.csmak.com under Admin > Settings > Email.\n'
printf 'Test Gaming mail with:\n  sudo docker compose --env-file %s -f %s/compose.production.yaml exec api bun src/cli/test-mail.ts --to=YOUR_EMAIL --locale=es\n' "$GAMING_ENV" "$GAMING_ROOT"
