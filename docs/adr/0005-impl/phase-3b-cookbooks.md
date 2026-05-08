# Phase 3b — `lxc-elasticsearch` + `lxc-kibana` cookbooks

Phase 3b ships the two cookbooks (and four PVE entry recipes) that
configure CT 112/113/114 (Elasticsearch 8.16.0 master+data+ingest) and
CT 115 (Kibana 8.16.0). It depends on Phase 3a (LXCs created via manual
`pct create` + `terraform import`) and Phase 1b (TLS certs + 9 SSM
passwords + IAM expansion). It is a prerequisite for Phase 4 (Vector
dual-write) and Phase 5 (Kibana saved objects).

## Scope

**Created in this branch (`feat/adr0005-phase3b-es-kibana-cookbooks`):**

```
cookbooks/lxc-elasticsearch/
  default.rb
  files/
    docker-compose.yml          ES 8.16.0 single-service compose spec
    elasticsearch.yml.tmpl      cluster config (transport TLS, no HTTP TLS)
    .env.template               placeholder for SSM-fetched secrets
    generate_env.sh             SSM → .env (mode 0600)
    fetch_certs.sh              SSM → ca.crt + node.crt + node.key
    ilm-policy-rtx-7d.json      hot rollover @ 1d / 10gb → delete @ 7d
    component-templates/
      logs-rtx-mappings.json    ip / integer / match_only_text / geo_point
      logs-rtx-settings.json    1 shard / 1 replica / best_compression / ILM ref
    index-template-rtx.json     binds the two component templates + data_stream
    bootstrap-roles.json        vector_writer / grafana_reader / rtx_analyst
    bootstrap-init.sh           idempotent ILM/template/data-stream/role/user setup

cookbooks/lxc-kibana/
  default.rb
  files/
    docker-compose.yml          Kibana 8.16.0 compose spec
    kibana.yml.tmpl             ES connection + 3 encryption keys
    .env.template               placeholder
    generate_env.sh             SSM → .env (kibana password + 3 enc keys)
    fetch_ca.sh                 SSM → ca.crt (Phase 7-tls anchor; staged early)

pve/lxc-es-0.rb                 sets node_name=es-0, transport_host=192.168.1.112
pve/lxc-es-1.rb                 sets node_name=es-1, transport_host=192.168.1.113
pve/lxc-es-2.rb                 sets node_name=es-2, transport_host=192.168.1.114
pve/lxc-kibana.rb
```

**Not in this branch:** Phase 4 Vector ES sink (`vector.toml`), Phase 5
Kibana saved objects (NDJSON dashboards), Phase 6 Loki removal, Phase
7-tls HTTPS migration, Phase 7-s3 snapshot keystore.

## Cookbook layout decisions

The three ES nodes share a single cookbook (`lxc-elasticsearch`).
Per-node divergence (NODE_NAME, TRANSPORT_HOST) is parameterised
through `node[:elasticsearch][:node_name]` / `[:transport_host]` set in
the `pve/lxc-es-*.rb` entry recipes. `elasticsearch.yml.tmpl` carries
two `@@PLACEHOLDER@@` substitutions; the cookbook renders the file via
`sed` at converge time and re-renders only when the inputs diverge from
the rendered output.

The `compose_service` DSL is intentionally NOT used here. The cookbook
needs an extra step after `up -d` (the `bootstrap-init.sh` API
initialization), and encoding that ordering inline gives explicit
control over the notify chain (`render elasticsearch.yml` → `restart
elasticsearch` → `run elasticsearch bootstrap`). The DSL still applies
to lxc-kibana, which has the simpler "restart-on-config-change" shape;
inlining there too for consistency.

## ILM bootstrap order (Adversarial #8)

The bootstrap-init.sh sequences the following steps in strict order:

1. **Wait cluster YELLOW** — single-node OK during cluster formation
2. **PUT ILM policy** `logs-rtx-7d` — hot rollover @ 1d / 10 GB → delete @ 7d
3. **PUT component templates** — `logs-rtx-mappings` + `logs-rtx-settings`
4. **PUT index template** `logs-rtx` — binds the two components + sets `data_stream: {}`
5. **Create data stream** `logs-rtx-default` — explicit `PUT _data_stream/<name>` only after the index template is registered, so the initial backing index inherits the ILM policy
6. **PUT roles** — vector_writer (write on logs-rtx-*), grafana_reader (read), rtx_analyst (read + Kibana space)
7. **Drift sync users** — for each app user, probe `_security/_authenticate` with the SSM password, on 401 issue an upsert with the new password

The ordering is non-negotiable: creating the data stream before the
index template means the initial backing index is created from cluster
defaults and silently ignores the ILM policy. PUT semantics on each
endpoint are upsert (200 on first call, 200 on repeat) so the script
runs without `not_if` guards — re-runs are cheap and idempotent.

## kibana_system atomic 2-step (Adversarial #12)

The `kibana_system` built-in user's password lives in SSM at
`/monitoring/elastic/kibana-password`. ES needs to be told this value
via `_security/user/kibana_system/_password` BEFORE Kibana boots and
reads the same SSM value into `kibana.yml`'s
`elasticsearch.password`. If the order reverses, Kibana's first
authentication attempt fails and the container crash-loops.

Encoding: `bootstrap-init.sh` (lxc-elasticsearch) calls
`reset_kibana_system_password()` as part of every converge sweep. The
master-plan apply order (es-0 → es-1 → es-2 → kibana) ensures all three
ES nodes have the same kibana_system password before Kibana ever boots.
A drift-detection re-run also closes the loop if Terraform regenerates
the password later.

## Drift detection (Adversarial #14)

Every cookbook converge invokes `bootstrap-init.sh` as a "drift sweep"
(via `execute "ensure elasticsearch bootstrap drift sweep"`). Each app
user is probed with the SSM password against `_security/_authenticate`;
if the probe returns 401, the script issues a `_security/user/<name>`
upsert with the new password. This handles the rotate path: Terraform
regenerates `random_password`, pushes to SSM, the next mitamae apply
on each ES node detects the divergence and re-syncs the cluster's
internal store.

The sweep is a no-op when everything is in sync (a few hundred ms of
curl probes). It runs on every apply, not just on .env / cert changes,
so a Terraform-side rotate without any cookbook diff still propagates.

## Bind-mount UID (Adversarial #2)

Phase 3a (manual op on PVE host) chowns
`/mnt/data/elasticsearch/es-{0,1,2}` to `100000:100000`, which surfaces
as `root:root` UID 0 inside the container. The cookbook then declares
the in-container subdirs (`data/`, `logs/`, `certs/`) with `owner
"1000"` — String, not Integer (per `~/.claude/rules/ruby.md` "owner /
group must be String"). The Elastic image's elasticsearch user runs as
UID 1000; in-namespace root has CAP_CHOWN over UIDs 0..65535 inside
(↔ host UIDs 100000..165535) so the chown succeeds.

For Kibana the disk lives on rpool (50 GB, no PVE bind-mount) so the
`/data/kibana` dirs are created directly inside the LXC's own filesystem
without host-side preparation. The same UID 1000 owner pattern applies
because the Kibana image also runs as UID 1000.

## `--force-recreate` notify (`docker-compose.md` rule)

Both cookbooks use `docker compose up -d --force-recreate` on the
restart paths. Bare `up -d` is a silent no-op when the image digest +
compose spec are unchanged, so bind-mount edits to
`elasticsearch.yml` / `kibana.yml` / `.env` / certs would not take
effect on already-running containers. The initial-state path (`ensure
… running`) intentionally skips `--force-recreate` to preserve
idempotency — its `only_if` shell guard already short-circuits when
the desired services are running.

## Rolling restart serialization (Adversarial #11)

The auto-mitamae orchestrator processes hosts sequentially in
alphabetical order, so es-0 → es-1 → es-2 → kibana naturally serializes
the rolling restart. With `number_of_replicas: 1` the cluster transitions
through yellow during one node's restart, returns to green when it
rejoins, then the next node restarts. Acceptable for the current write
rate; if churn grows to a level where one node down + replica rebuild
costs a measurable query latency hit, fold a
`cluster.routing.allocation.enable: primaries` toggle around the
container restart inside the cookbook (preferred) or as an external
shell wrapper invoked by the orchestrator.

## `.env` mode 0600 (Adversarial #6)

Both cookbooks generate `.env` files with `mode "0600"` and host-side
ownership (`node[:setup][:user]`, who already owns the deploy
directory). The .env carries 6+ SSM-fetched passwords; making it world-
unreadable is mandatory. Passwords are passed to ES / Kibana via Docker
Compose's `env_file:` directive — the host OS reads .env once, sets
container env at spawn time, and the file is never opened by the
container's UID 1000 process.

`auth=basic` is used in the Vector → ES sink (Phase 4) instead of an
embedded URL like `https://vector:pw@es-0:9200`. The auth-credentials-
in-URL form leaks the password into Vector's debug/info logs on every
connection retry; `auth.user` / `auth.password` keep the secret out of
the log surface.

## Auth-gate matches the actual SSM call

`require_external_auth` in both cookbooks uses a check_command that
attempts the actual SSM read the cookbook will perform, with explicit
`--profile #{aws_profile} --region #{aws_region}` flags (matching the
.env / cert generators). Per `~/.claude/rules/ruby.md` "Auth-check gate
must match the cookbook's actual invocation profile" — `aws sts
get-caller-identity` would pass against any default profile and is a
false gate.

## Verification (Claude-runnable)

- `jq -e .` on every JSON file under `cookbooks/lxc-elasticsearch/files`
  — all parse.
- `docker compose -f cookbooks/lxc-{elasticsearch,kibana}/files/docker-compose.yml config`
  — both validate (with `cp .env.template .env` as a fixture).
- `./bin/mitamae local pve/lxc-{es-0,es-1,es-2,kibana}.rb --dry-run`
  — all four return exit 0 with no `ERROR :` lines in the output.

## Verification (user hardware)

- After Phase 3a apply: bind-mount path on PVE host has 100000:100000 UID
- After mitamae apply on es-0/1/2 (sequential):
  - `pct exec <vmid> -- docker logs elasticsearch | grep "started"` on each
  - `curl -u elastic:$PW http://192.168.1.112:9200/_cluster/health?pretty` returns `green`, 3 nodes, replica 1
  - `curl -u elastic:$PW http://192.168.1.112:9200/_data_stream/logs-rtx-default` returns the data stream metadata with `ilm_policy: logs-rtx-7d`
  - `curl -u vector_writer:$PW http://192.168.1.112:9200/_security/_authenticate` returns 200 + `username: vector_writer`
- After mitamae apply on kibana:
  - `curl -sf http://192.168.1.115:5601/api/status` returns 200 + status `available`
  - Browser → http://kibana.home.local:5601 → log in as analyst

## Open items (tracked, deferred)

- HTTP TLS (Phase 7-tls) — flips `xpack.security.http.ssl.enabled: true`,
  Kibana hosts to https://, adds
  `elasticsearch.ssl.certificateAuthorities` ref. Cert material for
  Phase 7-tls is the same node cert + CA fetched in Phase 3b, so the
  Phase 7-tls diff is config-only.
- S3 snapshot keystore (Phase 7-s3-cb) — adds
  `elasticsearch-keystore add s3.client.default.{access_key,secret_key}`
  + `PUT /_snapshot/s3-home-monitor` repo registration. Builds on the
  bootstrap-init.sh pattern.
- `cluster.routing.allocation.enable: primaries` rolling-restart toggle
  — folded only if write churn justifies the complexity. Current Phase
  4 dual-write rate (~few hundred messages/sec at peak) is far below
  the threshold.
