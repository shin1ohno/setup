# Phase 6 — Loki Cutover

ADR: [0005 — RTX log analytics: Loki → Elasticsearch + Kibana](../0005-rtx-logs-loki-to-elasticsearch.md).

This is the removal-only diff that retires Loki from the `lxc-monitoring`
stack. Elasticsearch is now the sole sink for parsed RTX events; Kibana
provides the analyst UI (Phase 5 deliverable).

## Pre-conditions (DO NOT MERGE WITHOUT)

This PR is **DRAFT** and must not be merged until ALL of the following are
satisfied for at least 14 consecutive days after Phase 4 dual-write went
live:

1. Vector dual-write divergence < 1% — verify via Vector self-metrics
   `vector_component_sent_events_total{component_id="elasticsearch"}` vs
   `{component_id="loki"}` over the prior 24h on the Prometheus dashboard.
2. ES cluster health stays `green` (no `yellow`/`red` events) — verify in
   Kibana → Stack Monitoring or `curl -s elastic:9200/_cluster/health`.
3. Kibana query latency p95 < 500ms — Stack Monitoring → Kibana node.
4. The Phase 5 Kibana saved objects (Discover saved searches, Lens
   visualizations, Dashboard, Maps) are in active use by the operator —
   check `.kibana` index for last-access timestamps on the saved objects.

If any of the four fails, hold the PR until the underlying issue is
resolved. A premature cutover loses 30 days of Loki retention with no way
to recover.

## Files removed

- `cookbooks/lxc-monitoring/files/loki-config.yaml` — Loki server config.
- `cookbooks/lxc-monitoring/files/grafana/provisioning/datasources/loki.yml` —
  Grafana datasource provisioning that pinned `uid: loki` for the Loki
  data source. After this PR Grafana sees only the Prometheus datasource.
- `cookbooks/lxc-monitoring/files/grafana/dashboards/rtx-logs.json` —
  Grafana RTX log dashboard. Replaced by the Kibana saved objects bundled
  in Phase 5; Kibana is the analyst UI from now on.

## Cookbook changes

- `vector.toml` — `[sinks.loki]`, `[sinks.loki.labels]`, and
  `[sinks.loki.structured_metadata]` deleted. The
  `[transforms.parsed_rtx_for_es]` transform (Phase 4) becomes the sole
  consumer of `parse`.
- `docker-compose.yml` — `loki:` service deleted; `vector:` service no
  longer has `depends_on: [loki]`. Remaining services: prometheus,
  grafana, pve-exporter, blackbox, snmp-exporter, vector.
- `default.rb`:
  - `state_dir_owners` no longer creates `/data/monitoring/loki` (uid 10001).
  - New idempotent `execute "remove obsolete loki state dir"` runs
    `sudo rm -rf /data/monitoring/loki` (guarded by `only_if "test -d ..."`)
    so previously-deployed hosts have their on-disk Loki state reaped.
  - `file ... action :delete` resources for the three deleted files in the
    deploy directory; cleans up stale copies on already-converged hosts.
  - The `remote_file` resources that previously deployed `loki-config.yaml`
    and `grafana/provisioning/datasources/loki.yml` are gone; the
    dashboards loop no longer includes `rtx-logs.json`.

## Observable signals after apply

- `docker ps --filter name=monitoring-loki` returns empty.
- `ss -tlnp | grep ':3100'` (host) returns empty.
- Grafana `/api/datasources` returns only the Prometheus entry.
- Grafana `/api/search` no longer surfaces the rtx-logs dashboard.
- Vector `/metrics`: `vector_component_sent_events_total{component_id="loki"}`
  is absent; `vector_component_sent_events_total{component_id="elasticsearch"}`
  continues to increment at the prior rate (within ±10% of the pre-cutover
  baseline).
- ES indexing rate on `logs-rtx-default` continues unchanged (verifies
  Vector → ES wire path is not coupled to anything Loki provided).
- `du -sh /data/monitoring/loki` returns "No such file or directory" on
  the LXC.

## Rollback

`git revert <this-commit>` and re-apply mitamae. Loki state is gone (the
`rm -rf` is destructive) but the cookbook will recreate the empty state
directory and Loki container; ingestion resumes for new events. The 30
days of pre-cutover Loki retention is **not recoverable** post-merge —
this is the asymmetry that justifies the 14-day observation pre-condition.

If the cutover causes problems that aren't critical, prefer leaving Loki
out of service and fixing the ES/Kibana side rather than reverting; the
revert path is a last resort.
