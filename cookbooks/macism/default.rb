# frozen_string_literal: true

return unless node[:platform] == "darwin"

execute "brew tap laishulu/homebrew" do
  not_if "brew tap | grep laishulu/homebrew"
end

package "macism" do
  user node[:setup][:user]
end
