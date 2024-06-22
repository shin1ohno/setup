case node[:platform]
when "darwin"
  execute "brew tap teamookla/speedtest && brew update" do
    not_if "which speedtest"
  end

  package "speedtest"
when "ubuntu" 
  execute "Install speedtest-cli" do
    command "pip install speedtest-cli"
    not_if "which speedtest"
  end
end


