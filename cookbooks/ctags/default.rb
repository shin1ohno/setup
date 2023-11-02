# frozen_string_literal: true

case node[:platform]
when "ubuntu"
  package "universal-ctags" do
    user "root"
  end
when "darwin"
  package "ctags"
else
  package "ctags" do
    user "root"
  end
end
