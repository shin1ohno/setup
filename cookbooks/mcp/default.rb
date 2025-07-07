mcp_commands = %w(o3-search-mcp mcp-hub)

mcp_commands.each do |com|
  execute "volta install #{com}" do
    not_if "which #{com}"
  end
end
