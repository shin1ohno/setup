# frozen_string_literal: true
if node[:platform] == "darwin"
  package "ripgrep"
else
  package "ripgrep" do
    user "root"
  end
end
