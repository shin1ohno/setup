# frozen_string_literal: true

include_cookbook "homebrew"

execute %w[brew tap homebrew/cask-versions] do
  not_if "brew tap | grep -q  homebrew/cask-versions"
end
