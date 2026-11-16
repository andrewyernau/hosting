# Monitoring

Prometheus, Alertmanager and Grafana for everything hosted here, at https://monitor.tail0ca86f.ts.net, reachable only from the tailnet. Retention is 30 days. Alerts go to support@csmak.com from no-reply@csmak.com.

| Source | Path |
|---|---|
| miniPC | node-exporter, without host NIC counters so that it needs no host network |
| Containers | cAdvisor |
| VPS and HAProxy | loopback exporters on the VPS, reached by the `vps` SSH tunnel container |
| Webs, mail, game ports | blackbox-exporter on the VPS, so probes cross the public path |
| Kubo | joins `yernau-gaming_observability`; exporters stay in the Kubo stack |
| Backups | `backup-metric.sh`, an `ExecStartPost` drop-in on the backup units |

Rules:
- Nothing publishes a host port, and nothing goes through Caddy or the VPS. Never put `AllowFunnel` in `tailscale/serve.json`, even as `false`.
- The SSH user `metrics-tunnel` forwards only to 9100, 9115 and 8405 on VPS loopback. The connection is outbound, so the VPS cannot reach the LAN. Setup is `vps/setup.sh`.
- Vaultwarden is watched only through the presence of its container.
- Everything rides on the miniPC and its mail server: if the miniPC falls, no alert leaves.

Operate: `docker compose up -d`, then `./monitoring.sh verify`. Edit dashboards in `dashboards.py` and run it. New site: add it to `prometheus/prometheus.yml`, then `docker kill -s HUP monitoring-prometheus-1`.

The Tailscale identity is the external volume `monitoring_ts_state`. To re-enrol: `MONITOR_TS_AUTHKEY=... docker compose up -d --force-recreate monitor-ts`, then recreate without the variable.

After a reboot the Tailscale sidecar can restart after Grafana and leave it without network. The user timer `heal-tailnet-sidecars.timer` (`../scripts/heal-tailnet-sidecars.sh`) recreates Grafana within 2 minutes.
