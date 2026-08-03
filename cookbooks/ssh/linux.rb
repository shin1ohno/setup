# frozen_string_literal: true
#
# ssh (Linux): per-user agent management varies (systemd-user
# `ssh-agent.socket` vs gnome-keyring vs eval-on-shell). Keep the per-shell
# eval until linux setup is audited separately.
#
# darwin.rb deletes this same fragment rather than writing it — see there for
# why macOS must not source an agent per shell.

add_profile "ssh" do
  priority 10
  bash_content <<"EOM"
eval "$(ssh-agent)" > /dev/null
EOM
end
