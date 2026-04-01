# frozen_string_literal: true

# Google Workspace CLI (gws)
# https://github.com/googleworkspace/cli

include_cookbook "nodejs"

mise_tool "@googleworkspace/cli" do
  backend "npm"
end
