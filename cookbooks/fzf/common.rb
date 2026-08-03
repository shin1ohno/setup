# frozen_string_literal: true
#
# fzf, OS-independent half: the fzf-git.sh checkout and the two profile entries
# that do not depend on how fzf itself was installed. Included FIRST by
# darwin.rb and linux.rb, which then add the package plus their own "fzf"
# profile entry (different install prefixes, different shell wiring -- hence
# the per-OS split).
#
# The two add_profile entries here sit before the per-OS one rather than after
# it as in the pre-split recipe. That is inert: add_profile writes one
# <priority>-<name>.sh file per entry, so declaration order changes nothing
# about what lands in profile.d.

fzf_git_uri = "https://github.com/junegunn/fzf-git.sh.git"
fzf_git_dir = "#{node[:setup][:root]}/fzf-git.sh"

# Third-party, public, read-only clone -- HTTPS needs no auth at all and
# works on every host, unlike an SSH URL (which fails outright on hosts with
# no SSH private key, e.g. GCE OS Login boxes; confirmed live).
git_clone "fzf-git.sh" do
  cwd node[:setup][:root]
  uri fzf_git_uri
end

# git_clone's not_if is path-existence only (functions/default.rb), so it never
# re-clones -- a host that cloned before the HTTPS switch keeps its git@ remote
# forever, and the pull below then runs over exactly the SSH transport that
# switch existed to stop depending on. Repoint an existing SSH remote once; a
# no-op on a fresh HTTPS clone. `git -C` in the guard because mitamae does not
# promise the resource's cwd to only_if.
execute "repoint fzf-git.sh remote to HTTPS" do
  command "git remote set-url origin #{fzf_git_uri}"
  cwd fzf_git_dir
  only_if "test -d #{fzf_git_dir}/.git && " \
          "git -C #{fzf_git_dir} remote get-url origin | grep -q '^git@'"
end

# GIT_SSH_COMMAND is kept even though the remote is now HTTPS (git ignores it
# there): it is what stops a remote this run has NOT repointed -- the repoint
# guard skipped, or a checkout without a .git dir -- from hanging on a
# passphrase or host-key prompt. `|| true` hides such a hang rather than
# preventing it, so the timeout is the real guard. Same string as
# cookbooks/fzf-tab, cookbooks/dot-config-nvim and cookbooks/dot-tmux.
execute "update fzf-git.sh" do
  command "GIT_SSH_COMMAND='ssh -o BatchMode=yes -o ConnectTimeout=5' git pull || true"
  cwd fzf_git_dir
  only_if "test -d #{fzf_git_dir}"
end

add_profile "fzf-advanced" do
  bash_content <<~'EOS'
  # https://github.com/junegunn/fzf/wiki/Examples
  tm() {
    [[ -n "$TMUX" ]] && change="switch-client" || change="attach-session"
    if [ $1 ]; then
      tmux $change -t "$1" 2>/dev/null || (tmux new-session -d -s $1 && tmux $change -t "$1"); return
    fi
    session=$(tmux list-sessions -F "#{session_name}" 2>/dev/null | fzf --exit-0) &&  tmux $change -t "$session" || tmux
  }
  EOS
end

add_profile "fzf-git" do
  bash_content <<~EOS
    # Defer fzf-git widget registration to post-prompt; same fallback as
    # the fzf core profile entry.
    if (( $+functions[zsh-defer] )); then
      zsh-defer source "#{node[:setup][:root]}/fzf-git.sh/fzf-git.sh"
    else
      source "#{node[:setup][:root]}/fzf-git.sh/fzf-git.sh"
    fi
  EOS
end
