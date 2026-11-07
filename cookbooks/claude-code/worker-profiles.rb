# frozen_string_literal: true

# Opt-in only: no default include, login, credential links or permission changes.
%w(.agents .agents/profiles .claude .claude/agents).each do |name|
  directory "#{node[:setup][:home]}/#{name}" do
    owner node[:setup][:user]
    group node[:setup][:group]
    mode "755"
  end
end

%w(common dev cos writing).each do |profile|
  %w(claude codex).each do |harness|
    layers = profile == "common" ? %w(common) : ["common", profile]
    content = layers.map do |layer|
      File.read(File.join(File.dirname(__FILE__), "files/instructions/generated/#{layer}.#{harness}.md"))
    end.join("\n")
    # Check the complete artifact bytes before declaring any placement.
    raise "Codex #{profile} profile exceeds 32768 bytes" if harness == "codex" && content.bytesize > 32768
    file "#{node[:setup][:home]}/.agents/profiles/#{profile}.#{harness}.md" do
      content content
      owner node[:setup][:user]
      group node[:setup][:group]
      mode "644"
    end
    next unless harness == "claude"

    file "#{node[:setup][:home]}/.claude/agents/profile-#{profile}.md" do
      content "---\nname: profile-#{profile}\ndescription: Explicit #{profile} worker profile\nomitClaudeMd: true\n---\n\n#{content}"
      owner node[:setup][:user]
      group node[:setup][:group]
      mode "644"
    end
  end
end
