# frozen_string_literal: true
#
# Starship cross-shell prompt, linux half. Activated by cookbooks/sheldon's
# profile entry -- this cookbook only installs the binary, so the prompt and
# the plugin lifecycle stay co-located there.
#
# apt does NOT have starship on Ubuntu 24.04 (confirmed live: "E: Unable to
# locate package starship" -- Debian Trixie has it, but Ubuntu's own repos
# don't carry it forward at this release). Use the official installer instead;
# mitamae has no ignore_failure, so an apt-get 404 here used to abort the
# entire linux.rb run for every host past this point. The darwin half installs
# the brew formula (cookbooks/starship/darwin.rb).
execute "curl -fsSL https://starship.rs/install.sh | sh -s -- -y" do
  not_if "which starship"
end
