# frozen_string_literal: true

# Claude Code is Anthropic's agentic coding tool for the terminal
# Installed via native installer (https://code.claude.com/docs/en/setup)

include_cookbook "mcp"

claude_path = "#{node[:setup][:home]}/.local/bin/claude"
profile_dir = "#{node[:setup][:root]}/profile.d"

# Remove legacy profile that aliases claude to mise shim
file "#{profile_dir}/50-claude-code.sh" do
  action :delete
end

# Remove claude-code from mise: global config, install tracking, and installs
mise_installs_toml = "#{node[:setup][:home]}/.local/share/mise/installs/.mise-installs.toml"
execute "remove claude-code from mise" do
  user node[:setup][:user]
  command <<~SH
    $HOME/.local/bin/mise unuse --global "npm:@anthropic-ai/claude-code@latest" 2>/dev/null
    $HOME/.local/bin/mise uninstall --all npm:@anthropic-ai/claude-code 2>/dev/null
    $HOME/.local/bin/mise uninstall --all claude 2>/dev/null
    rm -rf $HOME/.local/share/mise/installs/claude
    rm -rf $HOME/.local/share/mise/installs/npm-anthropic-ai-claude-code
    python3 -c "
import re
f = '#{mise_installs_toml}'
t = open(f).read()
t = re.sub(r'\\[claude\\]\\n(?:(?!\\[)[^\\n]*\\n)*\\n?', '', t)
t = re.sub(r'\\[npm-anthropic-ai-claude-code\\]\\n(?:(?!\\[)[^\\n]*\\n)*\\n?', '', t)
open(f,'w').write(t)
" 2>/dev/null
  SH
  only_if "grep -qE '^\\[claude\\]$|^\\[npm-anthropic-ai-claude-code\\]$' #{mise_installs_toml} 2>/dev/null || grep -q 'claude-code' $HOME/.config/mise/config.toml 2>/dev/null"
end

# Remove claude-code installed as npm global under mise-managed node
execute "remove claude-code from mise node globals" do
  user node[:setup][:user]
  command "find $HOME/.local/share/mise/installs/node -name claude -path '*/bin/claude' -delete 2>/dev/null; rm -rf $HOME/.local/share/mise/installs/node/*/lib/node_modules/@anthropic-ai/claude-code"
  only_if "find $HOME/.local/share/mise/installs/node -name claude -path '*/bin/claude' 2>/dev/null | grep -q claude"
end

# Remove claude-code from volta if previously installed
execute "remove claude-code from volta" do
  user node[:setup][:user]
  command "$HOME/.volta/bin/volta uninstall @anthropic-ai/claude-code 2>/dev/null; rm -f $HOME/.volta/bin/claude"
  only_if "test -f $HOME/.volta/bin/claude"
end

# Install Claude Code via native installer
execute "install claude-code via native installer" do
  user node[:setup][:user]
  command "curl -fsSL https://claude.ai/install.sh | bash"
  not_if "test -f #{claude_path}"
end

directory "#{node[:setup][:home]}/.claude" do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
  action :create
end

remote_file "#{node[:setup][:home]}/.claude/CLAUDE.md" do
  source "files/CLAUDE.md"
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "644"
  action :create
end

# Merge managed keys into settings.json, preserving unmanaged keys (e.g. mcpServers)
# Deep-merges `permissions` so machine-specific allow/deny entries are preserved
settings_path = "#{node[:setup][:home]}/.claude/settings.json"
managed_file  = File.join(File.dirname(__FILE__), "files", "settings.json")

managed  = JSON.parse(File.read(managed_file))
existing = File.exist?(settings_path) ? (JSON.parse(File.read(settings_path)) rescue {}) : {}

# Shallow merge for all top-level keys (managed wins)
merged = existing.merge(managed)

# Deep merge for permissions: union the allow and deny arrays
if existing.key?("permissions") && managed.key?("permissions")
  %w[allow deny].each do |key|
    existing_entries = existing.dig("permissions", key) || []
    managed_entries  = managed.dig("permissions", key) || []
    merged["permissions"][key] = (existing_entries | managed_entries)
  end
end

file settings_path do
  content JSON.pretty_generate(merged) + "\n"
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "644"
end

# Deploy hook scripts
directory "#{node[:setup][:home]}/.claude/hooks" do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
  action :create
end

remote_file "#{node[:setup][:home]}/.claude/hooks/pre-commit-test.py" do
  source "files/hooks/pre-commit-test.py"
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
  action :create
end

# Deploy global rules
directory "#{node[:setup][:home]}/.claude/rules" do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
  action :create
end

%w(ruby.md shell.md infrastructure.md review.md writing.md).each do |file_name|
  remote_file "#{node[:setup][:home]}/.claude/rules/#{file_name}" do
    source "files/rules/#{file_name}"
    owner node[:setup][:user]
    group node[:setup][:group]
    mode "644"
    action :create
  end
end

