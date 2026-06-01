# ADR 0005 Phase 7-s3 — S3 Snapshot (cookbook side)

**Status**: DEFERRED — depends on Phase 3b (`cookbooks/lxc-elasticsearch/default.rb` creation) and Phase 7-s3-tf (S3 bucket + IAM user + SSM credentials in `home-monitor`).

This document specifies the **cookbook-side** changes required to register the
S3 snapshot repository and SLM (Snapshot Lifecycle Management) policy on the
Elasticsearch cluster. The companion **terraform-side** changes (S3 bucket, IAM
user, SSM `/monitoring/elastic/s3-snapshot/*` parameters, `pve-bootstrap-ssm`
policy extension) are tracked on branch `feat/adr0005-phase7-s3-snapshot` and
documented in the home-monitor side of `phase-7-s3-snapshot.md` (will be
unified at apply time).

## Why deferred

`cookbooks/lxc-elasticsearch/default.rb` does NOT exist on `origin/main` at the
time this branch is cut — Phase 3b (`feat/adr0005-phase3b-cookbooks`) creates
it. We therefore record the diff as a `git apply`-able patch
(`phase-7-s3-cookbook.patch`) and a markdown spec, ready to be re-applied after
Phase 3b lands and this branch rebases onto an updated `main`.

Apply path:

1. Phase 3b merges → `cookbooks/lxc-elasticsearch/default.rb` exists on `main`
2. Phase 7-s3-tf merges → `/monitoring/elastic/s3-snapshot/*` SSM parameters
   exist + `pve-bootstrap-ssm` IAM has read permission on them
3. Rebase this branch onto updated `main`
4. `git apply docs/adr/0005-impl/phase-7-s3-cookbook.patch`
5. `mitamae --dry-run` on the worktree, then `mitamae apply` on `es-0` only
   (the cookbook gates everything except the keystore-add via
   `node[:elasticsearch][:node_name] == "es-0"` — repo registration is
   cluster-wide, so only one node needs to perform the API calls)
6. `mitamae apply` on `es-1` and `es-2` to refresh the keystore (S3 access key
   needs to be present in every node's keystore for snapshot writes from any
   master). Then call `POST /_nodes/reload_secure_settings` cluster-wide.

## Scope (cookbook-side)

### Inputs

Three SSM SecureString parameters created by Phase 7-s3-tf:

| SSM path | Content |
|---|---|
| `/monitoring/elastic/s3-snapshot/access-key-id`     | IAM user `elasticsearch-snapshot` access key id |
| `/monitoring/elastic/s3-snapshot/secret-access-key` | IAM user `elasticsearch-snapshot` secret access key |
| `/monitoring/elastic/s3-snapshot/bucket-name`       | `home-monitor-elasticsearch-snapshots-<account>` |

### Steps performed by the cookbook

1. **SSM fetch (all nodes)** — pull the three values into a temp file with mode
   600. Use `require_external_auth` with the same `aws_profile` / `aws_region`
   convention as `cookbooks/lxc-monitoring`.

2. **Keystore add (all nodes)** — inside each ES container:

   ```bash
   docker exec -i elasticsearch \
     bin/elasticsearch-keystore add --stdin --force s3.client.default.access_key < <(cat /tmp/access-key-id)
   docker exec -i elasticsearch \
     bin/elasticsearch-keystore add --stdin --force s3.client.default.secret_key < <(cat /tmp/secret-access-key)
   ```

   The `--force` flag overwrites if the key already exists, so the resource is
   idempotent across re-runs. Idempotency at the script level: skip the add
   only if the in-keystore hash matches the SSM value (compute via `openssl
   dgst -sha256` of the fetched value and store the hash in
   `/var/lib/elasticsearch/.s3-keystore-hash`); otherwise re-add and bump the
   sentinel.

3. **Reload secure settings (run from es-0 only)** — the keystore add does not
   take effect until reload:

   ```bash
   curl -k -u elastic:${ELASTIC_PASSWORD} \
     -X POST https://localhost:9200/_nodes/reload_secure_settings \
     -H 'Content-Type: application/json' \
     -d "{\"secure_settings_password\":\"\"}"
   ```

   Run on `es-0` only; the request fans out across the cluster automatically.

4. **Register snapshot repository (es-0 only)** — idempotent via
   `_snapshot/s3-home-monitor/_status` returning 200:

   ```bash
   curl -k -u elastic:${ELASTIC_PASSWORD} \
     -X PUT https://localhost:9200/_snapshot/s3-home-monitor \
     -H 'Content-Type: application/json' \
     -d '{
       "type":"s3",
       "settings":{
         "bucket":"<bucket-name>",
         "base_path":"snapshots/home-monitor-rtx",
         "client":"default",
         "compress":true
       }
     }'
   ```

   Idempotency guard:

   ```bash
   status=$(curl -k -s -o /dev/null -w '%{http_code}' \
     -u elastic:${ELASTIC_PASSWORD} \
     https://localhost:9200/_snapshot/s3-home-monitor/_status)
   [[ "$status" == "200" ]] || PUT_REPO
   ```

5. **SLM policy `daily-snapshot` (es-0 only)** — idempotent via `GET
   /_slm/policy/daily-snapshot`:

   ```bash
   curl -k -u elastic:${ELASTIC_PASSWORD} \
     -X PUT https://localhost:9200/_slm/policy/daily-snapshot \
     -H 'Content-Type: application/json' \
     -d '{
       "schedule":"0 30 1 * * ?",
       "name":"<daily-snap-{now/d}>",
       "repository":"s3-home-monitor",
       "config":{
         "indices":["logs-rtx-*"],
         "include_global_state":false,
         "ignore_unavailable":true
       },
       "retention":{
         "expire_after":"30d",
         "min_count":7,
         "max_count":30
       }
     }'
   ```

   Schedule `0 30 1 * * ?` = daily 01:30 UTC (= 10:30 JST). Indices restricted
   to `logs-rtx-*` (no global state — security index, kibana saved-objects
   covered separately if required). 30-day retention with min 7 / max 30
   guards against both runaway storage and over-eager pruning.

### Files added / changed

| File | Action |
|---|---|
| `cookbooks/lxc-elasticsearch/default.rb` | Extend with SSM fetch, keystore add, snapshot bootstrap script invocation. New section under "Phase 7-s3 — S3 snapshot bootstrap" comment. |
| `cookbooks/lxc-elasticsearch/files/snapshot-bootstrap.sh` | New script — orchestrates all the above with idempotency guards. Mode 700, owner root. |

The script is structured similar to a `bootstrap-init.sh` that Phase 3b will
ship (`/usr/local/bin/elasticsearch-bootstrap` or equivalent). Pattern: each
step prefixed with a `should_run_X` function that returns 0 when the step
needs to run.

## Cookbook DSL ambiguities (for the future apply agent)

These are recorded so the apply agent (post-rebase) does not re-discover them:

1. **Keystore add idempotency** — `bin/elasticsearch-keystore add --force`
   always succeeds, but always rewrites the keystore file's mtime, which in
   turn could trigger restart notifies on every mitamae apply. Solution
   adopted in the patch: gate the docker exec inside an `only_if` shell guard
   that compares a sha256 sentinel file against the SSM value's hash. The
   sentinel lives at `/var/lib/elasticsearch/.s3-keystore-hash` (root-owned,
   mode 600). On first apply: sentinel absent → run + write hash. On
   subsequent apply with unchanged SSM: sentinel matches → skip.

2. **`reload_secure_settings` only after keystore changes** — must NOT be
   notify-driven from the docker `execute`, because the docker exec runs even
   when the keystore was already in sync. Use a separate `execute` resource
   with `only_if` checking sentinel-vs-SSM divergence (same shell guard used
   for the keystore add itself), and `notifies :run, "execute[reload secure
   settings]"` from there.

3. **Repo + SLM creation must run AFTER keystore reload** — order in the
   recipe matters. mitamae executes top-to-bottom; place the resources in
   order: SSM fetch → keystore add → reload → repo PUT → SLM PUT. No
   `notifies` between repo PUT and SLM PUT (both are independently idempotent
   via their own GET-200 guard).

4. **`--force` on `elasticsearch-keystore add`** — required because the
   keystore may already contain a previous value (e.g., a prior IAM key was
   rotated). Without `--force`, the command prompts interactively for
   overwrite confirmation, which fails in the docker exec stdin.

5. **es-0 gating** — `node[:elasticsearch][:node_name] == "es-0"` is the
   convention assumed here. Phase 3b cookbook should expose this attribute;
   if not, fall back to gating on `hostname -s == 'es-0'`. The patch uses the
   former; adapt at apply time if the actual attribute name differs.

6. **`localhost:9200`-vs-`<node-fqdn>:9200`** — once Phase 7-tls lands, ES
   listens on TLS only. The curl calls inside the cookbook hit `https://
   localhost:9200` from inside the LXC; the `-k` flag accepts the self-signed
   node cert. This avoids any cluster-DNS dependency. Patch matches this
   pattern.

7. **Empty `secure_settings_password` body** — the `_nodes/reload_secure_settings`
   endpoint requires the keystore password if one was set at keystore creation.
   The Phase 3b cookbook does NOT set a keystore password (the keystore is
   protected by filesystem permissions on the LXC; adding a keystore password
   would require another SSM round-trip on every reload). Patch hardcodes
   empty string; revisit if Phase 3b changes that decision.

## Verification (post-apply)

1. `curl -k -u elastic:<pw> https://es-0:9200/_snapshot/s3-home-monitor/_status` returns 200
2. `curl -k -u elastic:<pw> https://es-0:9200/_slm/policy/daily-snapshot` returns the policy JSON
3. Manual snapshot test: `curl -k -X PUT -u elastic:<pw> https://es-0:9200/_snapshot/s3-home-monitor/test-bootstrap-1`
   returns `{"accepted":true}`. After ~30s, `aws s3 ls s3://<bucket>/snapshots/home-monitor-rtx/`
   shows the new snapshot directory.
4. After the next 01:30 UTC tick: `GET /_slm/policy/daily-snapshot` shows
   `last_success.snapshot_name` populated with `daily-snap-YYYY.MM.dd`.
5. Cleanup test snapshot: `curl -k -X DELETE -u elastic:<pw>
   https://es-0:9200/_snapshot/s3-home-monitor/test-bootstrap-1`.

## Why Phase 5 observation period parallel apply

Per ADR §否定面 #4 (disk SPOF) and round-table #4 (blocker severity), the X8 USB
SSD physical fragility means the 3 ES nodes share a single failure mode:
cable-out → all 3 disks lost simultaneously, bypassing the replica1 HA. Phase
5 introduces a 2-week observation period before Phase 6 cutover; the
plan-revision proposal is to apply Phase 7-s3 (terraform + cookbook) IN
PARALLEL with Phase 5 observation, so that by the time Phase 6 retires the
Loki sink, the ES cluster has at least one valid snapshot in S3.

This document covers the cookbook side; once Phase 7-s3-tf merges, this branch
can rebase + git apply the patch + apply the cookbook on es-0 first, then
es-1/es-2, then run the manual snapshot test.
