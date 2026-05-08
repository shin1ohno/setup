# frozen_string_literal: true
#
# mcp-probe: systemd timer that runs an MCP-protocol prober (OAuth ->
# initialize -> tools/list) once per minute against mcp.ohno.be. The
# probe writes Prometheus textfile metrics into the node_exporter
# textfile collector dir, picked up by the existing scrape jobs and
# surfaced on the Grafana mcp-fleet-health dashboard.
#
# Extracted from cookbooks/lxc-monitoring during Phase 7 — the prober
# is logically distinct from the observability docker stack (system
# systemd timer + python script, not a docker compose service) and
# benefits from its own cookbook.
#
# Depends on:
#   - python3 (Debian 13 minimal LXC default)
#   - cookbooks/node-exporter (writes to /var/lib/node_exporter/textfile)
#   - cookbooks/awscli (SSM fetch for /monitoring/mcp-prober-* params)
#   - cookbooks/hydra-server having registered the monitoring-prober
#     Hydra client first (per the require_external_auth instructions
#     below) — fetch-secrets.sh fails until those SSM params exist.

return if node[:platform] == "darwin"

include_cookbook "awscli"

# Reuse the AWS profile / region convention from cookbooks/ssh-keys so
# the require_external_auth check_command matches the actual SSM
# invocation profile (per ~/.claude/rules/ruby.md "Auth-check gate must
# match the cookbook's actual invocation profile").
ssh_keys_config = JSON.parse(File.read(File.join(File.dirname(__FILE__), "..", "ssh-keys", "files", "aws-config.json")))
aws_profile = ssh_keys_config["aws_profile"]
aws_region  = ssh_keys_config["aws_region"]

user = node[:setup][:user]
group = node[:setup][:group]

# Defensive: setup_root + per-cookbook subdir before remote_file writes.
directory node[:setup][:root] do
  mode "755"
end

mcp_probe_staging = "#{node[:setup][:root]}/mcp-probe"
directory mcp_probe_staging do
  owner user
  group group
  mode "755"
end

remote_file "#{mcp_probe_staging}/probe.py" do
  source "files/probe.py"
  owner user
  group group
  mode "0755"
end

remote_file "#{mcp_probe_staging}/fetch-secrets.sh" do
  source "files/fetch-secrets.sh"
  owner user
  group group
  mode "0755"
end

%w[mcp-probe.service mcp-probe.timer].each do |unit|
  remote_file "#{mcp_probe_staging}/#{unit}" do
    source "files/#{unit}"
    owner user
    group group
    mode "0644"
  end
end

# Install the python script into a system PATH location.
execute "install /usr/local/bin/mcp-probe.py" do
  command "sudo install -m 755 -o root -g root " \
          "#{mcp_probe_staging}/probe.py /usr/local/bin/mcp-probe.py"
  not_if "diff -q #{mcp_probe_staging}/probe.py /usr/local/bin/mcp-probe.py 2>/dev/null"
  notifies :run, "execute[restart mcp-probe.timer]"
end

# /etc/mcp-probe/ holds the EnvironmentFile consumed by mcp-probe.service.
execute "ensure /etc/mcp-probe directory" do
  command "sudo install -d -m 755 -o root -g root /etc/mcp-probe"
  not_if "test -d /etc/mcp-probe"
end

# /var/lib/node_exporter/textfile — node_exporter scrapes this dir
# (matches `--collector.textfile.directory` in the node-exporter
# cookbook's unit file). Defensive ensure-exists — a no-op when the
# node-exporter cookbook has already converged on this host.
execute "ensure node_exporter textfile directory" do
  command "sudo install -d -m 755 -o root -g root " \
          "/var/lib/node_exporter/textfile"
  not_if "test -d /var/lib/node_exporter/textfile"
end

# Install systemd unit + timer.
%w[mcp-probe.service mcp-probe.timer].each do |unit|
  execute "install /etc/systemd/system/#{unit}" do
    command "sudo install -m 644 -o root -g root " \
            "#{mcp_probe_staging}/#{unit} /etc/systemd/system/#{unit}"
    not_if "diff -q #{mcp_probe_staging}/#{unit} /etc/systemd/system/#{unit} 2>/dev/null"
    notifies :run, "execute[mcp-probe systemctl daemon-reload]"
  end
end

execute "mcp-probe systemctl daemon-reload" do
  command "sudo systemctl daemon-reload"
  action :nothing
end

# Generate /etc/mcp-probe/probe.env from SSM. Stage in setup_root/generated,
# then install with `only_if test -f` so the converge-time presence check
# matches the converge-time creation (~/.claude/rules/ruby.md "Mitamae
# evaluation model — top-level Ruby is compile-time").
generated_dir = "#{node[:setup][:root]}/generated"
directory generated_dir do
  owner user
  group group
  mode "755"
end

probe_env_temp   = "#{generated_dir}/mcp-probe.env"
probe_env_system = "/etc/mcp-probe/probe.env"
probe_env_script = "#{mcp_probe_staging}/fetch-secrets.sh"

require_external_auth(
  tool_name: "AWS CLI for /monitoring/mcp-prober-{client-id,client-secret} SSM params",
  check_command: "aws ssm get-parameter --name /monitoring/mcp-prober-client-id " \
                 "--profile #{aws_profile} --region #{aws_region} > /dev/null 2>&1",
  instructions: "Run cookbooks/hydra-server first (on the Hydra LXC, CT 106) — " \
                "it registers the monitoring-prober Hydra client and writes " \
                "client-id/secret to SSM. Then this cookbook can fetch them.",
  skip_if: -> { File.exist?(probe_env_system) },
) do
  execute "generate mcp-probe env" do
    command "AWS_PROFILE=#{aws_profile} AWS_REGION=#{aws_region} " \
            "bash #{probe_env_script} #{probe_env_temp}"
    user user
  end
end

# Install at converge time when the temp env was successfully generated.
execute "install /etc/mcp-probe/probe.env" do
  command "sudo install -m 600 -o root -g root #{probe_env_temp} #{probe_env_system}"
  only_if "test -f #{probe_env_temp}"
  notifies :run, "execute[restart mcp-probe.timer]"
end

execute "delete mcp-probe staging env" do
  command "rm -f #{probe_env_temp}"
  only_if "test -f #{probe_env_temp}"
end

# Enable the timer once the env file is in place. The unit's
# EnvironmentFile= directive blocks startup if probe.env is absent,
# so gating the enable on that file presence avoids start failures
# on a fresh host where SSM auth hasn't been configured yet.
execute "enable mcp-probe.timer" do
  command "sudo systemctl enable --now mcp-probe.timer"
  only_if "test -f #{probe_env_system}"
  not_if "systemctl is-enabled --quiet mcp-probe.timer 2>/dev/null && " \
         "systemctl is-active --quiet mcp-probe.timer 2>/dev/null"
end

execute "restart mcp-probe.timer" do
  command "sudo systemctl restart mcp-probe.timer"
  action :nothing
  # Skip when systemd unit was not yet installed (e.g. fresh host where
  # the install step is still pending or SSM-gated bootstrap is incomplete).
  only_if "systemctl list-unit-files mcp-probe.timer 2>/dev/null | grep -q mcp-probe.timer"
end
