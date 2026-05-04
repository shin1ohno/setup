case node[:platform]
when "darwin"
  package "smartmontools"
else
  package "smartmontools" do
    user node[:setup][:system_user]
    not_if { run_command("dpkg-query -W -f='${Status}' smartmontools 2>/dev/null | grep -q 'install ok installed'", error: false).exit_status == 0 }
  end
end
