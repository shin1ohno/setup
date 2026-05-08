# Phase 4 — Vector dual-write to Loki + Elasticsearch

Implementation note for ADR 0005 Phase 4. Self-contained on `lxc-monitoring`
(CT 111). Depends on Phase 1b (TLS / SSM password / IAM) and Phase 3 (ES
cluster) being live for the elasticsearch sink to succeed; the cookbook
gracefully skips the auth-gated CA fetch on hosts without `pve-bootstrap-ssm`
SSM access, so apply order is decoupled.

## Files modified

| File | Change |
|---|---|
| `cookbooks/lxc-monitoring/files/vector.toml` | + `data_dir`; + `[transforms.parsed_rtx_for_es]`; + `[sinks.elasticsearch]`; existing `[sinks.loki]` gets `buffer = { type = "disk", ... }` |
| `cookbooks/lxc-monitoring/files/docker-compose.yml` | vector service: + `ELASTIC_VECTOR_PASSWORD` env, + `/data/monitoring/vector:/var/lib/vector` and `/data/monitoring/vector/elastic-ca.crt:/etc/vector/elastic-ca.crt:ro` mounts |
| `cookbooks/lxc-monitoring/files/generate_env.sh` | + `ELASTIC_VECTOR_PASSWORD=$(fetch_ssm /monitoring/elastic/vector-password)` |
| `cookbooks/lxc-monitoring/default.rb` | + `directory /data/monitoring/vector{,/buffer}` (host UID 100000 = container root); + SSM fetch of `/monitoring/elastic/ca/cert` → `/data/monitoring/vector/elastic-ca.crt` (mode 0644 root:root); + `restart monitoring` / `ensure monitoring running` `only_if` gates also test for `elastic-ca.crt` presence |

## VRL transforms

`[transforms.parsed_rtx_for_es]` consumes `parse` and reshapes for the ES
mapping (declared in Phase 3 lxc-elasticsearch cookbook, `dynamic: "strict"`):

- Port fields (`src_port`, `dst_port`, `peer_port`) — `to_int(...) ?? null`,
  gated on `exists()` so absent fields don't error
- `geoip_location` — built as `{lat, lon}` object only when both lat and
  lon convert cleanly. Partial geo_point would be rejected by ES strict
  mapping, so the transform drops the field rather than emitting partial
  data. The float values land at the top level for ES `geo_point` ingestion;
  the existing `geoip_latitude` / `geoip_longitude` string fields stay on
  the event for the Loki path's structured-metadata templating

The Loki path keeps consuming the unmodified `parse` transform. The two
sinks are entirely independent — failure / backpressure on one does not
affect the other.

## Buffer.type = disk rationale

Both sinks declare `buffer = { type = "disk", ... }` with `data_dir =
"/var/lib/vector"`. Reasons:

- Vector container restarts on every config edit (`docker compose up -d
  --force-recreate` per `~/.claude/rules/docker-compose.md`) drop in-memory
  buffer contents. Disk buffer survives the restart.
- ES sink is on a network path with TLS handshake overhead; transient
  ingest pauses (rolling ES node restart, GC pause) accumulate events
  faster than the in-memory buffer's default cap.
- Sized: Loki 500 MB (~30 min of typical RTX volume), ES 1 GB (slightly
  larger to absorb network jitter). Both `when_full = "drop_newest"` to
  prefer history during sustained backpressure.

Bind-mount `/data/monitoring/vector` is owned by host UID 100000 (= container
root in the unprivileged LXC's UID mapping) so Vector's in-container root
can write buffer pages.

## .env mode 0600 (Adversarial #6)

`generate_env.sh` already `chmod 600` the staging `.env`, and the existing
`remote_file env_output_path` resource declares `mode "0600"`. The new
`ELASTIC_VECTOR_PASSWORD` flows through the same file, so no additional
mode hardening was needed — the existing posture covers the new secret.

The ES sink uses the structured `auth = { strategy = "basic", user, password }`
block (NOT `https://user:pw@host` URL form) so the password never appears in
Vector logs. `tls.ca_file` references the bind-mounted CA cert; both
`verify_certificate = true` and `verify_hostname = true` are explicit.

## Phase 6 cutover dependency

This cookbook keeps the Loki sink active. Phase 6 will:

1. Confirm Kibana SLOs (after 2 weeks dual-write)
2. Remove `[sinks.loki]` block + the loki-specific buffer dir
3. Remove `loki` and `vector`-loki-related grafana datasource entries
4. Tear down loki container + state dir

Until Phase 6, the Loki path is the canonical query surface; the ES path
is observation-only.

## Verification

- `docker run --rm -e ELASTIC_VECTOR_PASSWORD=dummy -v $(pwd)/...vector.toml
  timberio/vector:0.45.0-alpine validate --no-environment ...` — passes
- `docker compose ... config` — passes
- `./bin/mitamae local pve/lxc-monitoring.rb --dry-run` — exit 0; new
  resources observed for vector buffer dirs + elastic-ca staging/install
  + .env regeneration (carries new ELASTIC_VECTOR_PASSWORD)
