# frozen_string_literal: true

# Slidev - Presentation slides for developers
# https://sli.dev/
# Requires Node.js >= 20.12.0

include_cookbook "nodejs"

mise_tool "@slidev/cli" do
  backend "npm"
end
