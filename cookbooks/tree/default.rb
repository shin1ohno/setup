# frozen_string_literal: true

package "tree" do
  user node[:platform] == "darwin" ? node[:setup][:user] : "root"
end

