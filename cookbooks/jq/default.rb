include_cookbook "mise"

mise_tool "jq"

if node[:platform] == "darwin"
  package "jq" do
    action :remove
    only_if { brew_formula?("jq") }
  end
end
