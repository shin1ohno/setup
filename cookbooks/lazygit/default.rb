# # frozen_string_literal: true

if node[:platform] == "darwin"
  package "lazygit"
else
  execute "go install github.com/jesseduffield/lazygit@latest"
end

