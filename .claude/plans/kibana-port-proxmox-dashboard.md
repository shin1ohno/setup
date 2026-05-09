# Plan: Port Grafana `Proxmox via Prometheus` dashboard to Kibana (Stream W)

## Context

The Grafana dashboard `Proxmox via Prometheus` (UID `Dp7Cd57Zza`, served from
CT 111 `monitoring`) presents 14 panels of PVE node + guest metrics from
`prometheus-pve-exporter`. The metrics flow into Elasticsearch via Elastic
Agent's Prometheus federation collector (PR #281). Stream T (PR #281) is
already done — confirmed 320,705 docs in
`.ds-metrics-prometheus.collector-default-2026.05.09-000001` with `pve_*`
fields populated.

## Schema (verified against ES, NOT Stream U's assumption)

Probed via `_field_caps?fields=prometheus.metrics.pve_*`:

- **Field name pattern**: `prometheus.metrics.<metric_name>` (NOT
  `prometheus.<metric>.value` — Stream U's data-view assumption was wrong
  for our actual collector schema)
- **Labels**: `prometheus.labels.<label>` keyword fields
- **Available labels for pve job**: `id`, `instance`, `job`, `name`, `node`,
  `type`, `tags`, `template`, `state`, `storage`
- **Time field**: `@timestamp`
- **Index pattern**: `metrics-prometheus.collector-*`

Verified pve_* metrics in ES:
- `pve_cpu_usage_ratio`, `pve_cpu_usage_limit`
- `pve_memory_usage_bytes`, `pve_memory_size_bytes`
- `pve_disk_usage_bytes`, `pve_disk_size_bytes`, `pve_disk_read_bytes`, `pve_disk_write_bytes`
- `pve_network_receive_bytes`, `pve_network_transmit_bytes`
- `pve_guest_info`, `pve_node_info`, `pve_storage_info`, `pve_storage_shared`
- `pve_up`, `pve_uptime_seconds`, `pve_version_info`
- `pve_lock_state`, `pve_ha_state`, `pve_onboot_status`

## Stream U schema correction needed

Stream U created data view `metrics-prometheus-collector` (id) pointing at
the same `metrics-prometheus.collector-*` pattern. The data view itself is
correct — only the *Lens visualizations* assume the wrong field-name
pattern. Stream W reuses the existing data view ID
(`metrics-prometheus-collector`) per the constraint.

This means Stream W panels will resolve while Stream U's RTX panels will
not — that is a Stream U bug, not a Stream W concern. Out of scope for
this PR.

## Panel-by-panel mapping (14 panels)

PromQL `* on(id, instance) group_left(name, type) pve_guest_info` joins
cannot be reproduced in Lens. Where the join is the only way to get the
human-readable `name` label, I drop the join and use
`prometheus.labels.name` directly (which IS present on metrics that have
been labeled by `pve_guest_info` upstream — verified via document inspection
above where `name=consent` appeared on `pve_guest_info{id=lxc/110}`).

For metrics WITHOUT the join'd labels, fall back to `prometheus.labels.id`
(always present; values like `lxc/110`, `node/pro`, `storage/local`).

| # | Grafana title | Type | Simplified Lens approach | NDJSON file |
|---|---|---|---|---|
| 19 | Resource allocation summary | table | lnsDatatable: `id`, `name`, `type` cols + last_value pve_guest_info, pve_up, pve_cpu_usage_limit, pve_memory_size_bytes, pve_disk_size_bytes | `grafana-port-proxmox-resource-table.ndjson` |
| 23 | CPU history (node) | timeseries | lnsXY line: `pve_cpu_usage_ratio` filtered to `id:node/*`, breakdown by `prometheus.labels.id` | `grafana-port-proxmox-node-cpu-history.ndjson` |
| 7 | Current CPU (node) | gauge | lnsMetric: `last_value(pve_cpu_usage_ratio)` filtered to `id:node/*`, percent format, palette | `grafana-port-proxmox-node-cpu-current.ndjson` |
| 22 | (CPU limit stat) | stat | lnsMetric: `last_value(pve_cpu_usage_limit)` filtered to `id:node/*`, breakdown by id | `grafana-port-proxmox-node-cpu-limit.ndjson` |
| 24 | Memory history (node) | timeseries | lnsXY line: `pve_memory_usage_bytes` + `pve_memory_size_bytes` filtered to `id:node/*` | `grafana-port-proxmox-node-memory-history.ndjson` |
| 8 | Current memory (node) | gauge | lnsMetric: formula `last_value(pve_memory_usage_bytes)/last_value(pve_memory_size_bytes)`, percent format, palette | `grafana-port-proxmox-node-memory-current.ndjson` |
| 20 | (Memory bytes stat) | stat | lnsMetric: `last_value(pve_memory_usage_bytes)` bytes format | `grafana-port-proxmox-node-memory-bytes.ndjson` |
| 2 | Guests CPU usage | timeseries | lnsXY line: `pve_cpu_usage_ratio` filtered to `id:(qemu/* OR lxc/*)`, breakdown by `prometheus.labels.name` | `grafana-port-proxmox-guests-cpu.ndjson` |
| 5 | Guests memory usage | timeseries | lnsXY line: `pve_memory_usage_bytes` filtered to `id:(qemu/* OR lxc/*)`, breakdown by `prometheus.labels.name`, bytes format | `grafana-port-proxmox-guests-memory.ndjson` |
| 11 | Storage usage | gauge | lnsMetric: formula `last_value(pve_disk_usage_bytes)/last_value(pve_disk_size_bytes)` filtered to `id:storage/*`, breakdown by id, percent format, palette | `grafana-port-proxmox-storage-usage.ndjson` |
| 15 | Space allocation | bargauge | lnsMetric: `last_value(pve_disk_size_bytes)` filtered to `id:storage/*`, breakdown by id, bytes format | `grafana-port-proxmox-storage-allocation.ndjson` |
| 9 | LXC guests Disk usage | timeseries | lnsXY line: formula `last_value(pve_disk_usage_bytes)/last_value(pve_disk_size_bytes)` filtered to `id:lxc/*`, breakdown by `prometheus.labels.name`, percent format | `grafana-port-proxmox-lxc-disk.ndjson` |
| 13 | Network IO/s | timeseries | lnsXY line: 2 series (`counter_rate(pve_network_receive_bytes)`, `counter_rate(pve_network_transmit_bytes)`) filtered to `id:(qemu/* OR lxc/*)`, breakdown by name, bytes/s format | `grafana-port-proxmox-network-io.ndjson` |
| 12 | Disk IO/s | timeseries | lnsXY line: formula `counter_rate(pve_disk_read_bytes)+counter_rate(pve_disk_write_bytes)` filtered to `id:(qemu/* OR lxc/*)`, breakdown by name, bytes/s format | `grafana-port-proxmox-disk-io.ndjson` |

Plus:
- `grafana-port-proxmox-overview.ndjson` — dashboard wrapping the 14 viz refs

Total: 15 NDJSON files (no separate data-view; reuse Stream U's `metrics-prometheus-collector`).

## Simplifications (vs source PromQL)

The source dashboard makes heavy use of:
- `* on (id, instance) group_left(name, type) pve_guest_info` — to attach name/type to metric series
- `and on (id, instance) pve_up == 1` — to filter to running guests only
- `instance=$instance` template variable — single-Proxmox-host filter

In Lens this becomes:
1. **No metric-to-info join**: rely on `prometheus.labels.name` being present on the metric directly (verified in ES — labels propagate via the federation scrape)
2. **No `pve_up==1` AND filter**: skip; Lens can't AND across separate metric streams. Stopped guests will show as 0/null
3. **No `$instance` filter**: there's only one PVE host (`pro`), no instance variable needed
4. **`bargauge` collapses to `lnsMetric` with breakdown** (per Stream L constraint: avoid lnsXY bar_horizontal)
5. **Multi-target stat panels** (#22, #20) become single-metric lnsMetric panels — Grafana's "multi-target stat" UI doesn't have a direct Lens analogue

Simplification summary surfaced in PR description so reviewers know what diverged.

## Filter strategy

Each panel uses an inline KQL filter to scope to the right `id` prefix:

- Node panels: `prometheus.labels.id : "node/*"`
- Guest panels (CPU/memory/network/disk-io): `prometheus.labels.id : "qemu/*" or prometheus.labels.id : "lxc/*"`
- LXC-only panel (#9): `prometheus.labels.id : "lxc/*"`
- Storage panels: `prometheus.labels.id : "storage/*"`
- Resource table (#19): no id filter — shows all guests

Plus a panel-level job filter: `prometheus.labels.job : "pve"`.

## Out of scope

- `$instance` template variable → not ported (single Proxmox host)
- `pve_up==1` filter on running-only guests → not ported (Lens limitation)
- Bargauge horizontal layout → use lnsMetric with breakdown
- Color thresholds → ported as Lens `palette` settings; exact RGB may vary
- Refresh interval default 30s ported; time range default `now-6h` ported (Grafana source default)

## Verification (Claude-runnable)

1. `bash -n cookbooks/lxc-kibana/files/import-saved-objects.sh` — syntax
2. `for f in cookbooks/lxc-kibana/files/saved-objects/grafana-port-proxmox-*.ndjson; do jq -c . "$f" > /dev/null; done` — every NDJSON is valid JSON
3. Idempotent test on CT 115:
   ```
   ssh root@pve.home.local 'pct exec 115 -- bash -lc "cd /opt/lxc-kibana && KIBANA_HOST=http://localhost:5601 KIBANA_USER=elastic KIBANA_PASSWORD=$(grep ^ELASTIC_PASSWORD /etc/elasticsearch/elasticsearch-secrets.env | cut -d= -f2-) bash /opt/lxc-kibana/import-saved-objects.sh"'
   ```
   Expected: every file imports `success=true`. Re-run also `success=true`.
4. Dashboard loads at `http://kibana.home.local:5601/app/dashboards#/view/grafana-port-proxmox-overview`. Panels resolve immediately (Stream T data is live).

## Files

```
cookbooks/lxc-kibana/files/saved-objects/
├── grafana-port-proxmox-resource-table.ndjson         (NEW)
├── grafana-port-proxmox-node-cpu-history.ndjson       (NEW)
├── grafana-port-proxmox-node-cpu-current.ndjson       (NEW)
├── grafana-port-proxmox-node-cpu-limit.ndjson         (NEW)
├── grafana-port-proxmox-node-memory-history.ndjson    (NEW)
├── grafana-port-proxmox-node-memory-current.ndjson    (NEW)
├── grafana-port-proxmox-node-memory-bytes.ndjson      (NEW)
├── grafana-port-proxmox-guests-cpu.ndjson             (NEW)
├── grafana-port-proxmox-guests-memory.ndjson          (NEW)
├── grafana-port-proxmox-storage-usage.ndjson          (NEW)
├── grafana-port-proxmox-storage-allocation.ndjson     (NEW)
├── grafana-port-proxmox-lxc-disk.ndjson               (NEW)
├── grafana-port-proxmox-network-io.ndjson             (NEW)
├── grafana-port-proxmox-disk-io.ndjson                (NEW)
└── grafana-port-proxmox-overview.ndjson               (NEW dashboard)

cookbooks/lxc-kibana/files/import-saved-objects.sh     (UPDATED — add 15 entries to ordered[])
```

Dashboard ID: `grafana-port-proxmox-overview`
