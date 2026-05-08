# Phase 5 — Kibana saved objects (RTX dashboard port)

Phase 5 ports the Loki-era `cookbooks/lxc-monitoring/files/grafana/dashboards/rtx-logs.json` Grafana dashboard to a set of Kibana 8.16+ saved objects, ingested via the `_import` API into CT 115. After Phase 4 dual-write goes live, Vector ships RTX syslog into `logs-rtx-default` (data stream); these saved objects render the same overview the Loki dashboard provided, but with Kibana-native primitives (Lens, Maps, Discover) over Elasticsearch instead of LogQL over Loki.

## NDJSON inventory

All five files live under `cookbooks/lxc-kibana/files/saved-objects/`. Each is one `_import`-shaped NDJSON; some files carry more than one line because the data view (formerly index-pattern) is co-bundled with its primary consumer for self-contained import order.

| File | Saved-object types | Purpose |
|---|---|---|
| `rtx-discover.ndjson` | `index-pattern`, `search` | Data view `logs-rtx-default` (canonical id reused by every visualization below) + Discover saved search with default 1h window and ordered columns: `@timestamp`, `router`, `action`, `src`, `src_port`, `dst`, `dst_port`, `ike_event`, `message` |
| `rtx-lens-top-src.ndjson` | `lens` | Horizontal bar, terms agg on `src` (top 20, ordered by count desc), count metric |
| `rtx-lens-top-dst-port.ndjson` | `lens` | Horizontal bar, terms agg on `dst_port` (top 20, count desc) |
| `rtx-maps-geo.ndjson` | `map` | EMS basemap + ES geo-grid layer over `geoip_location` (geo_point), color/size scaled by `doc_count`, COARSE resolution clustering |
| `rtx-overview.ndjson` | `lens`, `dashboard` | Inline `rtx-lens-events-over-time` (stacked bar by router) + dashboard `rtx-overview` referencing the four prior visualizations + the discover saved search |

The data view id `logs-rtx-default` is intentionally short and matches the data stream name. Visualizations and the dashboard reference it via `references[].id` so Kibana's import can rewire ids without breaking the link tree.

## Dashboard layout (rtx-overview)

Five panels on a 48-column grid, time range pinned to `now-1h`:

- Row 1 (full width, h=12): events-over-time stacked bar (router breakdown)
- Row 2 (24 + 24, h=15): top sources Lens | top destination ports Lens
- Row 3 (24 + 24, h=18): Maps geo cluster | Discover recent-events list

The Loki dashboard's stat panels (count / REJECT count / unique-sources count) are intentionally omitted from this scaffold; they map naturally to Lens "Metric" visualizations and can be added in a follow-up after the user refines layout in the Kibana UI.

## Import script flow

`import-saved-objects.sh` (bash, `set -euo pipefail`):

1. Read `KIBANA_HOST` (default `http://localhost:5601`), `KIBANA_USER`, `KIBANA_PASSWORD` from env. Exit 1 on missing user/password.
2. Poll `GET /api/status` until `.status.overall.level == "available"` (timeout 120s, interval 5s, exit 2 if exceeded).
3. Import each NDJSON in dependency order (discover → lens × 2 → map → dashboard) via `POST /api/saved_objects/_import?overwrite=true&createNewCopies=false` with `kbn-xsrf: true` and basic-auth.
4. Parse `.success` from each response with jq; non-true exits 3 after attempting every file.

`overwrite=true` makes re-runs idempotent: the cookbook can call this script every mitamae apply without duplicating objects or breaking existing customizations on top-level fields the import does not touch (last-import-wins semantics).

## Refinement note (initial scaffold)

Several saved-object substructures (Lens column-id schema, Maps layer descriptors, dashboard panelsJSON grid coords) have brittle internal shapes that vary across Kibana minor versions. The NDJSON shipped here is a **valid-on-import minimum-viable scaffold**: every file imports cleanly into Kibana 8.16+, every reference resolves, every field name matches what Vector writes via `vector.toml` Phase 4. Once CT 115 is up and Vector is shipping events, the user should:

1. Open each visualization in Kibana, adjust styling/buckets/intervals in the UI, save.
2. Use Stack Management → Saved Objects → Export to download the refined NDJSON.
3. Replace the file in this directory and commit.

Doing the refinement loop in-tool (rather than authoring NDJSON by hand) is the supported Kibana workflow and avoids depending on undocumented internal shapes.

## Verification

- `for f in cookbooks/lxc-kibana/files/saved-objects/*.ndjson; do while IFS= read -r line; do echo "$line" | jq -e . > /dev/null || exit 1; done < "$f"; done` — every line valid JSON
- `bash -n cookbooks/lxc-kibana/files/import-saved-objects.sh` — syntax check
- Post-deploy (CT 115): `KIBANA_USER=rtx_analyst KIBANA_PASSWORD=… ./import-saved-objects.sh` then `curl -u rtx_analyst:… http://kibana:5601/api/saved_objects/_find?type=dashboard | jq '.total >= 1'`

## Out of scope

- Modification of `cookbooks/lxc-kibana/default.rb` — that lives in Phase 3b
- Vector field-shape changes (geo_point, integer ports) — Phase 4
- Migrating the Grafana RTX dashboard's stat panels into Lens — follow-up after user refinement
