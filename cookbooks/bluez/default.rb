package "bluez" do
  user node[:setup][:user]
end

package "bluetooth" do
  user node[:setup][:user]
end

