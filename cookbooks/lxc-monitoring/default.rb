# frozen_string_literal: true
#
# lxc-monitoring (CT 111): Prometheus + Grafana stack for fleet observability.
#
# Stack:
#   - prom/prometheus:v2.55.1     :9090 (loopback-only inside the LXC)
#   - grafana/grafana:11.6.14     :3000 (LAN, LAN-only via firewall)
#
# State volumes (host paths bind-mounted into the containers):
#   /data/monitoring/prometheus/   TSDB
#   /data/monitoring/grafana/      grafana state (sqlite db, plugins)
#
# Provisioning:
#   - Prometheus datasource auto-loaded from /etc/grafana/provisioning/datasources
#   - Dashboards auto-loaded from /etc/grafana/dashboards
#       (a) Node Exporter Full (community ID 1860) — vendored
#       (b) Auto-mitamae Fleet — Phase 2a minimal, extended in Phase 2b
#
# Phase 2c (out of scope): Tailscale public access via mcp.ohno.be/grafana/
# through mcp-proxy. Phase 2 binds Grafana to the LAN only.
#
# CT 111 also runs node_exporter (cookbooks/node-exporter) as a sibling
# cookbook and self-applies via auto-mitamae-target — both included from
# pve/lxc-monitoring.rb.

return if node[:platform] == "darwin"

include_cookbook "docker-engine"
include_cookbook "awscli"

# Reuse the AWS profile / region convention from cookbooks/ssh-keys so the
# require_external_auth check_command and the .env generator both target the
# same IAM principal. Per CLAUDE.md "Auth-check gate must match the cookbook's
# actual invocation profile" — a bare check (no --profile) passes against
# whatever the host's `default` profile happens to be and is therefore a
# false gate when the cookbook actually invokes a named profile.
ssh_keys_config = JSON.parse(File.read(File.join(File.dirname(__FILE__), "..", "ssh-keys", "files", "aws-config.json")))
aws_profile = ssh_keys_config["aws_profile"]
aws_region  = ssh_keys_config["aws_region"]

user = node[:setup][:user]
group = node[:setup][:group]
deploy_dir = "#{node[:setup][:home]}/deploy/monitoring"
state_dir  = "/data/monitoring"

# Defensive: ensure setup_root + per-cookbook subdir exist before any
# remote_file write. Per CLAUDE.md "Defensive directory resource" rule.
directory node[:setup][:root] do
  mode "755"
end

directory "#{node[:setup][:root]}/lxc-monitoring" do
  owner user
  group group
  mode "755"
end

# Deploy directory + Grafana provisioning subdirs.
directory deploy_dir do
  owner user
  group group
  mode "755"
end

%w[grafana grafana/provisioning grafana/provisioning/datasources grafana/provisioning/dashboards grafana/dashboards].each do |sub|
  directory "#{deploy_dir}/#{sub}" do
    owner user
    group group
    mode "755"
  end
end

# State volumes — root-owned (containers mount these). Mode 755 so the
# Prometheus / Grafana containers (uid 65534 / 472 respectively) can write
# to them. The container images create the inner per-service subdirs at
# startup with the right uid.
directory "/data" do
  owner "root"
  group "root"
  mode "755"
end

directory state_dir do
  owner "root"
  group "root"
  mode "755"
end

# Vector state directory (ADR 0005 Phase 4). Holds disk-buffer storage
# for the loki + elasticsearch sinks (vector.toml `data_dir =
# "/var/lib/vector"`) and the SSM-distributed Elasticsearch CA cert
# (bind-mounted into /etc/vector/elastic-ca.crt).
#
# Vector container runs as root (network_mode: host, no user: directive).
# In the unprivileged LXC, container UID 0 maps to host UID 100000.
# The cookbook runs INSIDE the container, so address the in-container view:
# `owner "0"` chowns to container root, which surfaces on the host as
# UID 100000 via the namespace mapping. Writing `owner "100000"` would try
# to set UID 100000 inside the container — outside the 0-65535 mapping
# range — and fails with `chown: Invalid argument`. Mode 755 is sufficient
# because no other container reads this directory.
directory "#{state_dir}/vector" do
  owner "0"
  group "0"
  mode "755"
end

directory "#{state_dir}/vector/buffer" do
  owner "0"
  group "0"
  mode "755"
end

# Per-service state subdirs. Each container runs as its own non-root UID
# and writes sqlite WAL / lock / journal files INTO the parent dir (not
# just inside subdirs the container creates) — so the dir itself must be
# writable by the container's UID.
#
# Grafana 11.x → uid=472(grafana). Without uid 472 ownership, grafana.db
# opens read-only, sqlite raises "attempt to write a readonly database",
# and login fails with "Internal Server Error". Per CLAUDE.md
# `infrastructure.md` "Container state path audit when `user:` is non-root".
#
# Prometheus 2.x → uid=65534(nobody). TSDB writes (chunks_head/, wal/,
# lock, queries.active) all happen inside /prometheus.
#
# Set per-service explicitly with String UIDs (Integer raises
# InvalidTypeError per `ruby.md` "owner/group must be String").
state_dir_owners = {
  "prometheus" => "65534", # nobody (prom/prometheus standard)
  "grafana"    => "472",   # grafana (grafana/grafana standard)
}
state_dir_owners.each do |sub, uid|
  directory "#{state_dir}/#{sub}" do
    owner uid
    group uid
    mode "755"
  end
end

# Phase 6 (ADR 0005): Loki cutover — remove the on-disk state directory
# from previously-deployed hosts. Mitamae's `directory ... action :delete`
# only deletes empty dirs and doesn't accept `recursive`, so use a guarded
# `execute rm -rf`. The `only_if` keeps it idempotent: skipped when the
# directory is already gone.
execute "remove obsolete loki state dir" do
  command "sudo rm -rf #{state_dir}/loki"
  only_if "test -d #{state_dir}/loki"
end

# Allow the Vector container (network_mode: host, non-root user inside
# the container) to bind UDP 514 — RTX firmware emits syslog only to the
# fixed default destination port and does not honour `syslog host <ip>
# <port>` as a port specifier. Lowering ip_unprivileged_port_start is
# per-LXC kernel namespace and avoids granting CAP_NET_BIND_SERVICE.
sysctl_src  = File.expand_path("../files/99-syslog-unprivileged-port.conf", __FILE__)
sysctl_path = "/etc/sysctl.d/99-syslog-unprivileged-port.conf"

execute "install syslog unprivileged port sysctl" do
  command "sudo install -m 644 -o root -g root #{sysctl_src} #{sysctl_path}"
  not_if "test -f #{sysctl_path} && diff -q #{sysctl_src} #{sysctl_path}"
end

execute "apply syslog unprivileged port sysctl" do
  command "sudo sysctl -p #{sysctl_path}"
  not_if "sysctl -n net.ipv4.ip_unprivileged_port_start | grep -qx '514'"
  notifies :run, "execute[restart monitoring]"
end

# Compose + scrape config + provisioning files.
remote_file "#{deploy_dir}/docker-compose.yml" do
  source "files/docker-compose.yml"
  owner user
  group group
  mode "0644"
  notifies :run, "execute[restart monitoring]"
end

remote_file "#{deploy_dir}/prometheus.yml" do
  source "files/prometheus.yml"
  owner user
  group group
  mode "0644"
  notifies :run, "execute[restart monitoring]"
end

remote_file "#{deploy_dir}/grafana/provisioning/datasources/prometheus.yml" do
  source "files/grafana/provisioning/datasources/prometheus.yml"
  owner user
  group group
  mode "0644"
  notifies :run, "execute[restart monitoring]"
end

remote_file "#{deploy_dir}/grafana/provisioning/dashboards/dashboards.yml" do
  source "files/grafana/provisioning/dashboards/dashboards.yml"
  owner user
  group group
  mode "0644"
  notifies :run, "execute[restart monitoring]"
end

%w[node-exporter-full.json auto-mitamae-fleet.json proxmox-via-prometheus.json mcp-fleet-health.json rtx-routers.json].each do |dash|
  remote_file "#{deploy_dir}/grafana/dashboards/#{dash}" do
    source "files/grafana/dashboards/#{dash}"
    owner user
    group group
    mode "0644"
    notifies :run, "execute[restart monitoring]"
  end
end

# Phase 6 (ADR 0005): rtx-logs.json was the Grafana/Loki RTX log dashboard;
# replaced by Kibana saved objects (Phase 5). Remove the deployed copy on
# previously-converged hosts so Grafana doesn't show a stale dashboard
# pointing at a deleted Loki datasource.
file "#{deploy_dir}/grafana/dashboards/rtx-logs.json" do
  action :delete
end

# Phase 6 (ADR 0005): same cleanup for the Loki datasource provisioning
# yaml that Grafana would otherwise reload on container start.
file "#{deploy_dir}/grafana/provisioning/datasources/loki.yml" do
  action :delete
end

# Phase 6 (ADR 0005): the loki-config.yaml previously bind-mounted into
# the Loki container.
file "#{deploy_dir}/loki-config.yaml" do
  action :delete
end

# snmp-exporter config template — committed with @@RTX_SNMP_COMMUNITY@@
# placeholder; substituted at converge time after the .env is generated.
# See cookbooks/lxc-monitoring/files/snmp-generator/ for the regeneration
# workflow (Makefile + YAMAHA MIBs + prom/snmp-generator:v0.26.0).
snmp_tmpl_path = "#{deploy_dir}/snmp.yml.tmpl"
snmp_yml_path  = "#{deploy_dir}/snmp.yml"

remote_file snmp_tmpl_path do
  source "files/snmp.yml.tmpl"
  owner user
  group group
  mode "0644"
  notifies :run, "execute[generate snmp.yml]"
end

# blackbox_exporter config + Prometheus alerts dir. Placed BEFORE the
# `ensure monitoring running` execute (declared further below) because
# the docker-compose.yml staged above references both as bind mounts —
# `up -d` aborts with a missing-source error if blackbox.yml or the
# alerts/ dir don't exist when compose first parses the spec. Ordering
# is converge-time meaningful here even though resources individually
# converge top-to-bottom.
remote_file "#{deploy_dir}/blackbox.yml" do
  source "files/blackbox.yml"
  owner user
  group group
  mode "0644"
  notifies :run, "execute[restart monitoring]"
end

directory "#{deploy_dir}/alerts" do
  owner user
  group group
  mode "755"
end

remote_file "#{deploy_dir}/alerts/mcp.yml" do
  source "files/alerts/mcp.yml"
  owner user
  group group
  mode "0644"
  notifies :run, "execute[restart monitoring]"
end

remote_file "#{deploy_dir}/alerts/pve-host.yml" do
  source "files/alerts/pve-host.yml"
  owner user
  group group
  mode "0644"
  notifies :run, "execute[restart monitoring]"
end

remote_file "#{deploy_dir}/alerts/auto-mitamae.yml" do
  source "files/alerts/auto-mitamae.yml"
  owner user
  group group
  mode "0644"
  notifies :run, "execute[restart monitoring]"
end

# LAN DNS resolver (CT 118 / .61) health — fed by the PVE host's
# unbound-watchdog node_exporter textfile metrics (cookbooks/unbound-watchdog).
remote_file "#{deploy_dir}/alerts/unbound.yml" do
  source "files/alerts/unbound.yml"
  owner user
  group group
  mode "0644"
  notifies :run, "execute[restart monitoring]"
end

# Eternal Terminal listener health — fed by each et host's et-watchdog
# node_exporter textfile metrics (cookbooks/eternal-terminal). Reaches
# Prometheus only from scraped hosts (today pro-dev); mini/air/neo et health is
# covered centrally by the Kibana synthetics TCP probe. Origin: issue #567.
remote_file "#{deploy_dir}/alerts/et-watchdog.yml" do
  source "files/alerts/et-watchdog.yml"
  owner user
  group group
  mode "0644"
  notifies :run, "execute[restart monitoring]"
end

# RTX SNMP scrape health (hnd .253 / itm .254). `up{job="snmp-rtx"} == 0`
# means snmp_exporter cannot poll the router — most often the device lost its
# `snmp host any` / `snmpv2c host any` ACL on a reboot. The ACL is declared in
# home-monitor rtx_snmp_server.<router> (provider >= 0.15.0); recovery is a
# `terraform apply -target=rtx_snmp_server.<router>`. Added after the
# 2026-05-31 silent HND SNMP outage (no down alert existed).
remote_file "#{deploy_dir}/alerts/rtx-snmp.yml" do
  source "files/alerts/rtx-snmp.yml"
  owner user
  group group
  mode "0644"
  notifies :run, "execute[restart monitoring]"
end

# Elasticsearch cluster health (RED/YELLOW/unreachable/stale). Fed by
# elasticsearch_cluster_status{color=...} from each es node's node_exporter
# textfile (cookbooks/lxc-elasticsearch es-cluster-health.timer).
remote_file "#{deploy_dir}/alerts/elasticsearch.yml" do
  source "files/alerts/elasticsearch.yml"
  owner user
  group group
  mode "0644"
  notifies :run, "execute[restart monitoring]"
end

# self-heal-observer (CT 111) liveness + error alerts. Fed by the
# self_heal_observer_* textfile metrics that cookbooks/self-heal-observer
# emits into node_exporter's textfile dir on the same host.
# SelfHealObserverStale is the meta-alert: a dead observer silently
# reports all-clear, so its own liveness must be watched.
remote_file "#{deploy_dir}/alerts/self-heal.yml" do
  source "files/alerts/self-heal.yml"
  owner user
  group group
  mode "0644"
  notifies :run, "execute[restart monitoring]"
end

# Vector (RTX syslog → Elasticsearch). Replaces the prior Promtail syslog
# target: RTX1210/RTX830 firmware emits non-standard syslog (`<PRI>tag msg`
# with no TIMESTAMP/HOSTNAME) that neither RFC5424 nor RFC3164 strict
# parsers accept. Phase 6 (ADR 0005) removed the Loki sink + container;
# Elasticsearch is now the sole sink and Kibana provides the analyst UI.
remote_file "#{deploy_dir}/vector.toml" do
  source "files/vector.toml"
  owner user
  group group
  mode "0644"
  notifies :run, "execute[restart monitoring]"
end

# Clean up the old Promtail config — the deploy_dir copy is no longer
# referenced by docker-compose.yml. `not_if` makes this idempotent on
# already-cleaned hosts. Promtail's positions cache directory was at
# /tmp/promtail-positions and is intentionally NOT cleaned by the
# cookbook (tmpfs on reboot or admin can rm -rf manually).
execute "remove obsolete promtail-config.yaml from deploy_dir" do
  command "rm -f #{deploy_dir}/promtail-config.yaml"
  only_if "test -f #{deploy_dir}/promtail-config.yaml"
end

# GeoIP staging directory on the host (bind-mounted into vector at
# /etc/vector/geoip:ro). The .mmdb file lands here via the download
# execute below; the upstream files/geoip/ in the cookbook only carries
# a .gitkeep — the binary database is intentionally not committed.
directory "#{deploy_dir}/geoip" do
  owner user
  group group
  mode "755"
end

# Download dbip-city-lite (CC-BY 4.0, ~50 MB gz / ~125 MB unpacked) for
# GeoIP enrichment in the Vector pipeline. URL pattern is
# dbip-city-lite-YYYY-MM.mmdb.gz; verified 2026-05 active at the time of
# cookbook authoring (HTTP 200, 62 MB gzipped). The not_if guard
# re-downloads if the file is older than 25 days — db-ip publishes
# monthly so this naturally keeps the database fresh-ish without a
# separate cron.
geoip_db_path = "#{deploy_dir}/geoip/dbip-city-lite.mmdb"
geoip_url     = "https://download.db-ip.com/free/dbip-city-lite-2026-05.mmdb.gz"

execute "download dbip-city-lite GeoIP DB" do
  command <<~SH.strip
    set -euo pipefail
    curl -fsSL "#{geoip_url}" \\
      | gunzip > #{geoip_db_path}.new
    mv #{geoip_db_path}.new #{geoip_db_path}
    chmod 644 #{geoip_db_path}
  SH
  user user
  not_if "test -f #{geoip_db_path} && " \
         "find #{geoip_db_path} -mtime -25 | grep -q ."
  notifies :run, "execute[restart monitoring]"
end

# Generate .env from SSM (Grafana admin password). Mirror cognee pattern:
# stage in setup_root/generated, then move to deploy_dir/.env. require_external_auth
# pauses on a fresh host until AWS auth is configured (or skip in non-TTY).
generated_dir = "#{node[:setup][:root]}/generated"
directory generated_dir do
  owner user
  group group
  mode "755"
end

generate_env_script = File.join(File.dirname(__FILE__), "files", "generate_env.sh")
env_temp_path = "#{generated_dir}/monitoring.env"
env_output_path = "#{deploy_dir}/.env"

require_external_auth(
  tool_name: "AWS CLI (profile=#{aws_profile}, region=#{aws_region}) for monitoring SSM secrets",
  check_command: "aws ssm get-parameter --name /monitoring/grafana-admin-password " \
                 "--with-decryption --profile #{aws_profile} --region #{aws_region} " \
                 "> /dev/null 2>&1",
  instructions: "Configure '#{aws_profile}' with ssm:GetParameter on /monitoring/* in " \
                "#{aws_region}. generate_env.sh fetches: grafana-admin-password, " \
                "pve-exporter-token, rtx-snmp-community, elastic/vector-password " \
                "(ADR 0005 Phase 4 — write-only role for [sinks.elasticsearch]). " \
                "On a fresh machine: aws configure --profile #{aws_profile}. Then press Enter.",
  skip_if: -> { File.exist?(env_output_path) },
) do
  execute "generate monitoring .env" do
    command "AWS_PROFILE=#{aws_profile} AWS_REGION=#{aws_region} " \
            "bash #{generate_env_script} #{env_temp_path}"
    user user
  end
end

# Place .env at converge time (only_if test -f), then clean up the staged
# copy. Same compile-vs-converge guard pattern as cookbooks/cognee.
remote_file env_output_path do
  source env_temp_path
  owner user
  group group
  mode "0600"
  notifies :run, "execute[restart monitoring]"
  notifies :run, "execute[generate snmp.yml]"
  only_if "test -f #{env_temp_path}"
end

file env_temp_path do
  action :delete
  only_if "test -f #{env_temp_path}"
end

# Elasticsearch CA cert (ADR 0005 Phase 4). Stored as a plain PEM string
# in SSM /monitoring/elastic/ca/cert (Terraform-generated CA, validity
# 2 years per ADR 0005 §認証). Distributed to /data/monitoring/vector/
# elastic-ca.crt because docker-compose.yml bind-mounts that path
# read-only into vector at /etc/vector/elastic-ca.crt — the path Vector's
# [sinks.elasticsearch].tls.ca_file references.
#
# Mode 0644 root:root: the cert is public material (no key), readable by
# any process. Owner is host root (NOT 100000) because container Vector
# only needs RO access via the bind-mount; the file does not need to be
# owned by container-root.
#
# Fetched into a staging file then `install`-ed atomically so a partial
# fetch doesn't leave a half-written cert that breaks Vector startup.
elastic_ca_temp   = "#{generated_dir}/elastic-ca.crt"
elastic_ca_target = "#{state_dir}/vector/elastic-ca.crt"

require_external_auth(
  tool_name: "AWS CLI for /monitoring/elastic/ca/cert SSM param",
  check_command: "aws ssm get-parameter --name /monitoring/elastic/ca/cert " \
                 "--profile #{aws_profile} --region #{aws_region} > /dev/null 2>&1",
  instructions: "ES cluster (Phase 1b/3) must be provisioned first — Terraform " \
                "writes the CA cert to /monitoring/elastic/ca/cert. Then this " \
                "cookbook can fetch it.",
  skip_if: -> { File.exist?(elastic_ca_target) },
) do
  execute "fetch elastic CA cert from SSM" do
    command <<~SH.strip
      set -euo pipefail
      aws ssm get-parameter \\
        --name /monitoring/elastic/ca/cert \\
        --query "Parameter.Value" \\
        --output text \\
        --profile #{aws_profile} \\
        --region #{aws_region} > #{elastic_ca_temp}.new
      mv #{elastic_ca_temp}.new #{elastic_ca_temp}
      chmod 644 #{elastic_ca_temp}
    SH
    user user
  end
end

execute "install elastic CA cert" do
  command "sudo install -m 644 -o root -g root #{elastic_ca_temp} #{elastic_ca_target}"
  only_if "test -f #{elastic_ca_temp}"
  notifies :run, "execute[restart monitoring]"
end

execute "delete elastic CA cert staging file" do
  command "rm -f #{elastic_ca_temp}"
  only_if "test -f #{elastic_ca_temp}"
end

# Generate snmp.yml from snmp.yml.tmpl by substituting the community
# placeholder with the value from the deployed .env. snmp_exporter does
# NOT expand env vars in its YAML config, so the substitution happens
# at deploy time. Triggered (a) directly by remote_file above (notifies
# on tmpl change), and (b) on .env regeneration. Idempotent on stable
# input via the only_if guard — re-runs only when the rendered file is
# missing or stale relative to the template / .env.
execute "generate snmp.yml" do
  command <<~SH.strip
    set -euo pipefail
    . #{env_output_path}
    sed "s|@@RTX_SNMP_COMMUNITY@@|${RTX_SNMP_COMMUNITY}|g" \\
      #{snmp_tmpl_path} > #{snmp_yml_path}.new
    mv #{snmp_yml_path}.new #{snmp_yml_path}
    chmod 600 #{snmp_yml_path}
  SH
  user user
  action :nothing
  notifies :run, "execute[restart monitoring]"
  only_if "test -f #{env_output_path} && test -f #{snmp_tmpl_path}"
end

# Initial render at converge time when both inputs exist but the rendered
# file is absent (fresh host after first .env generation). Same idempotency
# pattern as cookbooks/cognee's docker-compose restart guard.
execute "ensure snmp.yml exists" do
  command <<~SH.strip
    set -euo pipefail
    . #{env_output_path}
    sed "s|@@RTX_SNMP_COMMUNITY@@|${RTX_SNMP_COMMUNITY}|g" \\
      #{snmp_tmpl_path} > #{snmp_yml_path}.new
    mv #{snmp_yml_path}.new #{snmp_yml_path}
    chmod 600 #{snmp_yml_path}
  SH
  user user
  only_if "test -f #{env_output_path} && test -f #{snmp_tmpl_path} && ! test -f #{snmp_yml_path}"
end

compose_path = "#{deploy_dir}/docker-compose.yml"
project_name = File.basename(deploy_dir)

# Bring containers up. DOCKER_BUILDKIT=0 because the unprivileged LXC's
# nesting=true setting + classic builder is the proven combination per
# CLAUDE.md "Docker Build in Unprivileged PVE LXC" rule. No subdir-context
# Dockerfiles here (only image pulls), so classic builder is sufficient.
execute "ensure monitoring running" do
  command "DOCKER_BUILDKIT=0 docker compose -f #{compose_path} up -d"
  user user
  # Gate on .env (grafana/pve-exporter/elastic env vars), snmp.yml
  # (bind-mounted into snmp-exporter — Docker creates a directory if the
  # source path is missing, leaving the container in a crash-loop with
  # `open /etc/snmp_exporter/snmp.yml: is a directory`), AND elastic-ca.crt
  # (bind-mounted into vector — same Docker auto-mkdir trap; absence
  # would crash Vector at startup because [sinks.elasticsearch].tls.ca_file
  # would point at a directory). All three come from SSM-gated bootstrap
  # paths so all must exist before compose is allowed to start the stack.
  only_if <<~SH.tr("\n", " ").strip
    test -f #{env_output_path} || exit 1;
    test -f #{snmp_yml_path} || exit 1;
    test -f #{elastic_ca_target} || exit 1;
    expected=$(docker compose -f #{compose_path} config --services 2>/dev/null | sort | tr '\\n' ' ');
    [ -n "$expected" ] || exit 1;
    running=$(docker ps --filter "label=com.docker.compose.project=#{project_name}"
                        --filter status=running --format '{{.Label "com.docker.compose.service"}}'
              | sort | tr '\\n' ' ');
    test "$running" = "$expected" && exit 1 || exit 0
  SH
end

execute "restart monitoring" do
  # --force-recreate forces re-creation even when image + compose spec are
  # unchanged, picking up bind-mounted config edits (prometheus.yml,
  # grafana provisioning yaml, dashboards/*.json) that bare `up -d`
  # silently skips on already-running containers. Discovered when adding
  # honor_labels to prometheus.yml in PR #154 — the notify fired but the
  # bare `up -d` was a no-op, so the new label semantics never reached
  # the running prometheus container until manual SIGHUP. Same fix shape
  # as PR #158 for the other 6 cookbooks; lxc-monitoring was excluded
  # there to avoid an apparent (but ultimately illusory) merge conflict.
  #
  # --remove-orphans drops containers that are no longer declared in
  # docker-compose.yml. Required when retiring services (e.g. promtail
  # was removed from the compose in the Vector migration; without
  # --remove-orphans, the old promtail container kept running and
  # holding UDP 514 so the new vector container couldn't bind).
  command "DOCKER_BUILDKIT=0 docker compose -f #{compose_path} up -d --force-recreate --remove-orphans"
  user user
  action :nothing
  # Skip when .env was not generated, snmp.yml hasn't been rendered, or
  # elastic-ca.crt hasn't been fetched (SSM auth absent / non-interactive
  # bootstrap, OR ES cluster not yet provisioned in Phase 1b/3). Restart
  # with empty admin password would leave Grafana unmanageable; missing
  # snmp.yml would leave snmp-exporter crash-looping; missing
  # elastic-ca.crt would leave Vector crash-looping with tls.ca_file
  # pointing at a directory. Same guard pattern as cookbooks/cognee.
  only_if "test -f #{env_output_path} && test -f #{snmp_yml_path} && test -f #{elastic_ca_target}"
end

# MCP fleet health monitoring — extracted to its own cookbook in Phase 7
# (mcp-probe systemd timer + python prober is logically distinct from the
# docker observability stack above). The cookbook handles its own SSM
# auth, env generation, and systemd unit lifecycle.
include_cookbook "mcp-probe"
