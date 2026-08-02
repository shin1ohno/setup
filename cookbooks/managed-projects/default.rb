# frozen_string_literal: true

# Depends on ssh-keys: the private device key must be in place before any
# git@github.com clone can succeed. ssh-keys pauses for AWS auth itself.
# The matching public key is registered to github.com/shin1ohno via
# home-monitor's Terraform `github_user_ssh_key.device[*]`.
include_cookbook "ssh-keys"

directory node[:managed_projects][:root] do
  owner node[:managed_projects][:user]
  group node[:managed_projects][:group]
  mode "755"
  action :create
end

# Probe each transport ONCE, then skip the repos whose transport this host
# cannot authenticate. mitamae has no ignore_failure, so the first clone that
# fails aborts the rest of this cookbook AND everything after it in the entry
# recipe — and because roles/manage runs before roles/network and roles/server,
# one unreachable repo silently skipped 21 downstream cookbooks. Confirmed live
# on a keyless cloud box: the SECOND of 14 entries is a codecommit:// URI, so it
# was the abort point, ahead of every git@github.com entry.
#
# Capability probes, not a host allow-list: a host that HAS the credential keeps
# cloning exactly as before, so this cannot regress the physical fleet.
# Evaluated at compile time on purpose — one probe per transport for the whole
# loop rather than one per repo — and both are read-only.
ssh_auth_ok = run_command(
  "ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new git@github.com 2>&1",
  error: false,
).stdout.include?("successfully authenticated")

# `== 0`, not `.zero?` — mitamae runs on mruby, which has no Integer#zero?.
# `ruby -c` (CRuby) accepts it and CI's real dry-run is what catches it.
# Matches the idiom already used at cookbooks/git/default.rb:28.
aws_auth_ok = run_command("aws sts get-caller-identity >/dev/null 2>&1", error: false).exit_status == 0

node[:managed_projects][:repos].each do |repo|
  # Repair a stored remote that drifted from the registry. `git_clone` below
  # fires only when the directory is ABSENT, so a repo something else cloned
  # first keeps that URL forever -- on the sh1-cloud GCE box the instance
  # startup-script clones `setup` over HTTPS before the first mitamae apply
  # ever runs, and the box then pushed over a URL the registry never chose.
  # repositories.json owns the transport, so re-point origin at it.
  #
  # Deliberately ABOVE the reachability gate: set-url is a local config write
  # that needs no credential, and the guards no-op when the clone is absent,
  # so a repo this host cannot authenticate still gets a correct remote for
  # the host that eventually can.
  #
  # The comparison reads `config --get remote.origin.url`, NOT `git remote
  # get-url`: the latter APPLIES url.*.insteadOf, so a stored
  # `https://github.com/shin1ohno/setup.git` reads back as
  # `git@github.com:shin1ohno/setup.git` and the drift is invisible. That is
  # exactly what hid this bug on sh1-cloud until the raw config was read.
  repo_path = "#{node[:managed_projects][:root]}/#{repo[:name]}"
  execute "repoint #{repo[:name]} origin at the registry URI" do
    command "git -C '#{repo_path}' remote set-url origin '#{repo[:uri]}'"
    user node[:managed_projects][:user]
    # Also serves as the "is a git repo with an origin" probe -- a directory
    # without one exits non-zero here rather than failing the set-url.
    only_if "git -C '#{repo_path}' remote get-url origin >/dev/null 2>&1"
    not_if "test \"$(git -C '#{repo_path}' config --get remote.origin.url 2>/dev/null)\" = '#{repo[:uri]}'"
  end

  # `codecommit::` is the scheme git-remote-codecommit registers; everything
  # else in the registry is a github URI. Anonymous HTTPS needs no credential
  # at all, so only the ssh form is gated on the key.
  transport =
    if repo[:uri].to_s.start_with?("codecommit::") then :aws
    elsif repo[:uri].to_s.start_with?("git@") then :ssh
    else :https
    end

  reachable =
    case transport
    when :aws then aws_auth_ok
    when :ssh then ssh_auth_ok
    else true
    end

  unless reachable
    MItamae.logger.warn(
      "managed-projects: skipping #{repo[:name]} — no #{transport == :aws ? "AWS" : "SSH"} " \
      "credential on this host for #{repo[:uri]}. Provision one (ssh-keys / an AWS profile) " \
      "and re-apply to clone it.",
    )
    next
  end

  git_clone repo[:name] do
    uri repo[:uri]
    cwd node[:managed_projects][:root]
  end
end
