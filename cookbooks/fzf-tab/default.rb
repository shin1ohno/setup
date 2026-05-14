# frozen_string_literal: true

git_clone "fzf-tab" do
  cwd node[:setup][:root]
  uri "https://github.com/Aloxaf/fzf-tab.git"
end

execute "update fzf-tab" do
  command "GIT_SSH_COMMAND='ssh -o BatchMode=yes -o ConnectTimeout=5' git pull || true"
  cwd "#{node[:setup][:root]}/fzf-tab"
  only_if "test -d #{node[:setup][:root]}/fzf-tab"
end

add_profile "fzf-tab" do
  bash_content <<~EOS
    # zstyles can be set before the plugin loads (they're read at use time).
    zstyle ':completion:*:descriptions' format '[%d]'
    zstyle ':completion:*' list-colors ${(s.:.)LS_COLORS}
    zstyle ':fzf-tab:complete:cd:*' fzf-preview 'ls -la $realpath'
    # Defer the plugin source itself — first TAB may briefly miss the
    # fzf-tab widget, normal completion fallback handles that case.
    if (( $+functions[zsh-defer] )); then
      zsh-defer source "#{node[:setup][:root]}/fzf-tab/fzf-tab.plugin.zsh"
    else
      source "#{node[:setup][:root]}/fzf-tab/fzf-tab.plugin.zsh"
    fi
  EOS
end
