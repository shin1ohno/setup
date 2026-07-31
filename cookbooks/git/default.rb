# frozen_string_literal: true

if node[:platform] == "darwin"
  package "git"
  package "git-lfs"
  package "git-filter-repo"

  include_cookbook "mise"
  mise_tool "gh"

  package "gh" do
    action :remove
    only_if { brew_formula?("gh") }
  end

  # git-ai-commit (takai/tap) removed — drop the formula and the tap.
  package "git-ai-commit" do
    action :remove
    only_if { brew_formula?("git-ai-commit") }
  end
  execute "brew untap takai/tap" do
    only_if { brew_tap?("takai/tap") }
  end
else
  %w(git git-lfs gh).each do |pkg|
    package pkg do
      user node[:setup][:system_user]
      not_if { run_command("dpkg-query -W -f='${Status}' #{pkg} 2>/dev/null | grep -q 'install ok installed'", error: false).exit_status == 0 }
    end
  end
end

remote_file "#{node[:setup][:home]}/.gitconfig" do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
  source "files/gitconfig"
end

# SSH-for-github preference: only added when this host actually has an SSH
# private key on disk. Hosts provisioned without one (e.g. GCE OS Login boxes
# with no static SSH keys, by design) must not get this rewrite -- it
# silently redirects EVERY https://github.com/... git/gh operation to an SSH
# transport that can never authenticate, breaking not just this cookbook's
# own use but any later cookbook/tool that shells out to plain git against
# github.com (confirmed live: broke both `gh repo clone` and fzf's
# fzf-git.sh clone on a fresh keyless box).
#
# Detection is filename-convention-agnostic (reads each ~/.ssh/* candidate's
# header instead of assuming id_rsa/id_ed25519) because ssh-keys cookbook
# names its key file per-device, not by the OpenSSH default names. ssh-keys
# runs AFTER this cookbook in roles/foundation, so a host's very first-ever
# bootstrap sees "no key yet" here and only gets this preference from its
# SECOND apply onward -- acceptable, matches this codebase's existing
# accepted compile-order tradeoffs elsewhere (see ~/.claude/rules/ruby.md
# "Mitamae evaluation model").
ssh_dir = "#{node[:setup][:home]}/.ssh"
has_ssh_private_key = Dir.exist?(ssh_dir) && Dir.glob("#{ssh_dir}/*").any? { |f|
  next false if File.directory?(f) || f.end_with?(".pub") || %w(known_hosts config authorized_keys).include?(File.basename(f))
  File.read(f, 100).to_s.include?("PRIVATE KEY")
}

execute 'git config --global url."git@github.com:".insteadOf https://github.com/' do
  only_if { has_ssh_private_key }
  not_if 'git config --global --get url."git@github.com:".insteadOf 2>/dev/null | grep -qx https://github.com/'
end
