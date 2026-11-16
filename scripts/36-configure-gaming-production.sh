#!/usr/bin/env bash
set -Eeuo pipefail

GAMING_ROOT=/opt/selfhost/gaming
GAMING_ENV=$GAMING_ROOT/.env

[[ $EUID -eq 0 ]] || { printf 'Run with sudo/root.\n' >&2; exit 1; }
[[ -f $GAMING_ENV && -f $GAMING_ROOT/compose.production.yaml ]] || { printf 'The deployed Gaming environment was not found.\n' >&2; exit 1; }

env_value() {
  awk -F= -v key="$1" '$1 == key { sub(/^[^=]*=/, ""); value=$0 } END { gsub(/^"|"$/, "", value); print value }' "$GAMING_ENV"
}

[[ $(env_value SMTP_MODE) == smtp && -n $(env_value SMTP_HOST) && -n $(env_value SMTP_USER) && -n $(env_value SMTP_PASSWORD) ]] || {
  printf 'Transactional SMTP is incomplete. Run 34-configure-gaming-smtp.sh first.\n' >&2
  exit 1
}
[[ $(env_value CALAGOPUS_MODE) == enabled && -n $(env_value CALAGOPUS_API_KEY) ]] || {
  printf 'Calagopus provisioning must already be enabled with its dedicated API key.\n' >&2
  exit 1
}
[[ $(env_value GAME_DNS_MODE) == cloudflare && -n $(env_value CLOUDFLARE_API_TOKEN) && -n $(env_value CLOUDFLARE_ZONE_ID) && -n $(env_value GAME_ORIGIN_IPV4) ]] || {
  printf 'Automated game DNS is incomplete. Run 37-configure-gaming-dns.sh first.\n' >&2
  exit 1
}

printf '%s\n' 'This changes the next deployment from test/disabled billing to real recurring charges.'
printf '%s\n' 'Before continuing, create the LIVE products, Prices and webhook endpoint in Stripe and a production Turnstile widget restricted to kubo.csmak.com (webhook: https://kubo.csmak.com/api/v1/webhooks/stripe).'
read -r -p 'Type ENABLE LIVE BILLING to continue: ' LIVE_CONFIRMATION
[[ $LIVE_CONFIRMATION == 'ENABLE LIVE BILLING' ]] || { printf 'No changes made.\n'; exit 0; }

read -r -s -p 'Stripe live secret or restricted key (sk_live_… / rk_live_…): ' STRIPE_KEY_INPUT
printf '\n'
[[ $STRIPE_KEY_INPUT =~ ^(sk|rk)_live_[A-Za-z0-9_]+$ ]] || { printf 'A Stripe live API key is required.\n' >&2; exit 2; }
read -r -s -p 'Stripe LIVE webhook signing secret (whsec_…): ' STRIPE_WEBHOOK_INPUT
printf '\n'
[[ $STRIPE_WEBHOOK_INPUT =~ ^whsec_[A-Za-z0-9_]+$ ]] || { printf 'A live webhook signing secret is required.\n' >&2; exit 2; }

read_price() {
  local production_label=$1 production_value
  read -r -p "Stripe live Price ID for $production_label: " production_value
  [[ $production_value =~ ^price_[A-Za-z0-9_]+$ ]] || { printf 'Invalid Stripe Price ID for %s.\n' "$production_label" >&2; exit 2; }
  printf '%s' "$production_value"
}

PRICE_BASIC=$(read_price 'Basic (€3.99/month)')
PRICE_STANDARD=$(read_price 'Standard (€6.49/month)')
PRICE_PLUS=$(read_price 'Plus (€8.99/month)')
PRICE_PRO=$(read_price 'Pro (€11.99/month)')
[[ $(printf '%s\n' "$PRICE_BASIC" "$PRICE_STANDARD" "$PRICE_PLUS" "$PRICE_PRO" | sort -u | wc -l) -eq 4 ]] || {
  printf 'Every plan must use a different Stripe Price ID.\n' >&2
  exit 2
}

read -r -p 'Turnstile production site key: ' TURNSTILE_SITE_INPUT
[[ $TURNSTILE_SITE_INPUT =~ ^[A-Za-z0-9_-]{10,}$ && $TURNSTILE_SITE_INPUT != 1x000000* ]] || { printf 'A non-test Turnstile site key is required.\n' >&2; exit 2; }
read -r -s -p 'Turnstile production secret key: ' TURNSTILE_SECRET_INPUT
printf '\n'
[[ $TURNSTILE_SECRET_INPUT =~ ^[A-Za-z0-9_-]{10,}$ && $TURNSTILE_SECRET_INPUT != 1x000000* ]] || { printf 'A non-test Turnstile secret is required.\n' >&2; exit 2; }

read -r -p 'Enable Stripe automatic tax? [no]: ' AUTOMATIC_TAX_INPUT
case ${AUTOMATIC_TAX_INPUT:-no} in
  y|Y|yes|YES|s|S|si|SI|sí|SÍ) AUTOMATIC_TAX_VALUE=true ;;
  n|N|no|NO) AUTOMATIC_TAX_VALUE=false ;;
  *) printf 'Answer yes or no.\n' >&2; exit 2 ;;
esac

update_env_value() {
  local production_file=$1 production_key=$2 production_value=$3 production_stage production_found=false production_line
  [[ $production_value != *$'\n'* && $production_value != *$'\r'* ]] || { printf 'Newlines are not allowed in environment values.\n' >&2; exit 2; }
  production_stage=$(mktemp "${production_file}.XXXXXX")
  while IFS= read -r production_line || [[ -n $production_line ]]; do
    if [[ $production_line == "$production_key="* ]]; then
      printf '%s=%s\n' "$production_key" "$production_value" >> "$production_stage"
      production_found=true
    else
      printf '%s\n' "$production_line" >> "$production_stage"
    fi
  done < "$production_file"
  $production_found || printf '%s=%s\n' "$production_key" "$production_value" >> "$production_stage"
  chown --reference="$production_file" "$production_stage"
  chmod --reference="$production_file" "$production_stage"
  mv -f "$production_stage" "$production_file"
}

update_env_value "$GAMING_ENV" APP_ENV production
update_env_value "$GAMING_ENV" APP_ORIGIN https://kubo.csmak.com
update_env_value "$GAMING_ENV" STRIPE_SECRET_KEY "$STRIPE_KEY_INPUT"
update_env_value "$GAMING_ENV" STRIPE_WEBHOOK_SECRET "$STRIPE_WEBHOOK_INPUT"
update_env_value "$GAMING_ENV" STRIPE_PRICE_BASIC "$PRICE_BASIC"
update_env_value "$GAMING_ENV" STRIPE_PRICE_STANDARD "$PRICE_STANDARD"
update_env_value "$GAMING_ENV" STRIPE_PRICE_PLUS "$PRICE_PLUS"
update_env_value "$GAMING_ENV" STRIPE_PRICE_PRO "$PRICE_PRO"
update_env_value "$GAMING_ENV" STRIPE_AUTOMATIC_TAX "$AUTOMATIC_TAX_VALUE"
update_env_value "$GAMING_ENV" TURNSTILE_SITE_KEY "$TURNSTILE_SITE_INPUT"
update_env_value "$GAMING_ENV" TURNSTILE_SECRET "$TURNSTILE_SECRET_INPUT"
update_env_value "$GAMING_ENV" TURNSTILE_MODE enabled
update_env_value "$GAMING_ENV" AUTOMATIC_SERVER_DELETION true
update_env_value "$GAMING_ENV" BILLING_MODE live
update_env_value "$GAMING_ENV" PRODUCTION_READY true

unset STRIPE_KEY_INPUT STRIPE_WEBHOOK_INPUT TURNSTILE_SECRET_INPUT
docker compose --env-file "$GAMING_ENV" -f "$GAMING_ROOT/compose.production.yaml" config >/dev/null

printf '%s\n' 'Live credentials are staged, but the running containers have not been restarted.'
printf '%s\n' 'Next: sudo /home/andrew/hosting/scripts/33-deploy-gaming.sh --execute'
printf '%s\n' 'The deployment will verify Stripe prices, SMTP and Calagopus before switching the stack.'
