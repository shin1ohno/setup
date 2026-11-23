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
%w(SKILL.md agents/openai.yaml references/dispatch.md references/hc-route.md references/linear.md references/supervision-handoff.md scripts/prune.py scripts/takeover.py scripts/tasks.py).each do |file_name|
  remote_file "#{node[:setup][:home]}/.agents/skills/chief-of-staff/#{file_name}" do
    source "files/skills/chief-of-staff/#{file_name}"
    owner node[:setup][:user]
    group node[:setup][:group]
    mode "644"
  end
end

agents_skill_link "chief-of-staff"
