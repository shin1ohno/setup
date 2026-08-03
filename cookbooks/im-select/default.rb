# frozen_string_literal: true
#
# im-select — macOS input-source switcher (https://github.com/daipeihust/im-select).
# The AstroNvim config in cookbooks/dot-config-nvim calls it to restore the
# ASCII input source when leaving insert mode, so it is meaningful only on
# darwin. Extracted from dot-config-nvim's trailing `case node[:platform]` so
# that cookbook carries no OS branch; the `platform` marker beside this file
# makes a cross-OS include fail loudly instead of silently no-opping.
#
# Sibling darwin-only input-method cookbook: cookbooks/macism.
execute "brew tap daipeihust/tap && brew install im-select" do
  not_if "which im-select"
end
