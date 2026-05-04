package "smartmontools" do
  user node[:setup][:system_user]
  not_if do
    if node[:platform] == "darwin"
      run_command("brew list --formula smartmontools >/dev/null 2>&1", error: false).exit_status == 0
    else
      run_command("dpkg-query -W -f='${Status}' smartmontools 2>/dev/null | grep -q 'install ok installed'", error: false).exit_status == 0
    end
  end
end
