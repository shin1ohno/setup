execute "$HOME/.volta/bin/npm install -g typescript@beta" do
  not_if { File.exists? "#{ENV["HOME"]}/.volta/bin/tsc" }
end
