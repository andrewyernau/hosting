#!/usr/bin/env python3
# Writes the Grafana dashboards. Run after editing: ./dashboards.py
import json, pathlib
OUT = pathlib.Path(__file__).parent / "grafana/dashboards"

def board(uid, title, panels):
    laid, x, y, row = [], 0, 0, 0
    for i, (name, kind, w, h, exprs, unit) in enumerate(panels, 1):
        if x + w > 24: x, y, row = 0, y + row, 0
        laid.append({"id": i, "title": name, "type": kind, "gridPos": {"x": x, "y": y, "w": w, "h": h},
            "datasource": {"type": "prometheus", "uid": "prometheus"},
            "fieldConfig": {"defaults": {"unit": unit} if unit else {}, "overrides": []},
            "targets": [{"refId": chr(65 + n), "expr": e, "legendFormat": l, "instant": kind in ("stat", "bargauge")} for n, (e, l) in enumerate(exprs)]})
        x, row = x + w, max(row, h)
    (OUT / f"{uid}.json").write_text(json.dumps({"uid": uid, "title": title, "schemaVersion": 41, "refresh": "1m", "time": {"from": "now-6h", "to": "now"}, "panels": laid}, indent=2) + "\n")

NODE = 'instance=~"minipc|vps"'
board("overview", "Overview", [
    ("Services answering", "stat", 6, 4, [('sum(probe_success)', "up"), ('count(probe_success)', "total")], None),
    ("Firing alerts", "stat", 6, 4, [('count(ALERTS{alertstate="firing"}) or vector(0)', "")], None),
    ("Oldest backup", "stat", 6, 4, [('max(time() - backup_last_success_timestamp_seconds)', "")], "s"),
    ("Soonest certificate expiry", "stat", 6, 4, [('min(probe_ssl_earliest_cert_expiry - time())', "")], "s"),
    ("Availability", "bargauge", 12, 12, [('probe_success', "{{instance}}")], None),
    ("Response time", "timeseries", 12, 12, [('probe_duration_seconds{job="web"}', "{{instance}}")], "s"),
    ("Firing alerts", "table", 24, 7, [('ALERTS{alertstate="firing"}', "{{alertname}}")], None),
])
board("hosts", "Hosts", [
    ("CPU used", "timeseries", 12, 8, [(f'1 - avg by (instance) (rate(node_cpu_seconds_total{{mode="idle",{NODE}}}[5m]))', "{{instance}}")], "percentunit"),
    ("Memory used", "timeseries", 12, 8, [(f'1 - node_memory_MemAvailable_bytes{{{NODE}}} / node_memory_MemTotal_bytes', "{{instance}}")], "percentunit"),
    ("Disk used", "bargauge", 12, 8, [('1 - node_filesystem_avail_bytes{fstype!~"tmpfs|overlay|squashfs"} / node_filesystem_size_bytes', "{{instance}} {{mountpoint}}")], "percentunit"),
    ("Load", "timeseries", 12, 8, [('node_load5', "{{instance}}")], None),
    ("Temperature, miniPC", "timeseries", 12, 8, [('node_hwmon_temp_celsius{instance="minipc"}', "{{chip}} {{sensor}}")], "celsius"),
    ("VPS network", "timeseries", 12, 8, [('rate(node_network_receive_bytes_total{instance="vps",device=~"eth0|wg0"}[5m])', "{{device}} in"), ('rate(node_network_transmit_bytes_total{instance="vps",device=~"eth0|wg0"}[5m])', "{{device}} out")], "Bps"),
    ("HAProxy connections", "timeseries", 12, 8, [('haproxy_frontend_current_sessions', "{{proxy}}")], None),
    ("HAProxy traffic", "timeseries", 12, 8, [('sum by (proxy) (rate(haproxy_frontend_bytes_in_total[5m]) + rate(haproxy_frontend_bytes_out_total[5m]))', "{{proxy}}")], "Bps"),
])
P = 'container_label_com_docker_compose_project'
board("containers", "Containers", [
    ("CPU by project", "timeseries", 12, 9, [(f'sum by ({P}) (rate(container_cpu_usage_seconds_total{{name!=""}}[5m]))', f"{{{{{P}}}}}")], None),
    ("Memory by project", "timeseries", 12, 9, [(f'sum by ({P}) (container_memory_working_set_bytes{{name!=""}})', f"{{{{{P}}}}}")], "bytes"),
    ("Top memory", "bargauge", 12, 12, [('topk(15, container_memory_working_set_bytes{name!=""})', "{{name}}")], "bytes"),
    ("Restarts in 24 h", "bargauge", 12, 12, [('topk(10, changes(container_start_time_seconds{name!=""}[24h]) > 0)', "{{name}}")], None),
])
board("kubo", "Kubo", [
    ("API", "stat", 6, 4, [('up{job="gaming-api"}', "")], None),
    ("Worker", "stat", 6, 4, [('up{job="gaming-worker"}', "")], None),
    ("PostgreSQL", "stat", 6, 4, [('pg_up', "")], None),
    ("Jobs pending", "stat", 6, 4, [('yernau_gaming_jobs_pending', "")], None),
    ("Requests by status", "timeseries", 12, 8, [('sum by (status) (rate(yernau_gaming_http_requests_total[5m]))', "{{status}}")], "reqps"),
    ("Request duration p95", "timeseries", 12, 8, [('histogram_quantile(0.95, sum by (le) (rate(yernau_gaming_http_request_duration_seconds_bucket[5m])))', "p95")], "s"),
    ("Job outcomes", "timeseries", 12, 8, [('sum by (kind, outcome) (increase(yernau_gaming_job_outcomes_total[15m]))', "{{kind}} {{outcome}}")], None),
    ("Rate limited", "timeseries", 12, 8, [('sum by (scope) (rate(yernau_gaming_rate_limited_total[5m]))', "{{scope}}")], "reqps"),
])
