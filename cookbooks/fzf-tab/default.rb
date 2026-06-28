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
  # priority 15: load AFTER compinit (10-dot-zsh.sh) but BEFORE sheldon
  # (20-sheldon.sh), which sources zsh-autosuggestions + fast-syntax-highlighting.
  # fzf-tab MUST load before those widget-wrapping plugins — otherwise the
  # zsh-autosuggestions ghost text renders garbled/doubled right after an
  # fzf-tab completion (perceived as the completed token "doubling" at the
  # cursor). This is the documented fzf-tab requirement: "load after compinit,
  # before plugins that wrap widgets". At priority 15 zsh-defer is not loaded
  # yet (sheldon at 20 provides it), so the source below takes the synchronous
  # `else` branch — which is what we want: fzf-tab ready before autosuggestions,
  # no first-TAB miss. Do NOT move this back to the default priority 50.
  priority 15
  bash_content <<~EOS
    # zstyles can be set before the plugin loads (they're read at use time).
    zstyle ':completion:*:descriptions' format '[%d]'
    zstyle ':completion:*' list-colors ${(s.:.)LS_COLORS}
    zstyle ':fzf-tab:complete:cd:*' fzf-preview 'ls -la $realpath'
    # Source fzf-tab BEFORE zsh-autosuggestions (see priority note above).
    # At priority 15 zsh-defer isn't defined yet, so this takes the `else`
    # (synchronous) branch; the conditional is kept as a safety net.
    if (( $+functions[zsh-defer] )); then
      zsh-defer source "#{node[:setup][:root]}/fzf-tab/fzf-tab.plugin.zsh"
    else
      source "#{node[:setup][:root]}/fzf-tab/fzf-tab.plugin.zsh"
    fi
  EOS
end
