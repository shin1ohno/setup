# frozen_string_literal: true

case node[:platform] 
when "ubuntu"
  package "fd-find" do
    user "root"
  end
when "darwin"
  package "fd"
else
  package "fd" do
    user "root"
  end
end

