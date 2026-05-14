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
  # apt has starship in Ubuntu 23.04+ / Debian Trixie. For older releases
  # the cookbook will fail at the apt-get step — adjust to the official
  # installer (curl -fsSL https://starship.rs/install.sh | sh -s -- -y) if
  # that ever happens.
  install_package "starship" do
    ubuntu "starship"
  end
else
  raise "Unsupported platform #{node[:platform]} for starship"
end
