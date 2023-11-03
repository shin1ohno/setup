# frozen_string_literal: true

package "tmux" do
  user node[:platform] == "darwin" ? node[:setup][:user] : "root"
end

