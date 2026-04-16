package "bluez" do
  user node[:setup][:system_user]
end

package "bluetooth" do
  user node[:setup][:system_user]
end

package "libdbus-1-dev" do
  user node[:setup][:system_user]
end

