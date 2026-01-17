# Ensure Node.js is installed via mise
include_cookbook "nodejs"

mcp_commands = %w(o3-search-mcp mcp-hub)

mcp_commands.each do |com|
  execute "export PATH=$HOME/.local/share/mise/shims:$PATH && npm install -g #{com}" do
    user node[:setup][:user]
    not_if "export PATH=$HOME/.local/share/mise/shims:$PATH && npm list -g #{com}"
  end
end
