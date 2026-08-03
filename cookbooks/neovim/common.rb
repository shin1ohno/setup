# frozen_string_literal: true
#
# neovim: the OS-independent half — the editor environment.
#
# Included last by darwin.rb and linux.rb so the profile fragment lands after
# the install, exactly as it did in the pre-split default.rb. Kept in one file
# rather than duplicated so EDITOR/VISUAL cannot drift between platforms.
add_profile "editor" do
  priority 50
  bash_content <<~BASH
    export EDITOR="nvim"
    export VISUAL="nvim"
  BASH
end
