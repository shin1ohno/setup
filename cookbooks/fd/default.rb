# frozen_string_literal: true

case node[:platform] 
when "ubuntu"
  package "fd-find" do
    user node[:setup][:user]
  end
when "darwin"
  package "fd"
else
  package "fd" do
    user node[:setup][:user]
  end
end

