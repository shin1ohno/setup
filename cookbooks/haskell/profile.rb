# frozen_string_literal: true
#
# haskell: the OS-independent profile half — sourcing ghcup's own env file.
# Included LAST by darwin.rb and linux.rb (see ghcup.rb for the other shared
# half).
add_profile "ghcup" do
  bash_content <<'EOM'
[ -f "${HOME}/.ghcup/env" ] && . "${HOME}/.ghcup/env" # ghcup-env
EOM
end
