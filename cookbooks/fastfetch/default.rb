include_cookbook "mise"

mise_tool "fastfetch"

if node[:platform] == "darwin"
  package "neofetch" do
    action :remove
    only_if { brew_formula?("neofetch") }
  end
end
