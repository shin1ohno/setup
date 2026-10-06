# frozen_string_literal: true
#
# session-search (macOS): the shared client install (common.rb) plus C5, the
# sweep timer, as a launchd user agent with StartInterval=900 (§6.4):
#   ~/Library/LaunchAgents/be.ohno.ccs-sweep.plist   runs `ccs ingest --sweep --quiet`
#
# ccs writes its own log (~/.claude/session-search.log); the agent's stderr
# goes to the same file so an interpreter-level crash is not lost.
#
# Verify after apply: `launchctl print gui/$(id -u)/be.ohno.ccs-sweep` shows
# `run interval = 900 seconds`.

include_recipe "common"

ss = node[:session_search]
return if ss[:skip]

ss_user = ss[:user]
home = ss[:home]
ss_group = ss[:group]
gate = ss[:redactor_gate]
agents_dir = "#{home}/Library/LaunchAgents"
plist = "#{agents_dir}/be.ohno.ccs-sweep.plist"

directory agents_dir do
  owner ss_user
  group ss_group
  mode "755"
  only_if gate
end

template plist do
  source "files/launchd/be.ohno.ccs-sweep.plist.erb"
  variables(launcher: ss[:launcher], log_path: "#{home}/.claude/session-search.log")
  owner ss_user
  group ss_group
  mode "644"
  only_if gate
  notifies :run, "execute[reload ccs-sweep agent]"
end

# bootout + bootstrap so a changed plist replaces the loaded definition.
load_agent = "bash -c 'launchctl bootout gui/$(id -u)/be.ohno.ccs-sweep 2>/dev/null || true; " \
             "launchctl bootstrap gui/$(id -u) #{plist}'"

execute "load ccs-sweep agent" do
  command load_agent
  user ss_user
  only_if gate
  not_if "launchctl print gui/$(id -u #{ss_user})/be.ohno.ccs-sweep >/dev/null 2>&1"
end

execute "reload ccs-sweep agent" do
  command load_agent
  user ss_user
  action :nothing
  only_if gate
end
