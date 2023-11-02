# frozen_string_literal: true

case node[:platform]
when "darwin"
  package "envchain"
when "arch"
  include_cookbook "arch-wanko-cc"
  package "envchain" do
    user "root"
  end
when "ubuntu"
  #skip!
else
  raise NotImplementedError
end
