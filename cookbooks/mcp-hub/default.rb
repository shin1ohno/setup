execute "$HOME/.volta/bin/npm install -g mcp-hub" do
  not_if { File.exists? "#{ENV["HOME"]}/.volta/bin/mcp-hub" }
end

