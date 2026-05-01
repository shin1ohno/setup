case node[:platform]
when "darwin"
  package "iperf3"
else
  package "iperf3" do
    user "root"
    not_if { run_command("dpkg-query -W -f='${Status}' iperf3 2>/dev/null | grep -q 'install ok installed'", error: false).exit_status == 0 }
  end
end
