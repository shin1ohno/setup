# Kibana Lens — verification limits + prometheus-federation gotchas

Load when building Kibana Lens visualizations / saved-object NDJSON, or importing them via the Kibana `_import` API (e.g. `cookbooks/lxc-kibana`).

## Verification limits (basic license, no browser)

On a **basic** Elasticsearch license + a build host with no browser:

- No PNG/PDF reporting (`/api/reporting/...` → 404) — a panel cannot be rendered headlessly.
- The only pre-user-review verification available:
  1. Clean `POST /api/saved_objects/_import?overwrite=true&createNewCopies=false` (`.success: true`, no `missingReferences`)
  2. ES data-presence — run the panel's equivalent aggregation directly and confirm it returns non-empty for the time range
  3. The dashboard is live → the USER eyeballs it (required before declaring done)

State this limit to the user up front: panels can't be headlessly rendered; you verify import + data presence, but a visual check catches layout / formula / agg bugs that import success does not.

## counter_rate — cannot ORDER a terms split by it

`counter_rate` compiles to an ES **pipeline aggregation** (derivative). A `terms` / multi-terms breakdown (split series) ORDERED BY a counter_rate column fails at render: "Invalid aggregation order path [-1] ... is a pipeline aggregation and cannot be used to sort the buckets." Order the terms by the underlying `max(<counter>)` column instead (busiest first). This is NOT about the X-axis — the date_histogram X-axis is fine; only the terms `orderBy` must avoid the pipeline column. (setup PR #413, rtx-snmp-throughput/errors.)

## last_value returns null on per-label-set federation docs

The elastic-agent `prometheus.collector` federation splits each metric into a separate ES doc keyed by its unique label set (metric = `prometheus.metrics.<name>`, labels = `prometheus.labels.<name>`). SNMP info-metrics (sysName, yrfRevision) and per-interface status labels (ifOperStatus, ifAdminStatus) live on DIFFERENT docs than the gauges/counters. `last_value(prometheus.labels.X)` over a parent `terms` bucket sorts ALL docs in the bucket by `@timestamp` and takes the latest — which usually LACKS field X → **null**.

Fix: give each such column a per-column Lens `filter` (`"prometheus.labels.X: *"`) so last_value only sees docs carrying that field. Use `max()` for numeric fields (it ignores null docs). Two fields from DIFFERENT label-set docs (sysName + yrfRevision; ifOperStatus + ifAdminStatus) each need their OWN per-column filter — a single shared panel query can't scope them. (setup PR #413 status table + PR #414 interfaces table.)

## Kibana 9.4 saved-object NDJSON shapes

- lens: `coreMigrationVersion "8.8.0"`, `typeMigrationVersion "8.9.0"`, top-level `references: [{id:<data-view-id>, name:"indexpattern-datasource-layer-<layerId>", type:"index-pattern"}]`
- index-pattern (data view): `coreMigrationVersion "8.16.0"`, `typeMigrationVersion "8.0.0"`
- dashboard: core `"8.8.0"` / type `"10.2.0"`; panel = `{type, gridData:{x,y,w,h,i:<idx>}, panelIndex:<idx>, panelRefName:"panel_<idx>"}`, reference name = `"<idx>:panel_<idx>"`
- SNMP TimeTicks (sysUpTime) = centiseconds → readable days via formula `max(...) / 8640000`
- Import order: data view → lenses → dashboard (so references resolve). `cookbooks/lxc-kibana/files/import-saved-objects.sh` uses an explicit ordered array — register new files THERE (it is not wired into default.rb; run it manually on the Kibana CT).

Origin: 2026-06-01 RTX SNMP dashboard (PRs #413/#414). Basic license + no browser meant two panels shipped with bugs the user caught visually (counter_rate terms-ordering; last_value null on fragmented docs).

## Manual Kibana edits must be exported back to the repo

A saved object created or edited directly in live Kibana (a new lens, a dashboard panel, a saved search) that is NOT exported to NDJSON is invisible to a fresh `_import` — a rebuilt CT renders the dashboard with a broken / missing panel reference. After any manual Kibana edit, export it back and commit:

```
curl -s -u "elastic:$PW" "http://<kibana-ip>:5601/api/saved_objects/_export" \
  -H 'kbn-xsrf: true' -H 'Content-Type: application/json' \
  -d '{"objects":[{"type":"lens","id":"<id>"}],"includeReferencesDeep":true}' \
  > cookbooks/lxc-kibana/files/saved-objects/<name>.ndjson
```

Register the file in `import-saved-objects.sh`'s ordered array (before the dashboard).

**Pre-merge check** for any dashboard saved-object PR: every `id` in each dashboard's `references` array must resolve to a committed source file AND appear in the import order. A reference with no file = a panel that breaks on fresh import. To find a live-only `id`, query `.kibana*` for it (`{"query":{"ids":{"values":["lens:<id>"]}}}`, count==1) and confirm it has no matching repo file.

Origin: 2026-06-01 PR #421 — rtx-overview-v2 referenced rtx-lens-events-over-time which existed only in live Kibana (manually created, never exported). A fresh import would have shown a broken "Events over time" panel; recovered via the `_export` API.

## match_only_text fields are not aggregatable — use a Discover saved-search, not a Lens

Fields mapped `match_only_text` (ECS `message`, parsed syslog event keywords like `ike_event`) cannot be aggregated — Lens `terms` / `top values` / split-series on them fail at render (`match_only_text fields do not support sorting and aggregations`). Check the mapping first:

```
GET <index>/_mapping/field/<field>   # "keyword" → aggregatable; "match_only_text" → NOT
```

For a panel that lists log lines keyed by such a field (IKE/IPsec events, firewall deny lines, DHCP leases), use a **Discover saved-search** panel (`type: "search"`, KQL `<field>: *` as an exists filter), mirroring the Grafana log-stream panel it replaces — NOT a Lens. Reference it in the dashboard as `type: "search"` (ref name `"<idx>:panel_<idx>"`). Only `keyword` fields support Lens `terms` (e.g. `action`, `router`, `severity`).

Origin: 2026-06-01 PR #421 — ike_event is match_only_text; the IKE/IPsec VPN panel had to be a Discover saved-search, not a Lens.
