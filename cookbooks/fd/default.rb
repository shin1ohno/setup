# frozen_string_literal: true

if node[:platform] == "ubuntu"
  package "fd-find"
else
  package "fd"
end

