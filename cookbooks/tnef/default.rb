case node[:platform]
when "darwin"
  package "tnef"
else
  package "tnef" do
    user node[:setup][:system_user]
    not_if { run_command("dpkg-query -W -f='${Status}' tnef 2>/dev/null | grep -q 'install ok installed'", error: false).exit_status == 0 }
  end
end
