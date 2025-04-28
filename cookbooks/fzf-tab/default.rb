# frozen_string_literal: true

git_clone "fzf-tab" do
  cwd node[:setup][:root]
  uri "https://github.com/Aloxaf/fzf-tab.git"
end

execute "git pull" do
  cwd "#{node[:setup][:root]}/fzf-tab"
end

add_profile "fzf-tab" do
  bash_content <<~EOS
    source "#{node[:setup][:root]}/fzf-tab/fzf-tab.plugin.zsh"
    zstyle ':completion:*:descriptions' format '[%d]'
    zstyle ':completion:*' list-colors ${(s.:.)LS_COLORS}
    zstyle ':fzf-tab:complete:cd:*' fzf-preview 'ls -la $realpath'
  EOS
end
