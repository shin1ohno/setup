# frozen_string_literal: true

package "thefuck" do
  user node[:platform] == "darwin" ? node[:setup][:user] : "root"
end

add_profile "thefuck" do
  bash_content <<~EOS
    eval $(thefuck --alias)
  EOS
end
