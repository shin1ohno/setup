package "bluez" do
  user node[:setup][:install_user]
end

package "bluetooth" do
  user node[:setup][:install_user]
end

