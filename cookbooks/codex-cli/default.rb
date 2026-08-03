# frozen_string_literal: true

include_cookbook "mise"

# Install Codex CLI using mise npm backend
execute "$HOME/.local/bin/mise install npm:@openai/codex@latest" do
  user node[:setup][:user]
  not_if "$HOME/.local/bin/mise list npm:@openai/codex | grep -q '@openai/codex'"
end

# Set Codex CLI as globally available
execute "$HOME/.local/bin/mise use --global npm:@openai/codex@latest" do
  user node[:setup][:user]
  not_if "$HOME/.local/bin/mise list npm:@openai/codex | grep -q '\\* '"
end

# Ensure ~/.codex directory exists
directory "#{node[:setup][:home]}/.codex" do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
  action :create
end

# Create generated directory for temporary files
generated_dir = "#{node[:setup][:root]}/generated"
directory generated_dir do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
  action :create
end

# Generate codex config.toml using shell script
# This uses the same servers.yml as mcp cookbook
mcp_yaml_path = File.join(File.dirname(__FILE__), "..", "mcp", "files", "servers.yml")
generator_script = File.join(File.dirname(__FILE__), "files", "generate_config.sh")
temp_path = "#{generated_dir}/codex_config.toml"
output_path = "#{node[:setup][:home]}/.codex/config.toml"

# NO auth gate here, deliberately (2026-08 gap decision): generate_config.sh
# skips EVERY `platforms:`-pinned server on every OS ("codex runs
# cross-platform" filter at its ~:102), and the only `ssm:` entry in mcp's
# servers.yml (obsidian-api-key) sits on a darwin-pinned server — so the codex
# render resolves ZERO SSM parameters anywhere. The old gate probed
# /mcp/obsidian-api-key anyway, which the fleet identity cannot read, so LXC
# applies silently skipped the codex config for a credential the generator
# never used (surfaced by gate-report as mitamae_gate_attention on pro-dev).
#
# CONTRACT: if an UNPINNED servers.yml entry ever gains `ssm:` (or url.ssm),
# reinstate a require_external_auth gate here probing that exact path.
#
# Generate, install, and clean up in one atomic execute. A previous split
# into separate generate / remote_file / file resources had a compile-vs-
# converge ordering bug: the deploy step gated by Ruby's `if File.exist?(
# temp_path)` evaluated at recipe-load time, before the generate execute
# had run, so the deploy and cleanup resources were never declared on a
# clean run. Folding the three steps into one shell pipeline sidesteps the
# ordering issue entirely.
execute "generate and deploy codex config.toml" do
  # Wrap in `bash -c` because mitamae's execute runs via /bin/sh, which is
  # dash on Ubuntu and rejects `set -o pipefail`.
  # umask 077 + install -m 600: the generator prepends
  # ~/.codex/config-preamble.toml when present, and that preamble can carry
  # provider auth (e.g. an `Authorization = "Bearer sk-..."` http_headers
  # entry), so both the temp file and the deployed config are owner-only.
  command <<~CMD.strip
    bash -c '
      set -euo pipefail
      umask 077
      export PATH="#{node[:setup][:home]}/.local/share/mise/shims:$PATH"
      bash #{generator_script} #{mcp_yaml_path} #{temp_path}
      install -m 600 #{temp_path} #{output_path}
      rm -f #{temp_path}
    '
  CMD
  user node[:setup][:user]
end
