# frozen_string_literal: true

case node[:platform]
when "ubuntu"
  package "universal-ctags" do
    user node[:setup][:system_user]
  end
when "darwin"
  include_cookbook "mise"
  mise_tool "universal-ctags/ctags" do
    backend "ubi"
  end
  package "ctags" do
    action :remove
    only_if { brew_formula?("ctags") }
  end
  package "universal-ctags" do
    action :remove
    only_if { brew_formula?("universal-ctags") }
  end
else
  package "ctags" do
    user node[:setup][:system_user]
  end
end
