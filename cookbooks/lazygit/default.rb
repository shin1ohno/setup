# # frozen_string_literal: true

if node[:platform] == "darwin"
  package "lazygit"
else
  execute "go install github.com/jesseduffield/lazygit@latest" do
    not_if "which lazygit"
  end
end

