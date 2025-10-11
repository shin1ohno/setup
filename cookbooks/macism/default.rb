# frozen_string_literal: true

return unless node[:platform] == "darwin"

execute "brew tap laishulu/macism" do
  not_if "brew tap | grep laishulu/macism"
end

package "macism" do
  user node[:setup][:user]
end
