# frozen_string_literal: true
#
# pm2: the OS-independent install half — Node.js plus the pm2 npm package via
# mise. Included FIRST by darwin.rb and linux.rb, before their per-OS startup
# wiring, so resource order matches the pre-split default.rb exactly
# (nodejs → mise_tool → startup → profile).

# Ensure Node.js is installed via mise
include_cookbook "nodejs"

mise_tool "pm2" do
  backend "npm"
end
