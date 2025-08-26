# frozen_string_literal: true

remote_file "#{node[:setup][:root]}/mise-install.sh" do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
  source "files/install.sh"
end

execute "sh #{node[:setup][:root]}/mise-install.sh" do
  not_if "which mise"
end

execute "$HOME/.local/bin/mise self-update" do
  only_if { File.exists? "#{ENV["HOME"]}/.local/bin/mise" }
end

# Install usage tool for mise completions
execute "$HOME/.local/bin/mise use -g usage" do
  user node[:setup][:user]
  not_if "$HOME/.local/bin/mise list usage | grep -q 'usage'"
end

# Generate shell completions
directory "#{ENV['HOME']}/.local/share/bash-completion/completions" do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
end

execute "$HOME/.local/bin/mise completion bash --include-bash-completion-lib > #{ENV['HOME']}/.local/share/bash-completion/completions/mise" do
  user node[:setup][:user]
  not_if "test -f #{ENV['HOME']}/.local/share/bash-completion/completions/mise"
end

# Create zsh completions directory if it doesn't exist
directory "#{ENV['HOME']}/.local/share/zsh/site-functions" do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
end

execute "$HOME/.local/bin/mise completion zsh > #{ENV['HOME']}/.local/share/zsh/site-functions/_mise" do
  user node[:setup][:user]
  not_if "test -f #{ENV['HOME']}/.local/share/zsh/site-functions/_mise"
end

directory "#{ENV['HOME']}/.config/fish/completions" do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
  only_if "which fish"
end

execute "$HOME/.local/bin/mise completion fish > #{ENV['HOME']}/.config/fish/completions/mise.fish" do
  user node[:setup][:user]
  not_if "test -f #{ENV['HOME']}/.config/fish/completions/mise.fish"
  only_if "which fish"
end

add_profile "mise" do
  bash_content <<~EOS
    # mise-en-place tool version manager
    if [ -f "$HOME/.local/bin/mise" ]; then
      # Detect shell and activate accordingly
      if [ -n "$BASH_VERSION" ]; then
        eval "$($HOME/.local/bin/mise activate bash)"
      elif [ -n "$ZSH_VERSION" ]; then
        eval "$($HOME/.local/bin/mise activate zsh)"
      fi
    fi
  EOS
  fish_content <<~FISH
    # mise-en-place tool version manager
    if test -f "$HOME/.local/bin/mise"
      eval ($HOME/.local/bin/mise activate fish)
    end
  FISH
end
