# frozen_string_literal: true

case node[:platform]
when "darwin"
  package "wget"
else # Linux
  package "wget" do
    user node[:setup][:system_user]
  end
end

