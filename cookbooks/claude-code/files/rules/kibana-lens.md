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
