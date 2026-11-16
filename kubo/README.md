# Yernau Gaming deployment

The canonical source lives at [`/home/andrew/src/kubo`](/home/andrew/src/kubo). Runtime releases, secrets and persistent data live under `/opt/selfhost/gaming`.

## Safety boundary

- Caddy remains the only public listener on 80/443.
- `gaming-web` is the only service attached to `selfhost_proxy`.
- The API and worker reach the Calagopus panel over `gaming_panel_api`, an internal Docker network.
- PostgreSQL and `/metrics` are never exposed through Caddy.
- Stripe, Calagopus and Cloudflare secrets are server-side and are never built into Vite.

## Database lifecycle

The private-beta schema is intentionally squashed into `0000_gaming_foundation.sql`. Deploy it only onto an empty database: changing the baseline does not upgrade an already initialized PostgreSQL volume. Once the first persistent release is declared, freeze `0000` and add forward-only migrations (`0001`, `0002`, and so on); never squash or rewrite migrations that have reached persistent release data.

For an intentional private-beta reset and deployment, use:

```sh
sudo /home/andrew/hosting/scripts/33-deploy-gaming.sh --execute --reset-database
```

The reset flag stops only the Yernau Gaming Compose project and moves the previous `postgres-data` directory to a timestamped path under `/opt/selfhost/gaming/backups/`; it does not erase it. Do not use this flag after persistent release data is declared.

To audit group ownership throughout `/opt/selfhost` and then normalize it without changing user owners or PostgreSQL's required `70:70` tree:

```sh
sudo /home/andrew/hosting/scripts/35-normalize-selfhost-groups.sh
sudo /home/andrew/hosting/scripts/35-normalize-selfhost-groups.sh --execute
```

The normalization preserves existing permission bits, changes symlinks without following them, applies setgid to in-scope directories, and excludes current or archived Gaming `postgres-data` directories.

## Deploy

Run the dry-run first:

```sh
sudo /home/andrew/hosting/scripts/33-deploy-gaming.sh
```

Then create the first disabled-integration deployment:

```sh
sudo /home/andrew/hosting/scripts/33-deploy-gaming.sh --execute
```

The script generates local secrets, copies an immutable release, starts PostgreSQL/API/worker/web, installs the Caddy site and reloads the existing gateway. It does not change DNS, Cloudflare, the firewall, Wings or Calagopus.

It also builds the small local `yernau/pumpkin:0.2.1` runtime (Debian/glibc) from the official Pumpkin 0.2.1 release binary, verified against the release checksum. Up to 2026-11-01 it wrapped the Alpine/musl `sha-de8c780` image, whose musl malloc made servers sluggish and kicked players for the packet rate limit. The wrapper changes no Pumpkin code: it starts Pumpkin inside the server's writable `/home/container` volume so the generated `pumpkin.toml`, world and player data are persistent, and disables the upstream fixed-`25565` Docker healthcheck so dynamic allocations can be used. The Pumpkin egg remains Java-only and pre-release until its persistence, dynamic allocation and external connection checks pass; Bedrock requires a dedicated TCP/UDP allocation design.

The Calagopus panel attaches itself to `gaming_panel_api` with the alias `calagopus-panel-api` (see [`calagopus/compose.yml.template`](../calagopus/compose.yml.template)). The migration from Pelican, including the Gaming `.env` switch from `PELICAN_*` to `CALAGOPUS_*`, is performed by [`scripts/archive/40-migrate-pelican-to-calagopus.sh`](../scripts/archive/40-migrate-pelican-to-calagopus.sh); `33-deploy-gaming.sh` refuses to deploy while the `.env` still contains `PELICAN_*` settings.

After each intentional catalog update, update the managed eggs in place, apply the Minecraft Modrinth feature/loader metadata, create missing allocations, re-link existing users and verify live orders, idempotently:

```sh
sudo docker compose --env-file /opt/selfhost/gaming/.env -f /opt/selfhost/gaming/compose.production.yaml exec worker bun src/cli/setup-panel.ts
```

Configure both transactional mailers interactively before repairing the order so its ready notification is delivered rather than logged:

```sh
sudo /home/andrew/hosting/scripts/34-configure-gaming-smtp.sh
```

## Daily administration

### Create an email-bound invitation

Create a single-use invitation valid for 14 days inside the deployed API image:

```sh
sudo docker compose --env-file /opt/selfhost/gaming/.env -f /opt/selfhost/gaming/compose.production.yaml exec api \
  bun src/cli/create-invite.ts \
  --email=player@example.com \
  --uses=1 \
  --days=14
```

The invitation code is displayed once and only its HMAC is stored. This command does not email the code automatically: deliver it to the intended recipient through a trusted channel. After the recipient submits the code on Gaming, the configured SMTP service sends the one-use magic sign-in link. Omit `--email` only when an invitation is intentionally allowed for any address.

### Remove a provisioned server

To permanently remove one provisioned server, cancel its subscription and release its managed DNS name and panel allocation, use the exact hostname twice:

```sh
sudo docker compose --env-file /opt/selfhost/gaming/.env -f /opt/selfhost/gaming/compose.production.yaml exec worker \
  bun src/cli/purge-order.ts \
  --subdomain=example.yernau.com \
  --confirm=example.yernau.com
```

This preserves the customer account, payment references and an audit record, but leaves the order in terminal `deleted` state. It does not refund past payments. The command refuses missing or ambiguous targets and can safely be retried after a partial external failure.

### Remove a server created manually in the panel

Do **not** use `purge-order.ts` for a server created directly in the Calagopus admin area: it has no Yernau Gaming order to reconcile. First take a backup if the data is needed, then open **Admin → Servers → exact server → Delete** in `panel.yernau.com` and confirm the permanent deletion. The panel removes the server volume and releases its assigned allocation.

If you also created a DNS name manually, delete its exact Cloudflare A and SRV records separately. There is no Stripe subscription to cancel unless you created one independently. A manually created server should never be left only suspended when the purpose is to clean a test: suspension retains both its files and allocation.

### Cancel an orphan Stripe subscription

Use this only when Stripe still has a subscription but the corresponding order no longer exists locally. Repeat the exact subscription ID as confirmation:

```sh
sudo docker compose --env-file /opt/selfhost/gaming/.env -f /opt/selfhost/gaming/compose.production.yaml exec worker \
  bun src/cli/cancel-subscription.ts \
  --subscription=sub_EXAMPLE \
  --confirm=sub_EXAMPLE
```

The command reports whether it ran against `test` or `live` billing and is safe to repeat when the subscription is already cancelled. It does not delete the Stripe customer, remove a locally managed server or issue a refund. For a normal provisioned order, use `purge-order.ts` instead so the panel server, DNS and the local order are cleaned together.

### Change plan prices

Create four new recurring monthly Stripe Prices for €3.99, €6.49, €8.99 and €11.99, then update the four `STRIPE_PRICE_*` values in `/opt/selfhost/gaming/.env`. After deploying the release, synchronize the existing plan rows only after Stripe has been verified:

```sh
sudo docker compose --env-file /opt/selfhost/gaming/.env -f /opt/selfhost/gaming/compose.production.yaml exec worker \
  bun src/cli/sync-plan-prices.ts \
  --confirm=UPDATE-PLAN-PRICES
```

The command refuses to update PostgreSQL if any configured Price has the wrong amount, currency, recurrence or Stripe mode. Existing subscriptions keep their current Stripe Price; the new amounts apply to new checkouts and future plan changes.

## Live billing launch

In Stripe live mode, create four active recurring monthly Prices in EUR for exactly €3.99, €6.49, €8.99 and €11.99. Create the live webhook endpoint at `https://gaming.yernau.com/api/v1/webhooks/stripe` and select only:

- `checkout.session.completed`
- `checkout.session.async_payment_succeeded`
- `checkout.session.async_payment_failed`
- `checkout.session.expired`
- `invoice.paid`
- `invoice.payment_failed`
- `invoice.payment_action_required`
- `customer.subscription.deleted`

Configure the Customer Portal to allow payment-method updates and subscription cancellation. Decide the applicable Spanish/EU tax treatment before enabling Stripe automatic tax; do not turn it on merely as a technical default. If enabled, every live Price must have an explicit inclusive or exclusive tax behavior or the production preflight will stop.

In Turnstile, create a production widget whose allowed hostname is exactly `gaming.yernau.com`. Keep the secret server-side. The application checks every token with Siteverify and requires both hostname `gaming.yernau.com` and action `magic_link`.

After transactional SMTP and Calagopus are working, stage all live credentials without exposing secrets in shell history:

```sh
sudo /home/andrew/hosting/scripts/36-configure-gaming-production.sh
sudo /home/andrew/hosting/scripts/33-deploy-gaming.sh --execute
```

The second command builds the new release, then verifies all four Stripe Prices against the expected live mode, amount, currency and monthly recurrence; checks that the default Customer Portal supports payment-method updates and cancellation; confirms the live webhook and its selected events; authenticates with SMTP; and checks the Calagopus capacity API. Containers are not replaced if preflight fails. A restricted Stripe key must therefore allow Checkout Session and Customer Portal Session creation plus read access to Prices, Portal configurations and webhook endpoints. The production gate also enables the documented 3-day payment grace and 14-day suspended-server retention lifecycle.

## Operations

- The `monitoring` profile runs only the PostgreSQL exporter. Prometheus and Grafana live in `../monitoring`.
- Produce a one-shot backup: `docker compose --profile ops ... run --rm backup`.
- Test restore against an isolated PostgreSQL database using `source/infra/backup/restore-drill.sh`.
- Inspect failed jobs with `SELECT id,kind,attempts,last_error_code FROM jobs WHERE status='failed';`.
- Review deletion-warning and retention jobs regularly; live billing automatically removes suspended servers after the documented 14-day retention period.

Before accepting the first real customer payment, obtain an appropriate legal/tax review, configure operational alert routing, confirm SPF/DKIM/DMARC, complete a restore drill and perform one low-value live purchase followed by cancellation and a refund check.
