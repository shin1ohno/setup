# frozen_string_literal: true

# Opt-in only (not included by default.rb): no login and no permission changes.
# The one credential link is each Codex home's auth.json, a symlink to the
# file-store ~/.codex/auth.json so a profile home shares the existing login
# without copying it.
profiles = %w(common dev cos writing)
codex_homes = "#{node[:setup][:home]}/.agents/codex-homes"

%w(.agents .agents/profiles .claude .claude/agents).each do |name|
  directory "#{node[:setup][:home]}/#{name}" do
    owner node[:setup][:user]
    group node[:setup][:group]
    mode "755"
  end
end

# Render and check every profile at compile time, before any profile resource
# is declared: an oversized profile aborts the run before anything converges.
contents = {}
profiles.each do |profile|
  layers = profile == "common" ? %w(common) : ["common", profile]
  contents[profile] = {}
  %w(claude codex).each do |harness|
    contents[profile][harness] = layers.map do |layer|
      File.read(File.join(File.dirname(__FILE__), "files/instructions/generated/#{layer}.#{harness}.md"))
    end.join("\n")
  end
  raise "Codex #{profile} profile exceeds 32768 bytes" if contents[profile]["codex"].bytesize > 32768
end

directory codex_homes do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "700"
end

profiles.each do |profile|
  contents[profile].each do |harness, content|
    file "#{node[:setup][:home]}/.agents/profiles/#{profile}.#{harness}.md" do
      content content
      owner node[:setup][:user]
      group node[:setup][:group]
      mode "644"
    end
  end

  file "#{node[:setup][:home]}/.claude/agents/profile-#{profile}.md" do
    content "---\nname: profile-#{profile}\ndescription: Explicit #{profile} worker profile\nomitClaudeMd: true\n---\n\n#{contents[profile]["claude"]}"
    owner node[:setup][:user]
    group node[:setup][:group]
    mode "644"
  end

  # One fixed CODEX_HOME per profile: the profile is the home's AGENTS.md,
  # project docs are off so a repository AGENTS.md cannot stack on top, and
  # auth stays in the shared file store.
  home = "#{codex_homes}/#{profile}"
  directory home do
    owner node[:setup][:user]
    group node[:setup][:group]
    mode "700"
  end

  file "#{home}/AGENTS.md" do
    content contents[profile]["codex"]
    owner node[:setup][:user]
    group node[:setup][:group]
    mode "644"
  end

  file "#{home}/config.toml" do
    content "project_doc_max_bytes = 0\ncli_auth_credentials_store = \"file\"\n"
    owner node[:setup][:user]
    group node[:setup][:group]
    mode "600"
  end

  # No force: without -f, ln -s does not replace an existing auth.json.
  link "#{home}/auth.json" do
    to "#{node[:setup][:home]}/.codex/auth.json"
  end
end
