# frozen_string_literal: true
#
# edge-agent: the OS-independent half — mise install/upgrade, the APM secrets
# fetch, the per-host config.toml, and the state directory.
#
# Included by darwin.rb and linux.rb, in both cases AFTER their (identical)
# host-profile FLEET guard has already returned on a non-fleet host. Locals do
# not cross an include_recipe boundary in mitamae, so the few node reads the
# guard needs are repeated in each caller rather than hoisted here.
#
# Resource order matches the pre-split default.rb exactly: mise install → mise
# use → config dir → APM gate → config.toml → state dir, then the caller's
# per-OS service wiring.

user = node[:setup][:user]
home = node[:setup][:home]
variant = node[:profile][:label]
mise_bin = "#{home}/.local/bin/mise"
edge_spec = "cargo:edge-agent[features=hue,locked=true]"

ssh_keys_config = JSON.parse(File.read(File.join(File.dirname(__FILE__), "..", "ssh-keys", "files", "aws-config.json")))
aws_profile = ssh_keys_config["aws_profile"]
aws_region  = ssh_keys_config["aws_region"]

# Phase 4 APM env paths (used by both Linux systemd --user and macOS launchd
# wrapper). OTEL_EXPORTER_OTLP_HEADERS holds the edge-agent-scoped ApiKey
# fetched from SSM at apply time (mode 0600). apm-ca.crt is the home APM
# Server CA cert; tonic's gRPC TLS handshake verifies against es_ca (not in
# OS roots) so without this the SDK silently drops every batch with "TLS
# handshake error: EOF" visible only in apm-server logs.
apm_env_path = "#{home}/.config/edge-agent/apm.env"
apm_ca_path  = "#{home}/.config/edge-agent/apm-ca.crt"

# Install (and auto-upgrade) via mise's cargo backend. mise resolves @latest each
# call, so a newer crates.io release is picked up on the next mitamae run.
execute "mise install #{edge_spec}@latest" do
  command "#{mise_bin} install '#{edge_spec}@latest'"
  user user
end

execute "mise use --global #{edge_spec}@latest" do
  command "#{mise_bin} use --global '#{edge_spec}@latest'"
  user user
  not_if "grep -q 'cargo:edge-agent' #{home}/.config/mise/config.toml 2>/dev/null"
end

directory "#{home}/.config/edge-agent" do
  owner user
  group node[:setup][:group]
  mode "755"
end

# Phase 4 APM: fetch the per-host ApiKey and CA cert from SSM. Auth gate
# fails-soft in non-TTY contexts so fresh hosts without AWS creds still
# converge the rest of the recipe; the resulting EnvironmentFile is consumed
# with `-` prefix (systemd) / sourced under `[ -f ]` guard (launchd wrapper)
# so its absence is non-fatal.
require_external_auth(
  tool_name: "AWS CLI (profile=#{aws_profile}, region=#{aws_region}) for /monitoring/apm/* SSM params",
  check_command: "aws ssm get-parameter --name /monitoring/apm/api-keys/edge-agent " \
                 "--with-decryption --profile #{aws_profile} --region #{aws_region} " \
                 "> /dev/null 2>&1",
  instructions: "Configure '#{aws_profile}' with ssm:GetParameter on " \
                "/monitoring/apm/* in #{aws_region}. " \
                "On a fresh machine: aws configure --profile #{aws_profile}. Then press Enter.",
  # Content-aware, not bare existence (check 13 / ~/ManagedProjects/setup/.claude/rules/ruby.md): a
  # truncated apm.env or a ca.crt holding an AWS error string would otherwise
  # count as converged forever. Needles are the exact tokens the two gated
  # generators below write. Still NOT rotation detection — a valid-shaped but
  # stale key is out of scope, same as elastic-agent's CA guard.
  skip_if: -> {
    file_has_all?(apm_env_path, ["OTEL_EXPORTER_OTLP_HEADERS=authorization=ApiKey "]) &&
      file_has_all?(apm_ca_path, ["BEGIN CERTIFICATE"])
  },
) do
  execute "generate edge-agent APM env" do
    command <<~SH.strip
      umask 077 && key=$(aws ssm get-parameter \
        --name /monitoring/apm/api-keys/edge-agent \
        --with-decryption \
        --profile #{aws_profile} --region #{aws_region} \
        --query Parameter.Value --output text) && \
        printf 'OTEL_EXPORTER_OTLP_HEADERS=authorization=ApiKey %s\n' "$key" > #{apm_env_path} && \
        chmod 0600 #{apm_env_path}
    SH
    user user
  end

  execute "fetch apm-server CA cert for edge-agent" do
    command "aws ssm get-parameter --name /monitoring/apm/ca/cert " \
            "--profile #{aws_profile} --region #{aws_region} " \
            "--query Parameter.Value --output text > #{apm_ca_path} && " \
            "chmod 0644 #{apm_ca_path}"
    user user
  end
end

remote_file "#{home}/.config/edge-agent/config.toml" do
  owner user
  group node[:setup][:group]
  mode "644"
  source "files/config-#{variant}.toml"
  # Skip when config exists AND no longer references the pre-PVE weave-server
  # endpoint (pro:3101). Hosts still pinned to the old endpoint get the file
  # re-deployed on next mitamae apply. Once neo / air have been migrated, this
  # guard can revert to the simple `test -f` form.
  not_if "test -f #{home}/.config/edge-agent/config.toml && " \
         "! grep -q '192.168.1.20:3101' #{home}/.config/edge-agent/config.toml"
end

directory "#{home}/.local/state/edge-agent" do
  owner user
  group node[:setup][:group]
  mode "755"
end
