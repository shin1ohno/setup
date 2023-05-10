execute "$HOME/.volta/bin/npm install -g typescript@beta" do
  not_if { File.exists? "$HOME/.volta/bin/tsc" }
end
