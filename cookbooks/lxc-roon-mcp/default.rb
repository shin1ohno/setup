# frozen_string_literal: true
#
# lxc-roon-mcp (CT 108): Roon MCP OAuth-protected server.
#
# Re-implements the deployment shape of cookbooks/roon-mcp but without the
# bare-metal IP gate (cookbooks/roon-mcp checks current_ip == 192.168.1.20
# to scope to legacy pro_1, which doesn't apply inside the LXC at .35).
#
# Network: vmbr0 (single interface, no host network sharing). The HTTP
# port 8080 is reachable on 192.168.1.35:8080 via the bridge.
#
# Bind-mount (set up by Terraform):
#   - host /mnt/data/roon-mcp/tokens.json → /root/.config/roon-rs/tokens.json
#
# RAM 1 GiB / CPU 1.

return if node[:platform] == "darwin"

include_cookbook "docker-engine"

ROON_MCP_VERSION = "0.5.3"
ROON_MCP_HTTP_PORT = 8080
# Roon Core lives in lxc-roon (CT 100, default IP 192.168.1.20).
# Override via node[:roon_core][:host] when the Terraform-managed IP
# changes.
ROON_MCP_CORE_HOST = node.dig(:roon_core, :host) || "192.168.1.20"
ROON_MCP_CORE_PORT = 9330
ROON_MCP_PUBLIC_HOST = "mcp.ohno.be"
ROON_MCP_ISSUER = "https://mcp.ohno.be"
ROON_MCP_AUDIENCE = "https://mcp.ohno.be/roon"
ROON_MCP_JWKS_URL = "https://mcp.ohno.be/.well-known/jwks.json"

user = node[:setup][:user]
home = node[:setup][:home]

directory "#{home}/.config/roon-rs" do
  owner user
  mode "755"
end

file "#{home}/.config/roon-rs/tokens.json" do
  owner user
  mode "600"
  content "{}\n"
  not_if "test -s #{home}/.config/roon-rs/tokens.json"
end

directory "#{home}/deploy/roon-mcp" do
  owner user
  mode "755"
end

file "#{home}/deploy/roon-mcp/.env" do
  owner user
  mode "644"
  content <<~ENV_FILE
    UID=1000
    GID=1000
  ENV_FILE
  not_if "test -s #{home}/deploy/roon-mcp/.env"
end

# Compose template — note network_mode is bridge (default), NOT host —
# the LXC has its own dedicated network namespace via vmbr0.
file "#{home}/deploy/roon-mcp/docker-compose.yml" do
  owner user
  mode "644"
  content <<~COMPOSE
    services:
      roon-mcp:
        build:
          context: https://github.com/shin1ohno/roon-rs.git#v#{ROON_MCP_VERSION}
          dockerfile: crates/roon-mcp/Dockerfile
        image: roon-mcp:#{ROON_MCP_VERSION}
        container_name: roon-mcp
        restart: unless-stopped
        ports:
          - "#{ROON_MCP_HTTP_PORT}:#{ROON_MCP_HTTP_PORT}"
        user: "${UID}:${GID}"
        volumes:
          - #{home}/.config/roon-rs:/root/.config/roon-rs:rw
        command:
          - --transport
          - http
          - --http-port
          - "#{ROON_MCP_HTTP_PORT}"
          - --host
          - "#{ROON_MCP_CORE_HOST}"
          - --port
          - "#{ROON_MCP_CORE_PORT}"
          - --allowed-host
          - "#{ROON_MCP_PUBLIC_HOST}"
          - --issuer
          - "#{ROON_MCP_ISSUER}"
          - --audience
          - "#{ROON_MCP_AUDIENCE}"
          - --jwks-url
          - "#{ROON_MCP_JWKS_URL}"
          - --require-auth
  COMPOSE
  notifies :run, "execute[restart roon-mcp]"
end

compose_path = "#{home}/deploy/roon-mcp/docker-compose.yml"
project_name = "roon-mcp"

execute "ensure roon-mcp running" do
  command "docker compose -f #{compose_path} up -d --build"
  user user
  only_if <<~SH.tr("\n", " ").strip
    expected=$(docker compose -f #{compose_path} config --services 2>/dev/null | sort | tr '\\n' ' ');
    [ -n "$expected" ] || exit 1;
    running=$(docker ps --filter "label=com.docker.compose.project=#{project_name}"
                        --filter status=running --format '{{.Label "com.docker.compose.service"}}'
              | sort | tr '\\n' ' ');
    test "$running" = "$expected" && exit 1 || exit 0
  SH
end

execute "restart roon-mcp" do
  command "docker compose -f #{compose_path} up -d --build"
  user user
  action :nothing
end
