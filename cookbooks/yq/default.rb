# frozen_string_literal: true

include_cookbook "mise"

mise_tool "yq"

if node[:platform] == "darwin"
  package "yq" do
    action :remove
    only_if { brew_formula?("yq") }
  end
end
