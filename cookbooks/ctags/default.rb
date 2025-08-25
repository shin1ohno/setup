# frozen_string_literal: true

case node[:platform]
when "ubuntu"
  package "universal-ctags" do
    user node[:setup][:install_user]
  end
when "darwin"
  package "ctags"
else
  package "ctags" do
    user node[:setup][:install_user]
  end
end
