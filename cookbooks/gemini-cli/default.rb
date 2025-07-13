# frozen_string_literal: true

# Google Gemini CLI
# https://github.com/google-gemini/gemini-cli

# Ensure Node.js is installed via volta
include_cookbook "nodejs"

# Install Gemini CLI globally via npm
execute "$HOME/.volta/bin/npm install -g @google/gemini-cli" do
  not_if "test -f $HOME/.volta/bin/gemini"
end

