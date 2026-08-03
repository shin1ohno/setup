# frozen_string_literal: true
#
# golang: the OS-independent half — the mise-managed Go toolchain and the
# GOPATH/PATH profile fragment. Included LAST by darwin.rb and linux.rb, after
# their `include_cookbook "mise"` (and, on linux, the distro build deps), so
# resource order matches the pre-split default.rb exactly.

mise_tool "go" do
  versions node[:go][:versions]
end

# Add Go environment setup
add_profile "golang" do
  bash_content <<~BASH
    # Go managed by mise
    export PATH="$HOME/.local/share/mise/shims:$PATH"
    export GOPATH="$HOME/go"
    export PATH="$GOPATH/bin:$PATH"
  BASH
  priority 70
end
