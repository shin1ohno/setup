# frozen_string_literal: true

# Google Gemini CLI
# https://github.com/google-gemini/gemini-cli

# Ensure Node.js is installed via mise
include_cookbook "nodejs"

mise_tool "@google/gemini-cli" do
  backend "npm"
end
