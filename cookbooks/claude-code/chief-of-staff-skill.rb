# frozen_string_literal: true

%w(.agents .agents/skills .agents/skills/chief-of-staff .agents/skills/chief-of-staff/agents .agents/skills/chief-of-staff/references .agents/skills/chief-of-staff/scripts).each do |dir_name|
  directory "#{node[:setup][:home]}/#{dir_name}" do
    owner node[:setup][:user]
    group node[:setup][:group]
    mode "755"
  end
end

%w(SKILL.md agents/openai.yaml references/dispatch.md references/hc-route.md references/linear.md scripts/tasks.py).each do |file_name|
  remote_file "#{node[:setup][:home]}/.agents/skills/chief-of-staff/#{file_name}" do
    source "files/skills/chief-of-staff/#{file_name}"
    owner node[:setup][:user]
    group node[:setup][:group]
    mode "644"
  end
end

agents_skill_link "chief-of-staff"
