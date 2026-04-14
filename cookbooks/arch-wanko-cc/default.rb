# frozen_string_literal: true

execute "pacman-key --recv-keys C48DBD97 && pacman-key --lsign-key C48DBD97" do
  action :nothing
end

server_block = "[aur-eagletmt]\nServer = http://arch.wanko.cc/\\$repo/os/\\$arch"

execute "add aur-eagletmt to pacman.conf" do
  command "printf '\\n#{server_block}\\n' | sudo tee -a /etc/pacman.conf > /dev/null"
  not_if "grep -q '\\[aur-eagletmt\\]' /etc/pacman.conf"
  notifies :run, "execute[pacman-key --recv-keys C48DBD97 && pacman-key --lsign-key C48DBD97]"
end
