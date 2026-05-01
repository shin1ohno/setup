## frozen_string_literal: true

package "avahi-daemon" do
  user node[:setup][:system_user]
  not_if { run_command("dpkg-query -W -f='${Status}' avahi-daemon 2>/dev/null | grep -q 'install ok installed'", error: false).exit_status == 0 }
end
