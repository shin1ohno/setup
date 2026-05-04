# frozen_string_literal: true

# git-remote-codecommit: AWS CodeCommit URL helper for git.
#
# Why: CodeCommit HTTPS URLs require either a stored AWS git credential
# helper or static IAM HTTPS credentials, both of which are awkward to
# manage. git-remote-codecommit lets git speak the short
# `codecommit::<region>://<profile>@<repo>` URL form using the standard
# AWS profile chain — no extra credential plumbing.
#
# Install path:
#   1. `pip install` via pyenv (mirrors cookbooks/speedtest-cli pattern).
#      `botocore[crt]` is required so botocore can read `aws login`-style
#      session credentials (login_session in ~/.aws/config); without it
#      the clone fails at credential resolution with
#      MissingDependencyException.
#   2. Symlink the pyenv shim into /usr/local/bin so `git` (which spawns
#      via sudo on remote-helper invocation) can find git-remote-codecommit
#      on the default sudoers secure_path. Without the symlink, mitamae's
#      git_clone fires through `sudo -H -u <user>` with PATH stripped to
#      /usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin and
#      git emits "git: 'remote-codecommit' is not a git command".
include_cookbook "python"

execute "install git-remote-codecommit" do
  command "$HOME/.pyenv/shims/pip install git-remote-codecommit 'botocore[crt]'"
  user node[:setup][:user]
  not_if "$HOME/.pyenv/shims/pip list 2>/dev/null | grep -qi '^git-remote-codecommit '"
end

execute "symlink git-remote-codecommit into /usr/local/bin" do
  command "ln -sf #{node[:setup][:home]}/.pyenv/shims/git-remote-codecommit /usr/local/bin/git-remote-codecommit"
  user node[:setup][:system_user]
  not_if "test -L /usr/local/bin/git-remote-codecommit && " \
         "test \"$(readlink /usr/local/bin/git-remote-codecommit)\" = " \
         "\"#{node[:setup][:home]}/.pyenv/shims/git-remote-codecommit\""
end
