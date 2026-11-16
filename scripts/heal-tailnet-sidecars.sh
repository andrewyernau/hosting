#!/usr/bin/env bash
# Apps that share a Tailscale sidecar's network namespace lose their network when the sidecar
# restarts after them (seen at boot, when tailscaled starts before the network is ready).
# Recreate any such app so it joins the sidecar's current namespace. Run by a user timer.
set -Eeuo pipefail

# compose dir | sidecar container | app service | app container
PAIRS=(
  "$HOME/hosting/vaultwarden|vaultwarden-vault-ts-1|vaultwarden|vaultwarden-vaultwarden-1"
  "$HOME/hosting/monitoring|monitoring-monitor-ts-1|grafana|monitoring-grafana-1"
  "$HOME/hosting/orbit|orbit-orbit-ts-1|orbit|orbit-orbit-1"
)

started() { docker inspect -f '{{.State.StartedAt}}' "$1" 2>/dev/null || true; }
running() { [[ $(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null) == true ]]; }

for pair in "${PAIRS[@]}"; do
  IFS='|' read -r dir sidecar service app <<<"$pair"
  running "$sidecar" && running "$app" || continue
  # RFC 3339 timestamps of the same daemon sort lexically.
  if [[ $(started "$app") < $(started "$sidecar") ]]; then
    printf '%s started before %s restarted; recreating it.\n' "$app" "$sidecar"
    (cd "$dir" && docker compose up -d --no-deps --force-recreate "$service")
  fi
done
