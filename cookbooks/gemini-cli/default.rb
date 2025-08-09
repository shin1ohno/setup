# frozen_string_literal: true

# Google Gemini CLI
# https://github.com/google-gemini/gemini-cli

# Ensure Node.js is installed via mise
include_cookbook "nodejs"

# Install Gemini CLI globally via npm
execute "export PATH=$HOME/.local/share/mise/shims:$PATH && npm install -g @google/gemini-cli" do
  user node[:setup][:user]
  not_if "which gemini"
end

