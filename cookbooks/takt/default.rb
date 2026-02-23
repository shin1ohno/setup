# frozen_string_literal: true

# Ensure mise and Node.js are available
include_cookbook "mise"
include_cookbook "nodejs"

mise_tool "takt" do
  backend "npm"
end
