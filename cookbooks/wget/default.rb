# frozen_string_literal: true

case node[:platform]
when "darwin"
  package "wget"
else # Linux
  package "wget" do
    user node[:setup][:system_user]
    not_if { run_command("dpkg-query -W -f='${Status}' wget 2>/dev/null | grep -q 'install ok installed'", error: false).exit_status == 0 }
  end
end

