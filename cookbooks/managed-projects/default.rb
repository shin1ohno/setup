# frozen_string_literal: true

directory node[:managed_projects][:root] do
  owner node[:managed_projects][:user]
  group node[:managed_projects][:group]
  mode "755"
  action :create
end

# At least one repo in the list is typically private — block until SSH-to-
# GitHub works so the first git_clone doesn't hard-fail. Skipped on re-runs
# where every repo is already present locally.
needs_clone = node[:managed_projects][:repos].any? do |repo|
  !File.exist?(File.join(node[:managed_projects][:root], repo[:name]))
end

if needs_clone
  await_external_auth(
    tool_name: "GitHub SSH access (managed-projects clones)",
    check_command: "ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -T git@github.com 2>&1 | grep -q 'successfully authenticated'",
    instructions: "Add ~/.ssh/<host>_ed25519.pub to https://github.com/settings/keys, then press Enter.",
  )
end

node[:managed_projects][:repos].each do |repo|
  git_clone repo[:name] do
    uri repo[:uri]
    cwd node[:managed_projects][:root]
  end
end
