# Ensure mise is installed
include_cookbook "mise"

# Install fd using mise
execute "mise install fd@latest" do
  not_if "$HOME/.local/bin/mise list fd | grep -q 'fd'"
end

# Set fd as globally available
execute "mise use --global fd@latest" do
  not_if "$HOME/.local/bin/mise list fd | grep -q '\\* '"
end

