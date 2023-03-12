# frozen_string_literal: true

package "git"
package "git-lfs"

remote_file "#{ENV["HOME"]}/.gitconfig" do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
  source "files/gitconfig"
end
