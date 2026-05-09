# Phase 5b — Kibana saved objects (auto-mitamae fleet dashboard port)

Phase 5b ports the operational `auto-mitamae-fleet` Grafana dashboard
(7 stat panels, Prometheus datasource on CT 111) to Kibana saved
objects in CT 115. Companion to Phase 5 (RTX log dashboard) and Phase 5a
(EC2 access log dashboard, PR #275).

## Status

**SHIPPED** (2026-05-09). Stream T merged via PR #281
(`elastic-agent: prometheus federation input for CT 111 (Streams U/V/W
enabler)`). The Elastic Agent on CT 110 scrapes CT 111's Prometheus
`/federate` endpoint with metric-name filter
`auto_mitamae_.*|bootstrap_lxc_creds_.*` and ships docs to data stream
`metrics-prometheus.collector-default` (320k+ docs at first verification).

The 7 lens visualizations + dashboard are committed in this PR and
verified end-to-end against ES with non-zero counts:
12 succeeded / 5 hard-fail / 13 transient / 17 active / max drift 6.

Dashboard URL:
`http://kibana.home.local:5601/app/dashboards#/view/auto-mitamae-overview`

## Source Grafana dashboard

Fetched from CT 111 Grafana via:

```
ssh root@pve.home.local "pct exec 111 -- bash -lc \\
  'gpw=\$(grep ^GF_SECURITY_ADMIN_PASSWORD= /root/deploy/monitoring/.env | cut -d= -f2-); \\
   curl -sf -u \"admin:\$gpw\" http://localhost:3000/api/dashboards/uid/auto-mitamae-fleet'"
```

UID `auto-mitamae-fleet`, 7 panels, Prometheus datasource
(uid `prometheus`).

### Required Prometheus metrics (verified on CT 111 2026-05-09)

```
auto_mitamae_last_apply_drift_commits      gauge, labels: host
auto_mitamae_last_apply_duration_seconds   gauge, labels: host
auto_mitamae_last_apply_sha_info           gauge=1, labels: host, sha
auto_mitamae_last_apply_status             gauge=1, labels: host, result
auto_mitamae_last_apply_timestamp_seconds  gauge unix-epoch, labels: host
auto_mitamae_orchestrator_expected_sha_info gauge=1, labels: commit
bootstrap_lxc_creds_last_attempt_timestamp_seconds  gauge, labels: ct
bootstrap_lxc_creds_last_result            gauge, labels: ct, result
setup_main_head_check_status               gauge=1, labels: status (ok|api_failure|parse_failure)
setup_main_head_check_timestamp_seconds    gauge unix-epoch
setup_main_head_commit_info                gauge=1, labels: commit
```

`result` enum on `auto_mitamae_last_apply_status`:
`success`, `mitamae_fail`, `ssh_unreachable`, `git_fail`,
`git_fetch_fail`, `invalid_command`, `sha_mismatch`, `lock_held`.

## Grafana → Kibana panel mapping

All 7 source panels are Grafana `stat` (single-value with thresholds /
mappings). Kibana's closest primitive is **Lens Metric** (`lnsMetric`).
Identical visual semantics: one big number, color-banded by threshold,
optional value-mapping table.

### Panel inventory (target dashboard `auto-mitamae-overview`)

| # | Title | Lens id | Query (KQL or ES\|QL — see notes) | Threshold |
|---|---|---|---|---|
| 1 | Hosts: last apply succeeded | `auto-mitamae-lens-hosts-success` | count distinct hosts where `last_apply_status.result == "success"` AND `last_apply_timestamp >= now-30m` | red 0 / yellow 1 / green ≥2 |
| 2 | Hosts: hard failing | `auto-mitamae-lens-hosts-hard-fail` | count distinct hosts where `result IN (mitamae_fail, ssh_unreachable, git_fail, git_fetch_fail, invalid_command)` AND timestamp ≥ now-30m | green 0 / red ≥1 |
| 3 | GitHub API status | `auto-mitamae-lens-github-status` | last value of `setup_main_head_check_status.label` (mapping: ok→OK green, api_failure→API FAILURE red, parse_failure→PARSE FAILURE yellow) | n/a (value mapping) |
| 4 | setup main HEAD | `auto-mitamae-lens-main-head` | last value of `setup_main_head_commit_info.commit` label (string display) | blue |
| 5 | per-host status (template var `${host}`) | `auto-mitamae-lens-per-host` | filtered by `host` selector — composite metric: status + freshness + drift + SHA-match | blue |
| 6 | Hosts: transient | `auto-mitamae-lens-hosts-transient` | count distinct hosts where `result IN (sha_mismatch, lock_held)` AND timestamp ≥ now-30m | green 0 / yellow ≥1 |
| 7 | Hosts: stale | `auto-mitamae-lens-hosts-stale` | count distinct hosts where `(now - last_apply_timestamp) > 30m` | green 0 / purple ≥1 |

### Query strategy: ES|QL over KQL

Panels 1, 2, 6 require **count distinct hosts WHERE label-filtered AND
freshness window**. Two-step bucketing in Lens formula language is
verbose and error-prone. Kibana 8.16 ships ES|QL (Elasticsearch Query
Language) which expresses these as one-liners:

```
FROM <metrics-index>
| WHERE @timestamp >= NOW() - 30 minutes
| WHERE prometheus.labels.result == "success"
| STATS unique_hosts = COUNT_DISTINCT(prometheus.labels.host)
```

Lens supports ES|QL as a datasource starting Kibana 8.11. Each panel's
query is one ES|QL statement — significantly more readable than the
formula-based equivalent.

**Decision**: use ES|QL for panels 1, 2, 6, 7 (filter + count distinct).
Use formula/last-value for panels 3, 4 (single label readback). Panel 5
is the most complex (per-host composite); fold into either ES|QL with
multiple aggregations or split into a row of 4 small Lens panels.

### Confirmed schema (post Stream T)

Stream T (PR #281) chose **Hypothesis B-equivalent** — Elastic Agent
prometheus collector metricset (not the Metricbeat module nor Vector):

```
index:    metrics-prometheus.collector-default (data stream)
fields:   prometheus.metrics.<metric_name>     (double, no .value suffix)
          prometheus.labels.host               (keyword)
          prometheus.labels.result             (keyword)
          prometheus.labels.instance / .job    (keyword)
```

Field-path probe via `_field_caps?fields=prometheus.metrics.*` confirms
all 8 metrics (`auto_mitamae_*` x6, `bootstrap_lxc_creds_*` x2) present.

Note `setup_main_head_*` metrics are NOT in the federate filter (PR
#281's regex covers `auto_mitamae_.*|bootstrap_lxc_creds_.*` only).
Panel 3 (GitHub API status) and Panel 4 (setup main HEAD commit) from
the original Grafana dashboard are therefore replaced by **Max apply
duration** and **Max drift commits** stats — operationally more useful
fleet aggregates that don't depend on the absent metrics.

The data view `metrics-prometheus-collector` (title
`metrics-prometheus.collector-*`) is created by Stream U PR #279 and
reused by Stream V — no new index-pattern NDJSON in this PR.

## Layout — `auto-mitamae-overview` dashboard

48-column grid, time range `now-30m`, refresh 30s.

```
+----------------------+----------------------+----------------------+
| 1 Hosts: succeeded   | 6 Hosts: transient   | 2 Hosts: hard fail   |  h=8
| (stat, green/red)    | (stat, yellow)       | (stat, red)          |
+----------------------+----------------------+----------------------+
| 7 Hosts: stale       | 3 GitHub API status  | 4 setup main HEAD    |  h=8
| (stat, purple)       | (stat, mapped)       | (stat, blue, string) |
+----------------------+----------------------+----------------------+
| 5 per-host status — template var ${host}, full width                |  h=12
+--------------------------------------------------------------------+
```

Top row = "fleet aggregate health" (3 panels, each 16 cols wide).
Middle row = "control-plane health" (3 panels, each 16 cols wide).
Bottom row = "drill-down" (1 wide panel, 48 cols).

Differs from Grafana layout (which had a free-form arrangement); the
3-row tile structure makes the operational priority order explicit:
fleet rollup → control-plane → per-host. This ordering matches what an
on-call operator would scan first during an incident.

## NDJSON inventory (post-Stream-T)

Files to create under `cookbooks/lxc-kibana/files/saved-objects/`:

1. `auto-mitamae-index-pattern.ndjson` — data view bound to Stream T's
   metrics index (id: `auto-mitamae-metrics`)
2. `auto-mitamae-lens-hosts-success.ndjson` (panel 1)
3. `auto-mitamae-lens-hosts-hard-fail.ndjson` (panel 2)
4. `auto-mitamae-lens-github-status.ndjson` (panel 3)
5. `auto-mitamae-lens-main-head.ndjson` (panel 4)
6. `auto-mitamae-lens-per-host.ndjson` (panel 5)
7. `auto-mitamae-lens-hosts-transient.ndjson` (panel 6)
8. `auto-mitamae-lens-hosts-stale.ndjson` (panel 7)
9. `auto-mitamae-overview.ndjson` — dashboard saved object referencing
   the 7 lens objects + index-pattern

Total 9 files. Import script `import-saved-objects.sh` extends with an
`# ---- auto-mitamae fleet dashboard ----` block at the bottom of the
`ordered=()` array, mirroring the EC2 / RTX block structure.

## Constraints

- **No manual Lens NDJSON authoring** — generate each file by:
  1. Build the visualization once in the Kibana UI (CT 115)
  2. Export via `POST /api/saved_objects/_export` with the lens id
  3. Commit the exported JSON line as the NDJSON file
  Manual JSON authoring violates the brittleness rule from PR #238 retro
  (lens internal schema changes between minor versions; UI-built objects
  always import cleanly)
- **English labels only** — title, descriptions, tooltips. Operator
  rotation may not include Japanese-readers
- **Idempotent import** — `overwrite=true&createNewCopies=false` so the
  cookbook can run on every mitamae apply

## Implementation steps (when Stream T ships)

1. Read Stream T's PR — extract index name + field-path convention
2. Fill `<TBD-stream-T>` placeholders in this doc with concrete values
3. Build each Lens visualization in CT 115 Kibana UI against the
   confirmed index (one panel at a time, verify rendering)
4. Export each saved object via `POST /api/saved_objects/_export`
5. Build the dashboard, link the 7 panels, export
6. Drop the 9 NDJSON files into
   `cookbooks/lxc-kibana/files/saved-objects/`
7. Append the auto-mitamae block to `import-saved-objects.sh` `ordered=()`
8. mitamae dry-run on dev box → apply on CT 115 → verify
   `http://kibana.home.local:5601/app/dashboards#/view/auto-mitamae-overview`
9. PR + merge

## Verification (post-deploy)

- `curl -sf http://kibana.home.local:5601/api/saved_objects/dashboard/auto-mitamae-overview`
  returns the dashboard meta (200, not 404)
- All 7 Lens panels render with non-empty data (no "No data" — same
  cause-class as the Grafana datasource UID rule from PR #156)
- Threshold colours match the Grafana original (red/green/yellow on
  panels 1, 2, 6, 7; blue on panels 4, 5; mapped value on panel 3)
- Time-range refresh on a 30s interval surfaces freshly-emitted
  metrics (verify by SIGHUP-ing one host's auto-mitamae timer and
  watching panel 1 increment)
