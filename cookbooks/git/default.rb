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

# The remote_file above renders ~/.gitconfig from a static source, so it DELETES
# anything another tool wrote there -- including the URL-scoped credential
# helper `gh auth setup-git` installs (`credential.https://github.com.helper =
# !gh auth git-credential`). On a host whose only authenticated path to github
# is that HTTPS token (no SSH key -- GCE OS Login boxes, by design), every
# apply silently revoked git's ability to authenticate. Confirmed live via
# `mitamae --dry-run`, which diffed the two [credential] blocks as removals.
# `gh repo clone` survived it because gh passes its own helper inline with -c,
# but a plain `git pull` against a private repo did not.
#
# only_if on `gh auth status` is load-bearing: bare `gh auth setup-git` exits
# non-zero when no host is authenticated ("If there is no authenticated hosts
# the command fails with an error"), and mitamae has no ignore_failure -- so an
# unguarded call would abort the whole run on any un-authenticated host,
# including the first-ever apply on a fresh Mac where this same cookbook
# installs gh moments earlier.
execute "gh auth setup-git" do
  user node[:setup][:user]
  only_if "gh auth status >/dev/null 2>&1"
  not_if "git config --global --get-urlmatch credential.helper https://github.com/ | grep -q ."
end

# files/gitconfig sets `commit.gpgsign = true` unconditionally, so a host that
# lacks the secret half of user.signingkey cannot commit AT ALL -- gpg reports
# `skipped "<id>": No secret key` and git aborts with `fatal: failed to write
# commit object`. That is fatal for a box whose purpose is running coding
# agents.
#
# Scoped to the sh1-cloud profile rather than "any host missing the key" on
# purpose: where the master secret is kept offline (`sec#`) or on hardware, a
# temporarily-unavailable key SHOULD fail loudly instead of silently producing
# unsigned commits. Self-healing -- the remote_file above restores
# `gpgsign = true` every apply, so once the key is present the guard below
# stops firing and signing resumes with no further action.
#
# The guard reads the CONFIGURED key rather than hardcoding an id (one source
# of truth: files/gitconfig). Shell, not a Ruby Proc, so it evaluates at
# converge time -- after the remote_file has written signingkey. sh operator
# precedence is left-to-right, so this reads: skip when (a key is configured
# AND git can actually sign with it) OR (signing is already disabled).
#
# It probes SIGNING CAPABILITY, not key presence. `gpg --list-secret-keys`
# succeeds for a key that gpg cannot actually use, and on a headless box that
# is the normal case: a passphrase-protected key makes gpg try to launch
# pinentry, which fails with `signing failed: Inappropriate ioctl for device`.
# Confirmed live -- presence-based, this guard enabled signing on a box where
# every commit then died, which is worse than the state it was written to fix.
# `-bsau <key>` is git's own invocation shape (see git's sign_buffer), so the
# probe exercises the same path git will, rather than a proxy for it.
execute "git config --global commit.gpgsign false" do
  user node[:setup][:user]
  only_if { node[:profile][:label] == "sh1-cloud" }
  not_if 'k=$(git config --global --get user.signingkey) && [ -n "$k" ] && ' \
         'printf x | gpg --batch --yes -bsau "$k" -o /dev/null >/dev/null 2>&1 || ' \
         'git config --global --get commit.gpgsign | grep -qx false'
end

# SSH-for-github preference: only added when this host actually has an SSH
# private key on disk. Hosts provisioned without one (e.g. GCE OS Login boxes
# with no static SSH keys, by design) must not get this rewrite -- it
# silently redirects EVERY https://github.com/... git/gh operation to an SSH
# transport that can never authenticate, breaking not just this cookbook's
# own use but any later cookbook/tool that shells out to plain git against
# github.com (confirmed live: broke `gh repo clone kouzoh/zp-SHIN` on a fresh
# keyless box -- gh itself correctly chose HTTPS and injected its own
# credential helper, and git's rewrite happened downstream of gh, invisible to
# it). Not the fzf-git.sh clone: that URI was the literal `git@github.com:`
# form at the time, which no `https://github.com/` prefix rule can match, so
# it failed on the missing key alone and was fixed separately in cookbooks/fzf.
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

# Scoped to the personal namespace, NOT all of github.com. A blanket
# `https://github.com/ -> git@github.com:` rewrite also captures ORG urls that
# the personal key cannot authenticate to. On a host whose only path to a
# private org repo is an HTTPS token (gh's credential helper), the blanket form
# silently breaks that clone the moment any SSH key lands in ~/.ssh -- and a
# `Match host github.com user git` stanza in ssh_config does NOT protect it,
# because that only scopes `org-<id>@github.com` connections, a form nothing
# produces unless an org-cert cookbook is deployed on the host.
# git resolves insteadOf by LONGEST matching prefix, so scoping the rule to
# `https://github.com/shin1ohno/` leaves every other owner on HTTPS.
execute 'git config --global url."git@github.com:shin1ohno/".insteadOf https://github.com/shin1ohno/' do
  only_if { has_ssh_private_key }
  not_if 'git config --global --get url."git@github.com:shin1ohno/".insteadOf 2>/dev/null | grep -qx https://github.com/shin1ohno/'
end

# Retire the blanket rewrite this cookbook used to install. Without this, a
# host that applied an earlier revision keeps BOTH rules, and the blanket one
# still wins for org urls -- the narrowing above would be cosmetic. Subsection
# names are matched literally, so this cannot touch the shin1ohno/-scoped key
# set just above. Same unset the repo's own CI already performs
# (.github/workflows/test-setup.yml).
execute 'git config --global --unset-all url."git@github.com:".insteadOf' do
  only_if 'git config --global --get url."git@github.com:".insteadOf >/dev/null 2>&1'
end
