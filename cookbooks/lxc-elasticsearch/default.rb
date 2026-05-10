# frozen_string_literal: true
#
# lxc-elasticsearch (CT 112 / 113 / 114): Elasticsearch 8.x master+data+ingest
# node, one of a 3-node cluster. Native apt + systemd install (Phase 3b
# retro: docker-compose deployment was replaced because 4 of 8 cookbook
# bugs were structural docker-isms — see ~/.claude/rules/pve-lxc.md
# "Docker-in-LXC vs apt+systemd"). The same cookbook ships to all three
# CTs; per-LXC divergence is parameterised through node attributes set
# in the pve/lxc-es-{0,1,2}.rb entry recipes:
#
#   node[:elasticsearch][:node_name]      "es-0" | "es-1" | "es-2"
#   node[:elasticsearch][:transport_host] "192.168.1.77" | ".78" | ".79"
#
# Stack:
#   - Elasticsearch 8.16.0 DEB (apt-mark hold)  :9200 (HTTP, LAN)
#                                                :9300 (transport TLS)
#   - systemd unit elasticsearch.service (DEB-shipped)
#   - /etc/systemd/system/elasticsearch.service.d/override.conf (cookbook-managed)
#
# State volume (host bind-mount): /data/elasticsearch/{data,logs,certs}
#   — on PVE host /mnt/data/elasticsearch/<node>/ (USB X8 SSD, 200 GB).
#   — Phase 3a manual op chowns the parent dir 100000:100000 so it
#     surfaces as root:root inside the container; the cookbook chowns
#     the data/ logs/ certs/ subdirs to the elasticsearch system user
#     (UID assigned by the DEB package, typically 113-115 on Debian
#     trixie templates).
#
# Phase 3b ships transport-TLS only. HTTP TLS comes in Phase 7-tls.
#
# Adversarial findings folded in:
#   #2  bind-mount UID — parent root, subdirs owned by elasticsearch user
#   #6  /etc/elasticsearch/elasticsearch-secrets.env mode 0640 root:elasticsearch
#   #8  ILM bootstrap order: ILM → component → index template → data stream → roles → users
#   #11 Rolling restart serialization — see notes in §restart section
#   #12 Atomic kibana_system reset before Kibana cookbook reads SSM password
#   #14 Drift detection — SSM password vs ES auth probe → reset on mismatch
#
# Migration from docker (UC2): operator must `docker compose down` BEFORE
# the first native apply on each LXC. Data dir survives unchanged; ES
# on-disk format is identical between container and native install. After
# native apply succeeds, the operator may remove ~/deploy/elasticsearch/
# from the LXC.

return if node[:platform] == "darwin"

include_cookbook "awscli"

# Reuse the AWS profile / region convention from cookbooks/ssh-keys so the
# require_external_auth check_command and the secrets / cert generators
# all target the same IAM principal (per CLAUDE.md "Auth-check gate must
# match the cookbook's actual invocation profile").
ssh_keys_config = JSON.parse(File.read(File.join(File.dirname(__FILE__), "..", "ssh-keys", "files", "aws-config.json")))
aws_profile = ssh_keys_config["aws_profile"]
aws_region  = ssh_keys_config["aws_region"]

node_name      = node[:elasticsearch] && node[:elasticsearch][:node_name]
transport_host = node[:elasticsearch] && node[:elasticsearch][:transport_host]

if node_name.nil? || transport_host.nil?
  raise "lxc-elasticsearch: node[:elasticsearch][:node_name] and " \
        "[:transport_host] must be set in the pve/lxc-es-*.rb entry recipe"
end

user      = node[:setup][:user]
group     = node[:setup][:group]
state_dir = "/data/elasticsearch"

# Defensive: ensure setup_root + per-cookbook subdir exist before any
# remote_file write. Per CLAUDE.md "Defensive directory resource".
directory node[:setup][:root] do
  mode "755"
end

directory "#{node[:setup][:root]}/lxc-elasticsearch" do
  owner user
  group group
  mode "755"
end

# Cookbook-files staging dir — bootstrap-init.sh, ILM/template/role JSON
# all live here at converge time so the bootstrap script can read them.
files_dir = "#{node[:setup][:root]}/lxc-elasticsearch/files"
directory files_dir do
  owner user
  group group
  mode "755"
end

directory "#{files_dir}/component-templates" do
  owner user
  group group
  mode "755"
end

# === Elastic apt repo registration ===

execute "install elastic apt prerequisites" do
  command "apt-get install -y ca-certificates curl gnupg apt-transport-https"
  not_if {
    %w(ca-certificates curl gnupg apt-transport-https).all? { |pkg|
      run_command("dpkg-query -W -f='${Status}' #{pkg} 2>/dev/null | grep -q 'install ok installed'", error: false).exit_status == 0
    }
  }
end

execute "add elastic apt key" do
  command <<~SH.strip
    install -d -m 0755 /etc/apt/keyrings && \
      curl -fsSL https://artifacts.elastic.co/GPG-KEY-elasticsearch | \
      gpg --batch --yes --dearmor -o /etc/apt/keyrings/elastic.gpg && \
      chmod a+r /etc/apt/keyrings/elastic.gpg
  SH
  not_if { File.exist?("/etc/apt/keyrings/elastic.gpg") }
end

execute "add elastic apt repo" do
  command "echo 'deb [signed-by=/etc/apt/keyrings/elastic.gpg] " \
          "https://artifacts.elastic.co/packages/8.x/apt stable main' " \
          "> /etc/apt/sources.list.d/elastic-8.x.list"
  not_if "test -f /etc/apt/sources.list.d/elastic-8.x.list && " \
         "grep -q 'artifacts.elastic.co' /etc/apt/sources.list.d/elastic-8.x.list"
  notifies :run, "execute[apt-get update for elastic]", :immediately
end

execute "apt-get update for elastic" do
  command "apt-get update -qq"
  action :nothing
end

# === Bind-mount state volume + per-subdir ownership ===
#
# The /data/elasticsearch parent is created by Phase 3a manual op
# (chown 100000:100000 on the host) so it surfaces as root:root inside
# the container. We chown the data/ logs/ certs/ subdirs to the
# elasticsearch user AFTER the DEB install creates that user.
#
# Migration note: pre-Phase-3b the subdirs were owned by UID 1000 (the
# docker.elastic.co/elasticsearch image's user). After native install
# the subdirs need to be re-owned to the elasticsearch system user.
# The DEB postinstall script does NOT chown bind-mount paths — only
# the default /var/lib/elasticsearch — so we do it here.
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

# Subdirs: created with mitamae's directory resource (no owner attempt
# yet — the elasticsearch user doesn't exist before apt install). The
# chown happens in the post-install execute resource below.
#
# Note: certs/ is intentionally NOT created under /data/elasticsearch
# because native ES enforces a Java SecurityManager constraint that
# blocks reading SSL files outside /etc/elasticsearch (error:
# "SSL resources should be placed in the [/etc/elasticsearch] directory").
# Certs are installed at /etc/elasticsearch/certs/ instead — see cert
# install resources below.
%w[data logs].each do |sub|
  directory "#{state_dir}/#{sub}" do
    mode "755"
  end
end

# === Install Elasticsearch DEB ===

execute "install elasticsearch 8.16.0" do
  command "apt-get install -y elasticsearch=8.16.0"
  not_if "dpkg-query -W -f='${Version}' elasticsearch 2>/dev/null | grep -q '^8.16.0$'"
end

execute "apt-mark hold elasticsearch" do
  command "apt-mark hold elasticsearch"
  not_if "apt-mark showhold | grep -q '^elasticsearch$'"
end

# Re-chown bind-mount subdirs to the elasticsearch user (created by the
# DEB postinst). Idempotent: skipped when the chown already matches.
%w[data logs].each do |sub|
  execute "chown #{state_dir}/#{sub} to elasticsearch" do
    command "chown -R elasticsearch:elasticsearch #{state_dir}/#{sub}"
    only_if "id elasticsearch >/dev/null 2>&1"
    not_if "test \"$(stat -c '%U:%G' #{state_dir}/#{sub})\" = 'elasticsearch:elasticsearch'"
  end
end

# Cert directory under /etc/elasticsearch (Java SecurityManager constraint
# — SSL resources must live under ES_PATH_CONF=/etc/elasticsearch).
execute "create /etc/elasticsearch/certs directory" do
  command "install -d -m 0750 -o root -g elasticsearch /etc/elasticsearch/certs"
  only_if "id elasticsearch >/dev/null 2>&1"
  not_if "test -d /etc/elasticsearch/certs && " \
         "test \"$(stat -c '%U:%G:%a' /etc/elasticsearch/certs)\" = 'root:elasticsearch:750'"
end

# === elasticsearch.yml render ===
#
# elasticsearch.yml is rendered from a template by substituting NODE_NAME
# and TRANSPORT_HOST. Same snmp_yml-pattern as before, but the destination
# is /etc/elasticsearch/ (DEB default) instead of the deploy_dir.
es_yml_tmpl = "#{files_dir}/elasticsearch.yml.tmpl"
es_yml_path = "/etc/elasticsearch/elasticsearch.yml"

remote_file es_yml_tmpl do
  source "files/elasticsearch.yml.tmpl"
  owner user
  group group
  mode "0644"
  notifies :run, "execute[render elasticsearch.yml]"
end

execute "render elasticsearch.yml" do
  command <<~SH.strip
    set -euo pipefail
    sed -e "s|@@NODE_NAME@@|#{node_name}|g" \\
        -e "s|@@TRANSPORT_HOST@@|#{transport_host}|g" \\
      #{es_yml_tmpl} > #{es_yml_path}.new
    install -m 0660 -o root -g elasticsearch #{es_yml_path}.new #{es_yml_path}
    rm -f #{es_yml_path}.new
  SH
  not_if "test -f #{es_yml_path} && " \
         "diff -q <(sed -e 's|@@NODE_NAME@@|#{node_name}|g' " \
         "-e 's|@@TRANSPORT_HOST@@|#{transport_host}|g' #{es_yml_tmpl}) " \
         "#{es_yml_path}"
  notifies :run, "execute[restart elasticsearch]"
end

# Also render once if both inputs exist but rendered file is absent
# (fresh host first apply, before any tmpl change has fired the notify).
execute "ensure elasticsearch.yml exists" do
  command <<~SH.strip
    set -euo pipefail
    sed -e "s|@@NODE_NAME@@|#{node_name}|g" \\
        -e "s|@@TRANSPORT_HOST@@|#{transport_host}|g" \\
      #{es_yml_tmpl} > #{es_yml_path}.new
    install -m 0660 -o root -g elasticsearch #{es_yml_path}.new #{es_yml_path}
    rm -f #{es_yml_path}.new
  SH
  only_if "test -f #{es_yml_tmpl} && id elasticsearch >/dev/null 2>&1 && ! test -f #{es_yml_path}"
end

# === JVM heap options ===
#
# /etc/elasticsearch/jvm.options.d/heap.options — ES merges every
# *.options file under jvm.options.d/ on top of the default jvm.options.
heap_options_staging = "#{files_dir}/elasticsearch-heap.options"
heap_options_path    = "/etc/elasticsearch/jvm.options.d/heap.options"

remote_file heap_options_staging do
  source "files/elasticsearch-heap.options"
  owner user
  group group
  mode "0644"
end

execute "install jvm.options.d/heap.options" do
  command "install -m 0660 -o root -g elasticsearch #{heap_options_staging} #{heap_options_path}"
  only_if "id elasticsearch >/dev/null 2>&1"
  not_if "test -f #{heap_options_path} && diff -q #{heap_options_staging} #{heap_options_path} 2>/dev/null"
  notifies :run, "execute[restart elasticsearch]"
end

# === systemd override ===
#
# wait-cluster-ready.sh is shipped to #{files_dir} and referenced
# directly from override.conf as ExecStartPost=. Path is hard-coded in
# override.conf (#{files_dir} expands to /root/.setup_shin1ohno/lxc-elasticsearch/files/);
# if node[:setup][:root] ever diverges from /root/.setup_shin1ohno on
# LXC entry recipes, update both files in lockstep.
unit_override_staging = "#{files_dir}/elasticsearch.service.override.conf"
unit_override_dir     = "/etc/systemd/system/elasticsearch.service.d"
unit_override_path    = "#{unit_override_dir}/override.conf"
wait_script_staging   = "#{files_dir}/wait-cluster-ready.sh"
wait_script_path      = "/usr/local/bin/es-wait-cluster-ready.sh"

# Stage in user space (mode 0755) then install to /usr/local/bin so the
# elasticsearch systemd unit's ExecStartPost (running as the
# `elasticsearch` system user) can exec it. /root is mode 700 — non-root
# users can't traverse it, so the staged path under node[:setup][:root]
# is unreachable for ExecStartPost. /usr/local/bin is world-readable.
remote_file wait_script_staging do
  source "files/wait-cluster-ready.sh"
  owner user
  group group
  mode "0755"
end

execute "install es-wait-cluster-ready.sh to /usr/local/bin" do
  command "install -m 0755 -o root -g root #{wait_script_staging} #{wait_script_path}"
  not_if "test -f #{wait_script_path} && diff -q #{wait_script_staging} #{wait_script_path} 2>/dev/null"
  notifies :run, "execute[restart elasticsearch]"
end

remote_file unit_override_staging do
  source "files/elasticsearch.service.override.conf"
  owner user
  group group
  mode "0644"
end

execute "create elasticsearch.service.d directory" do
  command "install -d -m 0755 -o root -g root #{unit_override_dir}"
  not_if "test -d #{unit_override_dir}"
end

execute "install elasticsearch systemd override" do
  command "install -m 0644 -o root -g root #{unit_override_staging} #{unit_override_path}"
  not_if "test -f #{unit_override_path} && diff -q #{unit_override_staging} #{unit_override_path} 2>/dev/null"
  notifies :run, "execute[elasticsearch daemon-reload]", :immediately
  notifies :run, "execute[restart elasticsearch]"
end

execute "elasticsearch daemon-reload" do
  command "systemctl daemon-reload"
  action :nothing
end

# === Stage bootstrap files ===

# bootstrap-init.sh + ILM/template/role JSON — used by bootstrap-init.sh
# at converge time. Unchanged from the docker-era cookbook.
%w[
  ilm-policy-rtx-7d.json
  index-template-rtx.json
  bootstrap-roles.json
].each do |f|
  remote_file "#{files_dir}/#{f}" do
    source "files/#{f}"
    owner user
    group group
    mode "0644"
  end
end

%w[logs-rtx-mappings.json logs-rtx-settings.json].each do |f|
  remote_file "#{files_dir}/component-templates/#{f}" do
    source "files/component-templates/#{f}"
    owner user
    group group
    mode "0644"
  end
end

remote_file "#{files_dir}/bootstrap-init.sh" do
  source "files/bootstrap-init.sh"
  owner user
  group group
  mode "0755"
end

# === SSM-gated env + cert generation ===

generated_dir = "#{node[:setup][:root]}/generated"
directory generated_dir do
  owner user
  group group
  mode "755"
end

env_temp_path   = "#{generated_dir}/elasticsearch.env"
env_output_path = "/etc/elasticsearch/elasticsearch-secrets.env"
generate_env_script = File.join(File.dirname(__FILE__), "files", "generate_env.sh")
fetch_certs_script  = File.join(File.dirname(__FILE__), "files", "fetch_certs.sh")
certs_staging_dir   = "#{generated_dir}/elasticsearch-certs"

# require_external_auth: probe the actual SSM read the cookbook will
# perform, gated to the named profile (per CLAUDE.md
# "Auth-check gate must match the cookbook's actual invocation profile").
require_external_auth(
  tool_name: "AWS CLI (profile=#{aws_profile}, region=#{aws_region}) for /monitoring/elastic/* SSM params",
  check_command: "aws ssm get-parameter --name /monitoring/elastic/elastic-password " \
                 "--with-decryption --profile #{aws_profile} --region #{aws_region} " \
                 "> /dev/null 2>&1",
  instructions: "Configure '#{aws_profile}' with ssm:GetParameter on " \
                "/monitoring/elastic/* in #{aws_region}. " \
                "On a fresh machine: aws configure --profile #{aws_profile}. Then press Enter.",
  # Skip when env file AND all 3 certs already exist at the new
  # /etc/elasticsearch/certs/ location. Previously skipped only on env
  # presence, but the cert path migration (PR #257 fix) required
  # re-fetching certs from SSM into the staging dir even when the env
  # file was already in place from the partial PR #256 apply.
  skip_if: -> {
    File.exist?(env_output_path) &&
      File.exist?("/etc/elasticsearch/certs/ca.crt") &&
      File.exist?("/etc/elasticsearch/certs/#{node_name}.crt") &&
      File.exist?("/etc/elasticsearch/certs/#{node_name}.key")
  },
) do
  execute "generate elasticsearch secrets env" do
    command "AWS_PROFILE=#{aws_profile} AWS_REGION=#{aws_region} " \
            "bash #{generate_env_script} #{env_temp_path} #{node_name} #{transport_host}"
    user user
  end

  execute "fetch elasticsearch certs from SSM" do
    command "AWS_PROFILE=#{aws_profile} AWS_REGION=#{aws_region} " \
            "bash #{fetch_certs_script} #{certs_staging_dir} #{node_name}"
    user user
  end
end

# Install elasticsearch-secrets.env — mode 0640 root:elasticsearch.
# systemd's EnvironmentFile= reads bare KEY=VALUE pairs without shell
# expansion, so metacharacter-bearing passwords (parens, brackets, &)
# are passed through literally. This eliminates the docker-compose
# env_file: + bash source collision that motivated this migration.
execute "install elasticsearch-secrets.env" do
  command "install -m 0640 -o root -g elasticsearch #{env_temp_path} #{env_output_path}"
  only_if "test -f #{env_temp_path} && id elasticsearch >/dev/null 2>&1"
  not_if "test -f #{env_output_path} && diff -q #{env_temp_path} #{env_output_path} 2>/dev/null"
  notifies :run, "execute[restart elasticsearch]"
  notifies :run, "execute[run elasticsearch bootstrap]"
end

file env_temp_path do
  action :delete
  only_if "test -f #{env_temp_path} && test -f #{env_output_path}"
end

# Install certs into /etc/elasticsearch/certs/ — owned by root:elasticsearch.
# CA cert and node cert are mode 0640 (group-readable PEM), node key is
# mode 0600 (root-only). Native ES requires SSL resources under
# /etc/elasticsearch (Java SecurityManager FilePermission constraint).
certs_dir = "/etc/elasticsearch/certs"

%w[ca crt key].each do |kind|
  case kind
  when "ca"
    src  = "#{certs_staging_dir}/ca.crt"
    dest = "#{certs_dir}/ca.crt"
    mode = "0640"
  when "crt"
    src  = "#{certs_staging_dir}/#{node_name}.crt"
    dest = "#{certs_dir}/#{node_name}.crt"
    mode = "0640"
  when "key"
    src  = "#{certs_staging_dir}/#{node_name}.key"
    dest = "#{certs_dir}/#{node_name}.key"
    mode = "0640"
  end

  execute "install elasticsearch cert (#{kind})" do
    command "install -m #{mode} -o root -g elasticsearch #{src} #{dest}"
    only_if "test -f #{src} && id elasticsearch >/dev/null 2>&1"
    not_if "test -f #{dest} && diff -q #{src} #{dest} 2>/dev/null"
    notifies :run, "execute[restart elasticsearch]"
  end
end

# Clean up cert staging once installed.
execute "delete elasticsearch cert staging" do
  command "rm -rf #{certs_staging_dir}"
  only_if "test -d #{certs_staging_dir} && " \
          "test -f #{certs_dir}/ca.crt && " \
          "test -f #{certs_dir}/#{node_name}.crt && " \
          "test -f #{certs_dir}/#{node_name}.key"
end

# === Service activation ===
#
# Adversarial #11 — rolling restart serialization: the auto-mitamae
# orchestrator's per-host loop fires sequentially across LXCs (es-0 →
# es-1 → es-2 in alphabetical order). The `restart elasticsearch`
# notify here re-creates a single node at a time; with replica=1 the
# cluster stays yellow during one node's restart, returns to green when
# it rejoins, then the orchestrator moves on to the next node. Bare
# `systemctl restart` does not pre-flush shards (no
# `cluster.routing.allocation.enable: primaries` dance) — accepted for
# Phase 3b given the small write rate; if write churn grows, fold the
# allocation toggle into a wrapper script invoked here.

execute "enable + start elasticsearch" do
  command "systemctl enable --now elasticsearch.service"
  # Gate on .env + certs + elasticsearch.yml — all required before
  # the service can usefully start.
  only_if <<~SH.tr("\n", " ").strip
    test -f #{env_output_path} || exit 1;
    test -f #{certs_dir}/ca.crt || exit 1;
    test -f #{certs_dir}/#{node_name}.crt || exit 1;
    test -f #{certs_dir}/#{node_name}.key || exit 1;
    test -f #{es_yml_path} || exit 1;
    systemctl is-enabled elasticsearch.service > /dev/null 2>&1 &&
    systemctl is-active elasticsearch.service > /dev/null 2>&1 && exit 1 || exit 0
  SH
  notifies :run, "execute[run elasticsearch bootstrap]"
end

execute "restart elasticsearch" do
  command "systemctl restart elasticsearch.service"
  action :nothing
  only_if "test -f #{env_output_path} && test -f #{es_yml_path} && id elasticsearch >/dev/null 2>&1"
  notifies :run, "execute[run elasticsearch bootstrap]"
end

# === Bootstrap initialization ===
#
# Bootstrap fires after the service is healthy. The bootstrap-init.sh
# handles its own cluster-ready wait (up to 5 min). Adversarial
# #8 / #12 / #14 are encoded in the script.
execute "run elasticsearch bootstrap" do
  command "ES_URL=http://#{transport_host}:9200 ENV_FILE=#{env_output_path} bash #{files_dir}/bootstrap-init.sh #{files_dir}"
  user user
  action :nothing
  only_if "test -f #{env_output_path} && test -f #{files_dir}/bootstrap-init.sh"
end

# Drift-detection sweep on every converge: even when nothing else
# changed, run the bootstrap script to re-probe user passwords against
# SSM. Cheap (a few hundred ms of curl probes when everything is in
# sync) and self-heals after a Terraform-driven password rotate.
#
# Guard changed from `docker ps` to `systemctl is-active elasticsearch`
# (native install — no docker daemon).
execute "ensure elasticsearch bootstrap drift sweep" do
  command "ES_URL=http://#{transport_host}:9200 ENV_FILE=#{env_output_path} bash #{files_dir}/bootstrap-init.sh #{files_dir}"
  user user
  # Skip when the env file is absent (SSM auth not configured yet) or
  # when the service isn't active yet (initial bootstrap will be
  # triggered by the notify chain instead).
  only_if "test -f #{env_output_path} && " \
          "test -f #{files_dir}/bootstrap-init.sh && " \
          "systemctl is-active elasticsearch.service >/dev/null 2>&1"
end

# === Phase 7-s3 — S3 snapshot repository + SLM daily policy ===
#
# Closes ADR 0005 §否定面 #4 (disk SPOF — 3 ES nodes share one USB SSD).
# Adapted from docs/adr/0005-impl/phase-7-s3-cookbook.patch (which targeted
# the docker-based install) for the native systemd ES install Phase 3b
# actually shipped. Companion: home-monitor PR #43 creates the S3 bucket
# + IAM user + SSM creds.
#
# Idempotency:
#   - keystore-add: gated by sha256 sentinel /var/lib/elasticsearch/.s3-keystore-hash
#   - reload-secure-settings: notify-driven from keystore-add
#   - repo / SLM register: gated by GET _snapshot|_slm returning 200

s3_snapshot_script = "/usr/local/bin/elasticsearch-snapshot-bootstrap"

remote_file "#{files_dir}/snapshot-bootstrap.sh" do
  source "files/snapshot-bootstrap.sh"
  owner user
  group group
  mode "0755"
end

execute "stage snapshot-bootstrap.sh" do
  command "install -m 0700 -o root -g root #{files_dir}/snapshot-bootstrap.sh #{s3_snapshot_script}"
  only_if "test -f #{files_dir}/snapshot-bootstrap.sh"
  not_if "test -f #{s3_snapshot_script} && diff -q #{files_dir}/snapshot-bootstrap.sh #{s3_snapshot_script} 2>/dev/null"
end

require_external_auth(
  tool_name: "AWS CLI (profile=#{aws_profile}, region=#{aws_region}) for /monitoring/elastic/s3-snapshot/*",
  check_command: "aws ssm get-parameter --name /monitoring/elastic/s3-snapshot/access-key-id " \
                 "--with-decryption --profile #{aws_profile} --region #{aws_region} " \
                 "> /dev/null 2>&1",
  instructions: "Configure '#{aws_profile}' with ssm:GetParameter on " \
                "/monitoring/elastic/s3-snapshot/* in #{aws_region}. " \
                "home-monitor PR #43 creates these SSM parameters; ensure " \
                "that branch is merged + applied before this cookbook runs.",
  skip_if: -> { !File.exist?(s3_snapshot_script) },
) do
  execute "elasticsearch-snapshot: fetch + keystore add" do
    command "AWS_PROFILE=#{aws_profile} AWS_REGION=#{aws_region} " \
            "#{s3_snapshot_script} keystore-add"
    user "root"
    notifies :run, "execute[elasticsearch-snapshot: reload secure settings]"
  end
end

# Reload secure settings on the local node after keystore add. ES masters
# coordinate the cluster-wide reload automatically.
execute "elasticsearch-snapshot: reload secure settings" do
  command "#{s3_snapshot_script} reload-secure-settings"
  user "root"
  action :nothing
  if node[:elasticsearch] && node[:elasticsearch][:node_name] == "es-0"
    notifies :run, "execute[elasticsearch-snapshot: register repository]"
    notifies :run, "execute[elasticsearch-snapshot: register SLM policy]"
  end
end

execute "elasticsearch-snapshot: register repository" do
  command "#{s3_snapshot_script} register-repo"
  user "root"
  action :nothing
  only_if { node[:elasticsearch] && node[:elasticsearch][:node_name] == "es-0" }
end

# Initial-converge entry: if keystore reload happened in a prior run but
# repo never registered, this ensures it lands. Idempotent at the script.
execute "elasticsearch-snapshot: ensure repository registered" do
  command "#{s3_snapshot_script} register-repo"
  user "root"
  only_if { node[:elasticsearch] && node[:elasticsearch][:node_name] == "es-0" }
  not_if  "#{s3_snapshot_script} repo-exists"
end

execute "elasticsearch-snapshot: register SLM policy" do
  command "#{s3_snapshot_script} register-slm"
  user "root"
  action :nothing
  only_if { node[:elasticsearch] && node[:elasticsearch][:node_name] == "es-0" }
end

execute "elasticsearch-snapshot: ensure SLM policy registered" do
  command "#{s3_snapshot_script} register-slm"
  user "root"
  only_if { node[:elasticsearch] && node[:elasticsearch][:node_name] == "es-0" }
  not_if  "#{s3_snapshot_script} slm-exists"
end
