# frozen_string_literal: true

package "mosh" do
  user node[:setup][:system_user]
  not_if { run_command("dpkg-query -W -f='${Status}' mosh 2>/dev/null | grep -q 'install ok installed'", error: false).exit_status == 0 }
end

# mosh-server refuses to start unless a UTF-8 native locale is
# available; LXC images and minimal Debian/Ubuntu installs ship with
# only C / C.utf8 / POSIX. Enable en_US.UTF-8 + ja_JP.UTF-8 in
# /etc/locale.gen and run locale-gen. Symptom on a missing locale
# is Blink/iTerm "NoMoshServerArgs - Did not find mosh server
# startup message" because mosh-server's locale error is printed
# before MOSH CONNECT and the client treats the prefix as garbage.
execute "enable UTF-8 locales for mosh-server" do
  command <<~BASH
    sed -i \
      -e 's/^# en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' \
      -e 's/^# ja_JP.UTF-8 UTF-8/ja_JP.UTF-8 UTF-8/' \
      /etc/locale.gen
    /usr/sbin/locale-gen
  BASH
  user node[:setup][:system_user]
  not_if { run_command("locale -a 2>/dev/null | grep -qx en_US.utf8", error: false).exit_status == 0 }
end
