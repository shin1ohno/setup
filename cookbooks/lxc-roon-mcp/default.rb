# frozen_string_literal: true
#
# lxc-roon-mcp (CT 108): Roon MCP OAuth-protected server.
#
# Re-implements the deployment shape of cookbooks/roon-mcp but without the
# bare-metal IP gate (cookbooks/roon-mcp checks current_ip == 192.168.1.20
# to scope to legacy pro_1, which doesn't apply inside this LXC).
#
# Network: vmbr0 (single interface, no host network sharing). The HTTP
# port 8080 is reachable on roon-mcp.home.local:8080 via the bridge.
#
# State directory:
#   host /var/lib/roon-mcp/state → container /data (XDG_CONFIG_HOME=/data),
#   owner UID 1000:GID 1000 to match compose `user: "${UID}:${GID}"`.
#   Application resolves `dirs_next::config_dir().join("roon-rs/tokens.json")`
#   to `/data/roon-rs/tokens.json`.
#
# RAM 1 GiB / CPU 1.

return if node[:platform] == "darwin"

include_cookbook "docker-engine"

ROON_MCP_VERSION = "0.5.3"
ROON_MCP_HTTP_PORT = 8080
# Roon Core lives in lxc-roon (CT 100) at 192.168.1.20 (Phase 9 cutover IP).
# Default is the direct IP rather than `roon-lxc.home.local` because the
# container DNS (via Docker's embedded resolver, even with RTX 192.168.1.253
# upstream) returns NAT64-mapped IPv6 addresses (e.g. 64:ff9b::c0a8:114) for
# *.home.local A-record lookups in some configurations, and the Roon binary's
# tokio TCP connect chokes on the IPv6 form. Direct IPv4 sidesteps the
# resolver entirely. Override via node[:roon_core][:host] when LAN DNS
# returns a clean A record. Same rationale as cookbooks/lxc-weave (PR #126).
ROON_MCP_CORE_HOST = node.dig(:roon_core, :host) || "192.168.1.20"
ROON_MCP_CORE_PORT = 9330
ROON_MCP_PUBLIC_HOST = "mcp.ohno.be"
ROON_MCP_ISSUER = "https://mcp.ohno.be"
ROON_MCP_AUDIENCE = "https://mcp.ohno.be/roon"
ROON_MCP_JWKS_URL = "https://mcp.ohno.be/.well-known/jwks.json"

user = node[:setup][:user]
home = node[:setup][:home]

# State directory tree owned by container UID 1000 (matches compose
# `user: "${UID}:${GID}"`). /var/lib is the conventional system-state
# location and is mode-755 root:root by default → traversable for UID 1000.
# `/root/.config/...` cannot be used: container `HOME=/` resolves
# `dirs_next::config_dir()` to `/.config` (unwritable for UID 1000), and
# `/root` is mode 700 root:root in the container image (untraversable).
roon_mcp_state_root = "/var/lib/roon-mcp"
roon_mcp_state_dir = "#{roon_mcp_state_root}/state"
roon_mcp_app_state_dir = "#{roon_mcp_state_dir}/roon-rs"

directory roon_mcp_state_root do
  owner 1000
  group 1000
  mode "755"
end

directory roon_mcp_state_dir do
  owner 1000
  group 1000
  mode "755"
end

directory roon_mcp_app_state_dir do
  owner 1000
  group 1000
  mode "755"
end

file "#{roon_mcp_app_state_dir}/tokens.json" do
  owner 1000
  group 1000
  mode "600"
  content "{}\n"
  not_if "test -s #{roon_mcp_app_state_dir}/tokens.json"
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
        # Debug-level logging on the auth path so token validation
        # rejections (audience / issuer / signature mismatch) surface in
        # `docker logs roon-mcp`. Default INFO suppresses the reason and
        # makes claude.ai's "Authorization with the MCP server failed"
        # impossible to triage server-side.
        environment:
          RUST_LOG: "info,roon_mcp::auth=debug"
          # XDG_CONFIG_HOME drives `dirs_next::config_dir()` inside the
          # container. Pinning to /data routes state writes into the
          # bind-mounted host path /var/lib/roon-mcp/state (owner UID 1000).
          XDG_CONFIG_HOME: "/data"
        ports:
          - "#{ROON_MCP_HTTP_PORT}:#{ROON_MCP_HTTP_PORT}"
        user: "${UID}:${GID}"
        # Default container DNS does not include the LAN's home.local zone
        # (RTX-served), so `roon-lxc.home.local` (ROON_MCP_CORE_HOST) fails
        # to resolve inside the container. Pin Cloudflare for general
        # internet + the LAN's RTX (192.168.1.253) for *.home.local. The
        # RTX entries in cookbooks/lxc-roon-mcp's hardcoded list keep this
        # working even if DHCP-served DNS changes.
        dns:
          - 192.168.1.253
          - 1.1.1.1
        volumes:
          - #{roon_mcp_state_dir}:/data:rw
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
  command "DOCKER_BUILDKIT=0 docker compose -f #{compose_path} up -d --build"
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
  command "DOCKER_BUILDKIT=0 docker compose -f #{compose_path} up -d --build"
  user user
  action :nothing
end
