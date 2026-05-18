# frozen_string_literal: true

# Set system timezone to Asia/Tokyo.
#
# Uses direct symlink + /etc/timezone write instead of `timedatectl
# set-timezone` because systemd-timedated is not reliably available
# inside unprivileged PVE LXCs (D-Bus / timedated unit not running).
# Idempotent: skip when both /etc/localtime target and /etc/timezone
# content already match.

execute "set timezone to Asia/Tokyo" do
  command 'ln -sf /usr/share/zoneinfo/Asia/Tokyo /etc/localtime && printf "Asia/Tokyo\n" > /etc/timezone'
  user node[:setup][:system_user]
  not_if 'test "$(readlink -f /etc/localtime 2>/dev/null)" = /usr/share/zoneinfo/Asia/Tokyo && grep -qFx Asia/Tokyo /etc/timezone'
end
