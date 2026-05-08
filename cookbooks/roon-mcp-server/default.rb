# frozen_string_literal: true
#
# roon-mcp-server: deploys roon-mcp Rust binary as a docker compose
# service in front of an authentication chain (Hydra JWT validation
# via JWKS). LXC-friendly primitive — extracted from
# cookbooks/lxc-roon-mcp during Phase 6 refactoring. The earlier
# cookbooks/roon-mcp/ (legacy bare-metal pro) had a hardcoded IP gate
# (current_ip == 192.168.1.20) that doesn't apply inside an LXC; this
# primitive is the LXC-targeted re-implementation without that gate.
#
# Parameterised via node attributes (with defaults that match the
# canonical CT 108 deployment):
#
#   node[:roon_mcp_server][:version]      git tag (default "0.5.4")
#   node[:roon_mcp_server][:http_port]    listener port (default 8080)
#   node[:roon_mcp_server][:core_host]    Roon Core address
#                                         (default "192.168.1.20" — direct
#                                         IP, not roon-lxc.home.local; see
#                                         hostname/DNS comment below)
#   node[:roon_mcp_server][:core_port]    Roon Core RAAT port (default 9330)
#   node[:roon_mcp_server][:public_host]  public hostname (default "mcp.ohno.be")
#   node[:roon_mcp_server][:issuer]       JWT issuer (default "https://mcp.ohno.be")
#   node[:roon_mcp_server][:audience]     JWT audience (default "https://mcp.ohno.be/roon")
#   node[:roon_mcp_server][:jwks_url]     JWKS URL (default
#                                         "http://192.168.1.71:4444/.well-known/jwks.json"
#                                         — direct LAN, not the public hairpin)

return if node[:platform] == "darwin"

include_cookbook "docker-engine"

version     = node.dig(:roon_mcp_server, :version)     || "0.5.4"
http_port   = node.dig(:roon_mcp_server, :http_port)   || 8080
# core_host default is the direct IP rather than `roon-lxc.home.local`
# because the container DNS (Docker's embedded resolver, even with RTX
# 192.168.1.253 upstream) returns NAT64-mapped IPv6 addresses (e.g.
# 64:ff9b::c0a8:114) for *.home.local A-record lookups in some
# configurations, and the Roon binary's tokio TCP connect chokes on the
# IPv6 form. Direct IPv4 sidesteps the resolver entirely. Override via
# node[:roon_mcp_server][:core_host] when LAN DNS returns a clean A
# record. Same rationale as cookbooks/cognee + pve/lxc-weave (PR #126).
core_host   = node.dig(:roon_mcp_server, :core_host)   || "192.168.1.20"
core_port   = node.dig(:roon_mcp_server, :core_port)   || 9330
public_host = node.dig(:roon_mcp_server, :public_host) || "mcp.ohno.be"
issuer      = node.dig(:roon_mcp_server, :issuer)      || "https://mcp.ohno.be"
audience    = node.dig(:roon_mcp_server, :audience)    || "https://mcp.ohno.be/roon"
# JWKS_URL points at the LOCAL Hydra public port (192.168.1.71:4444), not
# at the public mcp.ohno.be hairpin. roon_mcp's JwksCache (auth.rs:24)
# refetches every 300s, and reqwest going through the public path takes
# ~4.2s per fetch — observed as a periodic 6-min-spaced 4.2s spike on
# the mcp_probe_phase_latency `sse_open` metric, because the first
# bearer-validated request after TTL expiry blocks on the JWKS fetch
# before serving the response. Going direct cuts the steady-state JWKS
# refetch cost from ~4.2s to <0.5s.
jwks_url    = node.dig(:roon_mcp_server, :jwks_url)    || "http://192.168.1.71:4444/.well-known/jwks.json"

user = node[:setup][:user]
home = node[:setup][:home]

# State directory tree owned by container UID 1000 (matches compose
# `user: "${UID}:${GID}"`). /var/lib is the conventional system-state
# location and is mode-755 root:root by default → traversable for UID
# 1000. `/root/.config/...` cannot be used: container `HOME=/` resolves
# `dirs_next::config_dir()` to `/.config` (unwritable for UID 1000),
# and `/root` is mode 700 root:root in the container image
# (untraversable).
state_root = "/var/lib/roon-mcp"
state_dir = "#{state_root}/state"
app_state_dir = "#{state_dir}/roon-rs"

directory state_root do
  owner "1000"
  group "1000"
  mode "755"
end

directory state_dir do
  owner "1000"
  group "1000"
  mode "755"
end

directory app_state_dir do
  owner "1000"
  group "1000"
  mode "755"
end

file "#{app_state_dir}/tokens.json" do
  owner "1000"
  group "1000"
  mode "600"
  content "{}\n"
  not_if "test -s #{app_state_dir}/tokens.json"
end

deploy_dir = "#{home}/deploy/roon-mcp"

directory deploy_dir do
  owner user
  mode "755"
end

file "#{deploy_dir}/.env" do
  owner user
  mode "644"
  content <<~ENV_FILE
    UID=1000
    GID=1000
  ENV_FILE
  not_if "test -s #{deploy_dir}/.env"
end

# Compose template — note network_mode is bridge (default), NOT host —
# the LXC has its own dedicated network namespace via vmbr0.
file "#{deploy_dir}/docker-compose.yml" do
  owner user
  mode "644"
  content <<~COMPOSE
    services:
      roon-mcp:
        build:
          context: https://github.com/shin1ohno/roon-rs.git#v#{version}
          dockerfile: crates/roon-mcp/Dockerfile
        image: roon-mcp:#{version}
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
          - "#{http_port}:#{http_port}"
        user: "${UID}:${GID}"
        # Default container DNS does not include the LAN's home.local
        # zone (RTX-served), so home.local hostnames fail to resolve
        # inside the container. Pin Cloudflare for general internet +
        # the LAN's RTX (192.168.1.253) for *.home.local. The RTX entry
        # keeps this working even if DHCP-served DNS changes.
        dns:
          - 192.168.1.253
          - 1.1.1.1
        volumes:
          - #{state_dir}:/data:rw
        command:
          - --transport
          - http
          - --http-port
          - "#{http_port}"
          - --host
          - "#{core_host}"
          - --port
          - "#{core_port}"
          - --allowed-host
          - "#{public_host}"
          - --issuer
          - "#{issuer}"
          - --audience
          - "#{audience}"
          - --jwks-url
          - "#{jwks_url}"
          - --require-auth
  COMPOSE
  notifies :run, "execute[restart roon-mcp]"
end

# Compose orchestration via the compose_service DSL. buildkit: false
# forces DOCKER_BUILDKIT=0 because roon-mcp runs in an unprivileged LXC
# where BuildKit's mount namespacing trips up despite features_nesting
# (see ~/.claude/rules/pve-lxc.md). The compose spec uses git-source
# context but NOT the `#ref:subdir` syntax, so classic builder is
# sufficient.
compose_service "roon-mcp" do
  compose_path "#{deploy_dir}/docker-compose.yml"
  deploy_dir deploy_dir
  buildkit false
end
