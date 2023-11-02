# frozen_string_literal: true

if node[:platform] == "ubuntu"
  execute "sudo snap install nvim --edge --classic && sudo apt-get install python3-pynvim" do
    not_if "which nvim"
  end
else
  package "neovim"
end
