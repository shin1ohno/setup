# frozen_string_literal: true

%w(.agents .agents/skills .agents/skills/chief-of-staff .agents/skills/chief-of-staff/agents .agents/skills/chief-of-staff/references .agents/skills/chief-of-staff/scripts).each do |dir_name|
  directory "#{node[:setup][:home]}/#{dir_name}" do
    owner node[:setup][:user]
    group node[:setup][:group]
    mode "755"
  end
end

# evals/ (the `claude plugin eval` suite and its fixtures) is repo-only and
# intentionally excluded from this deploy list.
%w(SKILL.md agents/openai.yaml references/dispatch.md references/hc-route.md references/linear.md references/report.md references/supervision-handoff.md scripts/board.rb scripts/inbox.py scripts/prune.py scripts/takeover.py scripts/tasks.py).each do |file_name|
  remote_file "#{node[:setup][:home]}/.agents/skills/chief-of-staff/#{file_name}" do
    source "files/skills/chief-of-staff/#{file_name}"
    owner node[:setup][:user]
    group node[:setup][:group]
    mode "644"
  end
end

agents_skill_link "chief-of-staff"

# scripts/board.rb (the Agent Board) runs under the `ruby` on PATH, the rbenv
# global version, and needs WEBrick, which left the default gems in Ruby 3.0.
# roles/programming sets node[:rbenv] before roles/llm reaches this recipe;
# the cloud entry (claude-cloud.rb) has no rbenv and distributes files only.
if node[:rbenv] && node[:rbenv][:root]
  rbenv_root = node[:rbenv][:root]
  rbenv_bin = "#{rbenv_root}/bin/rbenv"
  execute "gem install webrick (rbenv global, chief-of-staff board)" do
    command "env RBENV_ROOT=#{rbenv_root} #{rbenv_bin} exec gem install --no-document webrick"
    user node[:setup][:user]
    only_if "test -x #{rbenv_bin}"
    not_if "env RBENV_ROOT=#{rbenv_root} #{rbenv_bin} exec ruby -e 'require \"webrick\"'"
  end
end
