# frozen_string_literal: true
#
# memory-keeper: async write-intelligence worker for the unified memory MCP (v2).
#
# The memory-mcp server (CT119) has NO LLM. All write intelligence — fact
# reconciliation and nightly consolidation — runs here on mini (the always-on
# Mac) via `claude -p` (subscription, no API key) with direct LAN access to the
# ES cluster. See ~/.claude/plans/unified-memory-design-v3.md §6 and the frozen
# contract ~/.claude/plans/memory-v2-contract.md §§1,2c,6.
#
# Deploy shape (mini only):
#   - Two LaunchDaemons (mini has NO GUI/Aqua session, so LaunchAgents can't run):
#       com.shin1ohno.memory-keeper       — reconcile tick, StartInterval 60
#       com.shin1ohno.memory-consolidate  — nightly job, 03:30 local
#     Both are root:wheel in /Library/LaunchDaemons but carry
#     <key>UserName</key><string>shin1ohno</string> so the process runs AS
#     shin1ohno — required to reach ~/.claude/.credentials.json + the
#     ~/.local/bin/claude subscription binary. LaunchDaemons do NOT set HOME, so
#     the wrapper scripts export HOME=/Users/shin1ohno themselves.
#   - Wrapper scripts (/usr/local/bin/memory-*-run.sh) + keeper python
#     (/usr/local/lib/memory-keeper/) live on stable, daemon-traversable system
#     paths (root:wheel), staged in user-space then sudo-installed with diff
#     guards — same posture as cookbooks/eternal-terminal's et-watchdog.
#   - keeper.env (~/.config/memory-keeper/keeper.env, mode 600) holds the ES
#     password + Voyage key + index/model config, fetched from SSM via a
#     content-aware require_external_auth gate.
#
# Identity is resolved once by cookbooks/host-profile (node[:profile][:label]);
# mini is the sole converge target. Every other host is skipped — same pattern
# as edge-agent / macos-hub.

label = node[:profile][:label]

unless label == "mini"
  MItamae.logger.warn(
    "memory-keeper: host '#{node[:profile][:hostname]}' is not mini " \
    "(node[:profile][:label]=#{label.inspect}) — memory-keeper only converges on mini.",
  )
  return
end

user = node[:setup][:user]
home = node[:setup][:home]
sys_user = node[:setup][:system_user]
sys_group = node[:setup][:system_group]

# aws_profile / aws_region for the SSM gate come from the same bootstrap config
# the ssh-keys cookbook uses (pve-bootstrap-ssm; /memory/* + /monitoring/* are
# inside its scoped grant).
ssh_keys_config = JSON.parse(File.read(File.join(File.dirname(__FILE__), "..", "ssh-keys", "files", "aws-config.json")))
aws_profile = ssh_keys_config["aws_profile"]
aws_region  = ssh_keys_config["aws_region"]

config_dir = "#{home}/.config/memory-keeper"
state_dir  = "#{home}/.local/state/memory-keeper"
keeper_env = "#{config_dir}/keeper.env"

staging_dir = "#{node[:setup][:root]}/memory-keeper"
lib_dir = "/usr/local/lib/memory-keeper"
bin_dir = "/usr/local/bin"

# --- config + state directories (owned by the runtime user) ----------------
directory node[:setup][:root] do
  mode "755"
end

directory config_dir do
  owner user
  mode "755"
end

directory state_dir do
  owner user
  mode "755"
end

directory staging_dir do
  owner user
  mode "755"
end

# --- keeper.env via SSM (content-aware skip_if, NOT File.exist?) ------------
# Grep for VOYAGE_API_KEY so that ADDING a key to generate_keeper_env.sh later
# actually re-generates on warm hosts (File.exist? alone would silently skip —
# the SSM/.env drift trap in ~/.claude/rules/ruby.md).
generate_script_staging = "#{staging_dir}/generate_keeper_env.sh"

remote_file generate_script_staging do
  source "files/generate_keeper_env.sh"
  owner user
  mode "0755"
end

require_external_auth(
  tool_name: "AWS CLI (profile=#{aws_profile}, region=#{aws_region}) for /memory/* + /monitoring/elastic/* SSM params",
  check_command: "aws ssm get-parameter --name /memory/voyage-api-key " \
                 "--with-decryption --profile #{aws_profile} --region #{aws_region} " \
                 "> /dev/null 2>&1",
  instructions: "Configure '#{aws_profile}' with ssm:GetParameter on /memory/* and " \
                "/monitoring/elastic/* (+ KMS decrypt) in #{aws_region}. " \
                "On a fresh machine: aws configure --profile #{aws_profile}. Then press Enter.",
  skip_if: -> {
    File.exist?(keeper_env) &&
      File.read(keeper_env).include?("VOYAGE_API_KEY=") &&
      File.read(keeper_env).include?("ES_PASSWORD=")
  },
) do
  execute "generate memory-keeper keeper.env" do
    command "AWS_PROFILE=#{aws_profile} AWS_REGION=#{aws_region} " \
            "bash #{generate_script_staging} #{keeper_env}"
    user user
  end
end

# --- wrapper scripts -> /usr/local/bin (root:wheel, daemon-executable) ------
%w[memory-keeper-run.sh memory-consolidate-run.sh].each do |wrapper|
  wrapper_staging = "#{staging_dir}/#{wrapper}"

  remote_file wrapper_staging do
    source "files/#{wrapper}"
    owner user
    mode "0755"
  end

  execute "install #{wrapper} to #{bin_dir}" do
    user sys_user
    command "mkdir -p #{bin_dir} && " \
            "cp #{wrapper_staging} #{bin_dir}/#{wrapper} && " \
            "chmod 0755 #{bin_dir}/#{wrapper} && " \
            "chown #{sys_user}:#{sys_group} #{bin_dir}/#{wrapper}"
    not_if "test -f #{bin_dir}/#{wrapper} && diff -q #{wrapper_staging} #{bin_dir}/#{wrapper} >/dev/null 2>&1"
  end
end

# --- keeper python + prompts -> /usr/local/lib/memory-keeper ----------------
# Flatten files/keeper/** into the lib dir so `python3 .../reconcile.py`
# resolves its sibling modules (es_client / voyage_client / claude_judge) and
# prompts/ via __file__. StartInterval re-runs the wrapper each cycle in a
# fresh python process, so a changed .py is picked up next tick WITHOUT a
# launchctl reload — only plist changes need a reload (below).
directory "#{staging_dir}/lib" do
  owner user
  mode "755"
end

directory "#{staging_dir}/lib/prompts" do
  owner user
  mode "755"
end

lib_payload = {
  "keeper/es_client.py"         => "es_client.py",
  "keeper/voyage_client.py"     => "voyage_client.py",
  "keeper/claude_judge.py"      => "claude_judge.py",
  "keeper/reconcile.py"         => "reconcile.py",
  "keeper/consolidate.py"       => "consolidate.py",
  "keeper/prompts/reconcile.md" => "prompts/reconcile.md",
  "keeper/prompts/promote.md"   => "prompts/promote.md",
}

lib_payload.each do |src, dest|
  src_staging = "#{staging_dir}/lib/#{dest}"

  remote_file src_staging do
    source "files/#{src}"
    owner user
    mode "0644"
  end

  dest_path = "#{lib_dir}/#{dest}"
  dest_parent = File.dirname(dest_path)

  execute "install memory-keeper #{dest}" do
    user sys_user
    command "mkdir -p #{dest_parent} && " \
            "cp #{src_staging} #{dest_path} && " \
            "chmod 0644 #{dest_path} && " \
            "chown #{sys_user}:#{sys_group} #{dest_path}"
    not_if "test -f #{dest_path} && diff -q #{src_staging} #{dest_path} >/dev/null 2>&1"
  end
end

# --- LaunchDaemons -> /Library/LaunchDaemons (root:wheel, UserName shin1ohno)
# Same stage -> cp+chown -> launchctl load -w -> notify-driven reload (diff-q
# guard) pattern as cookbooks/eternal-terminal's et-watchdog daemon.
{
  "com.shin1ohno.memory-keeper.plist"     => "com.shin1ohno.memory-keeper",
  "com.shin1ohno.memory-consolidate.plist" => "com.shin1ohno.memory-consolidate",
}.each do |plist_file, plist_label|
  plist_staging = "#{staging_dir}/#{plist_file}"

  remote_file plist_staging do
    source "files/#{plist_file}"
    owner user
    mode "0644"
  end

  execute "copy #{plist_label} launch daemon" do
    user sys_user
    command "cp #{plist_staging} /Library/LaunchDaemons/#{plist_file} && " \
            "chown #{sys_user}:#{sys_group} /Library/LaunchDaemons/#{plist_file}"
    not_if "diff -q #{plist_staging} /Library/LaunchDaemons/#{plist_file} >/dev/null 2>&1"
    notifies :run, "execute[reload #{plist_label} daemon]", :delayed
  end

  execute "load #{plist_label} daemon" do
    user sys_user
    command "launchctl load -w /Library/LaunchDaemons/#{plist_file}"
    not_if "launchctl list | grep -q #{plist_label}"
  end

  execute "reload #{plist_label} daemon" do
    user sys_user
    command "launchctl unload /Library/LaunchDaemons/#{plist_file} 2>/dev/null; " \
            "launchctl load -w /Library/LaunchDaemons/#{plist_file}"
    action :nothing
  end
end
