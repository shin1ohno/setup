include_cookbook "mise"

mise_tool "fd"

if node[:platform] == "darwin"
  package "fd" do
    action :remove
    only_if { brew_formula?("fd") }
  end
end
