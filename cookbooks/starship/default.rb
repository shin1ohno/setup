# frozen_string_literal: true

# Starship cross-shell prompt. Activated by cookbooks/sheldon/ profile entry.
# This cookbook only installs the binary; prompt activation lives with the
# plugin manager (Sheldon) profile so the prompt + plugin lifecycle stay
# co-located.

case node[:platform]
when "darwin"
  package "starship" do
    not_if { brew_formula?("starship") }
  end
when "ubuntu"
  # apt does NOT have starship on Ubuntu 24.04 (confirmed live: "E: Unable
  # to locate package starship" -- Debian Trixie has it, but Ubuntu's own
  # repos don't carry it forward at this release). Use the official
  # installer instead; mitamae has no ignore_failure, so an apt-get 404
  # here used to abort the entire linux.rb run for every host past this
  # point.
  execute "curl -fsSL https://starship.rs/install.sh | sh -s -- -y" do
    not_if "which starship"
  end
else
  raise "Unsupported platform #{node[:platform]} for starship"
end
