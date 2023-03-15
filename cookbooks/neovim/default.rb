# frozen_string_literal: true

if node[:platform] == "ubuntu"
  execute "snap install nvim --edge --classic && apt-get install python3-pynvim && apt-get remove neovim" do
    not_if "snap list | grep -q neovim"
  end
else
  package "neovim"
end
