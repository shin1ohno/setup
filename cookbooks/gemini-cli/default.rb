# frozen_string_literal: true

# Google Gemini CLI
# https://github.com/google-gemini/gemini-cli

# Ensure Node.js is installed via mise
include_cookbook "nodejs"

# Install Gemini CLI globally via mise
execute "install gemini-cli via mise" do
  user node[:setup][:user]
  command "$HOME/.local/bin/mise use --global npm:@google/gemini-cli@latest"
  not_if "$HOME/.local/bin/mise list | grep -q 'npm:@google/gemini-cli'"
end
