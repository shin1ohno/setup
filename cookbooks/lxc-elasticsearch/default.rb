# frozen_string_literal: true
#
# lxc-elasticsearch (CT 112 / 113 / 114): Elasticsearch 8.x master+data+ingest
# node, one of a 3-node cluster. The same cookbook ships to all three CTs;
# per-LXC divergence is parameterised through node attributes set in the
# pve/lxc-es-{0,1,2}.rb entry recipes:
#
#   node[:elasticsearch][:node_name]      "es-0" | "es-1" | "es-2"
#   node[:elasticsearch][:transport_host] "192.168.1.112" | ".113" | ".114"
#
# Stack:
#   - docker.elastic.co/elasticsearch/elasticsearch:8.16.0  :9200 (HTTP, LAN)
#                                                            :9300 (transport)
#
# State volume (host bind-mount): /data/elasticsearch/{data,logs,certs}
#   — on PVE host /mnt/data/elasticsearch/<node>/ (USB X8 SSD, 200 GB).
#   — Phase 3a manual op chowns the parent dir 100000:100000 so it
#     surfaces as root:root inside the container; the cookbook chowns
#     the data/ logs/ subdirs to UID 1000 (= host UID 101000) so the
#     ES image's elasticsearch user can write to them.
#
# Phase 3b ships transport-TLS only. HTTP TLS comes in Phase 7-tls.
#
# Adversarial findings folded in:
#   #2  bind-mount UID — parent root, subdirs UID 1000
#   #6  .env mode 0600 root:root, no embedded URLs
#   #8  ILM bootstrap order: ILM → component → index template → data stream → roles → users
#   #11 Rolling restart serialization — see notes in §restart section
#   #12 Atomic kibana_system reset before Kibana cookbook reads SSM password
#   #14 Drift detection — SSM password vs ES auth probe → reset on mismatch

return if node[:platform] == "darwin"

include_cookbook "docker-engine"
include_cookbook "awscli"

# Reuse the AWS profile / region convention from cookbooks/ssh-keys so the
# require_external_auth check_command and the .env / cert generators all
# target the same IAM principal (per CLAUDE.md "Auth-check gate must match
# the cookbook's actual invocation profile").
ssh_keys_config = JSON.parse(File.read(File.join(File.dirname(__FILE__), "..", "ssh-keys", "files", "aws-config.json")))
aws_profile = ssh_keys_config["aws_profile"]
aws_region  = ssh_keys_config["aws_region"]

node_name      = node[:elasticsearch] && node[:elasticsearch][:node_name]
transport_host = node[:elasticsearch] && node[:elasticsearch][:transport_host]

if node_name.nil? || transport_host.nil?
  raise "lxc-elasticsearch: node[:elasticsearch][:node_name] and " \
        "[:transport_host] must be set in the pve/lxc-es-*.rb entry recipe"
end

user       = node[:setup][:user]
group      = node[:setup][:group]
deploy_dir = "#{node[:setup][:home]}/deploy/elasticsearch"
state_dir  = "/data/elasticsearch"

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
# all live here at converge time so the bootstrap script can read them
# without needing the deploy_dir layout.
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

# Deploy directory (compose project root).
directory deploy_dir do
  owner user
  group group
  mode "755"
end

# State volumes — bind-mount targets. Adversarial #2: in-container
# subdirs MUST be owned by UID 1000 (the elasticsearch image user).
# In-namespace root has CAP_CHOWN over UIDs in the mapped range
# (0..65535 inside ↔ 100000..165535 host), so chown to "1000" inside
# the container succeeds. The parent /data/elasticsearch directory
# itself is created on the host by Phase 3a manual op (chown
# 100000:100000); from inside the container it appears as root:root.
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

%w[data logs certs].each do |sub|
  directory "#{state_dir}/#{sub}" do
    # String UIDs — Integer raises InvalidTypeError per
    # ~/.claude/rules/ruby.md "owner/group must be String".
    owner "1000"
    group "1000"
    mode "755"
  end
end

# === compose + config files ===

remote_file "#{deploy_dir}/docker-compose.yml" do
  source "files/docker-compose.yml"
  owner user
  group group
  mode "0644"
  notifies :run, "execute[restart elasticsearch]"
end

# elasticsearch.yml is rendered from a template by substituting NODE_NAME
# and TRANSPORT_HOST. snmp_yml-pattern: a tmpl is shipped, a sed step
# produces the final yaml.
es_yml_tmpl = "#{deploy_dir}/elasticsearch.yml.tmpl"
es_yml_path = "#{deploy_dir}/elasticsearch.yml"

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
    mv #{es_yml_path}.new #{es_yml_path}
    chmod 644 #{es_yml_path}
  SH
  user user
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
    mv #{es_yml_path}.new #{es_yml_path}
    chmod 644 #{es_yml_path}
  SH
  user user
  only_if "test -f #{es_yml_tmpl} && ! test -f #{es_yml_path}"
end

# Stage bootstrap files (used by bootstrap-init.sh, not the container).
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
env_output_path = "#{deploy_dir}/.env"
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
  skip_if: -> { File.exist?(env_output_path) },
) do
  execute "generate elasticsearch .env" do
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

# Place .env at converge time. Mode 0600 (Adversarial #6) — passwords
# are world-unreadable. Owned by host user (matches deploy_dir owner);
# the elasticsearch container reads .env via compose's `env_file:` which
# happens on the host before any process is spawned, so container UID
# does not need to read the file directly.
remote_file env_output_path do
  source env_temp_path
  owner user
  group group
  mode "0600"
  notifies :run, "execute[restart elasticsearch]"
  notifies :run, "execute[run elasticsearch bootstrap]"
  only_if "test -f #{env_temp_path}"
end

file env_temp_path do
  action :delete
  only_if "test -f #{env_temp_path}"
end

# Install certs into the bind-mounted /data/elasticsearch/certs/ — owned
# by UID 1000 to match the in-container elasticsearch user. CA cert and
# node cert are mode 0644 (public PEM), node key is mode 0600 (secret).
%w[ca crt key].each do |kind|
  case kind
  when "ca"
    src  = "#{certs_staging_dir}/ca.crt"
    dest = "#{state_dir}/certs/ca.crt"
    mode = "0644"
  when "crt"
    src  = "#{certs_staging_dir}/#{node_name}.crt"
    dest = "#{state_dir}/certs/#{node_name}.crt"
    mode = "0644"
  when "key"
    src  = "#{certs_staging_dir}/#{node_name}.key"
    dest = "#{state_dir}/certs/#{node_name}.key"
    mode = "0600"
  end

  execute "install elasticsearch cert (#{kind})" do
    command "sudo install -m #{mode} -o 1000 -g 1000 #{src} #{dest}"
    only_if "test -f #{src}"
    not_if "test -f #{dest} && diff -q #{src} #{dest} 2>/dev/null"
    notifies :run, "execute[restart elasticsearch]"
  end
end

# Clean up cert staging once installed.
execute "delete elasticsearch cert staging" do
  command "rm -rf #{certs_staging_dir}"
  only_if "test -d #{certs_staging_dir} && " \
          "test -f #{state_dir}/certs/ca.crt && " \
          "test -f #{state_dir}/certs/#{node_name}.crt && " \
          "test -f #{state_dir}/certs/#{node_name}.key"
end

# === docker compose orchestration ===
#
# We do NOT use the compose_service DSL here because the bootstrap step
# (run-once-on-converge ES API initialization) needs to fire AFTER the
# container is healthy, AFTER the compose `up -d`. Encoding that ordering
# inline gives us the chance to gate on the env-file existence and the
# cluster-readiness wait baked into bootstrap-init.sh.
#
# Adversarial #11 — rolling restart serialization: the auto-mitamae
# orchestrator's per-host loop fires sequentially across LXCs (es-0 →
# es-1 → es-2 in alphabetical order). The `restart elasticsearch`
# notify here re-creates a single node at a time; with replica=1 the
# cluster stays yellow during one node's restart, returns to green when
# it rejoins, then the orchestrator moves on to the next node. Bare
# `up -d --force-recreate` does not pre-flush shards (no
# `cluster.routing.allocation.enable: primaries` dance) — accepted for
# Phase 3b given the small write rate; if write churn grows, fold the
# allocation toggle into a wrapper script invoked here.
compose_path = "#{deploy_dir}/docker-compose.yml"
project_name = File.basename(deploy_dir)

execute "ensure elasticsearch running" do
  command "DOCKER_BUILDKIT=0 docker compose -f #{compose_path} up -d"
  user user
  # Gate on .env, certs, and elasticsearch.yml — all required before
  # the container is allowed to start.
  only_if <<~SH.tr("\n", " ").strip
    test -f #{env_output_path} || exit 1;
    test -f #{state_dir}/certs/ca.crt || exit 1;
    test -f #{state_dir}/certs/#{node_name}.crt || exit 1;
    test -f #{state_dir}/certs/#{node_name}.key || exit 1;
    test -f #{es_yml_path} || exit 1;
    expected=$(docker compose -f #{compose_path} config --services 2>/dev/null | sort | tr '\\n' ' ');
    [ -n "$expected" ] || exit 1;
    running=$(docker ps --filter "label=com.docker.compose.project=#{project_name}"
                        --filter status=running --format '{{.Label "com.docker.compose.service"}}'
              | sort | tr '\\n' ' ');
    test "$running" = "$expected" && exit 1 || exit 0
  SH
  notifies :run, "execute[run elasticsearch bootstrap]"
end

execute "restart elasticsearch" do
  # --force-recreate is mandatory per ~/.claude/rules/docker-compose.md —
  # bind-mount edits to elasticsearch.yml / certs / .env are otherwise
  # silently ignored on already-running containers.
  command "DOCKER_BUILDKIT=0 docker compose -f #{compose_path} up -d --force-recreate"
  user user
  action :nothing
  only_if "test -f #{env_output_path} && test -f #{es_yml_path}"
  notifies :run, "execute[run elasticsearch bootstrap]"
end

# Bootstrap initialization — runs after the container is healthy. The
# bootstrap-init.sh handles its own cluster-ready wait (up to 5 min).
# Adversarial #8 / #12 / #14 are all encoded in the script.
execute "run elasticsearch bootstrap" do
  command "ENV_FILE=#{env_output_path} bash #{files_dir}/bootstrap-init.sh #{files_dir}"
  user user
  action :nothing
  only_if "test -f #{env_output_path} && test -f #{files_dir}/bootstrap-init.sh"
end

# Drift-detection sweep on every converge: even when nothing else
# changed, run the bootstrap script to re-probe user passwords against
# SSM. Cheap (a few hundred ms of curl probes when everything is in
# sync) and self-heals after a Terraform-driven password rotate.
execute "ensure elasticsearch bootstrap drift sweep" do
  command "ENV_FILE=#{env_output_path} bash #{files_dir}/bootstrap-init.sh #{files_dir}"
  user user
  # Skip when the env file is absent (SSM auth not configured yet) or
  # when the container isn't running yet (initial bootstrap will be
  # triggered by the notify chain instead).
  only_if "test -f #{env_output_path} && " \
          "test -f #{files_dir}/bootstrap-init.sh && " \
          "docker ps --filter name=^elasticsearch$ --filter status=running --format '{{.Names}}' | grep -q '^elasticsearch$'"
end
