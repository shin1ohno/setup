# frozen_string_literal: true

# Ensure mise and Node.js are available
include_cookbook "mise"
include_cookbook "nodejs"

# Install takt globally using mise npm backend
execute "install takt via mise" do
  user node[:setup][:user]
  command "$HOME/.local/bin/mise use --global npm:takt@latest"
  not_if "$HOME/.local/bin/mise list | grep -q 'npm:takt'"
end
