# frozen_string_literal: true

if node[:platform] == "ubuntu"
  package "universal-ctags"
else
  package "ctags"
end
