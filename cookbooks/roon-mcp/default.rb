# frozen_string_literal: true
#
# roon-mcp: OAuth-protected MCP server exposing Roon Core as AI assistant tools.
#
# Deployment shape (see ~/.claude/plans/frolicking-beaming-crescent.md):
#   - Docker compose at ~/deploy/roon-mcp/, build context = upstream git tag
#   - network_mode: host (direct Roon Core access on same machine, no SOOD needed)
#   - Bearer JWT verification in-process against Hydra JWKS
#   - Public entry: https://mcp.ohno.be/roon/  (nginx → Tailscale → :8080)
#
# Scoped to pro_1 (192.168.1.20) only — Roon Core lives there. The other
# pro_* hosts share the hostname `pro` but do NOT run Roon Core, so a
# hostname-only gate would deploy roon-mcp three times. IP gate disambiguates.

current_ip = run_command("hostname -I", error: false).stdout.split.first.to_s
unless current_ip == "192.168.1.20"
  MItamae.logger.info(
    "roon-mcp: this host (#{current_ip.empty? ? "unknown" : current_ip}) is not Roon Core (192.168.1.20), skipping"
  )
  return
end

ROON_MCP_VERSION = "0.5.3"
ROON_MCP_HTTP_PORT = 8080
ROON_MCP_CORE_HOST = "192.168.1.20"
ROON_MCP_CORE_PORT = 9330
ROON_MCP_PUBLIC_HOST = "mcp.ohno.be"
ROON_MCP_ISSUER = "https://mcp.ohno.be"
ROON_MCP_AUDIENCE = "https://mcp.ohno.be/roon"
ROON_MCP_JWKS_URL = "https://mcp.ohno.be/.well-known/jwks.json"

user = node[:setup][:user]
home = node[:setup][:home]

# Docker is already installed via cookbooks/docker on this host (cognee /
# hydra stacks depend on it). If absent, surface the dependency rather than
# silently install — keeps responsibility in the docker cookbook.
execute "verify docker is installed" do
  command "command -v docker >/dev/null 2>&1"
  not_if "command -v docker >/dev/null 2>&1"
end

# Pre-create the Roon token file. A bind-mount of a non-existent file
# turns into a directory bind, breaking FileStateStore reads.
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

# Deploy directory mirrors ~/deploy/cognee, ~/deploy/hydra layout.
directory "#{home}/deploy/roon-mcp" do
  owner user
  mode "755"
end

# UID / GID env vars so the container runs as the same user that owns the
# token file on the host — required for FileStateStore rw access.
file "#{home}/deploy/roon-mcp/.env" do
  owner user
  mode "644"
  content <<~ENV_FILE
    UID=1000
    GID=1000
  ENV_FILE
  not_if "test -s #{home}/deploy/roon-mcp/.env"
end

# Render docker-compose.yml. Buildkit pulls the upstream tag directly,
# avoiding a separate git checkout to manage. Bumping ROON_MCP_VERSION
# above is the only knob needed to upgrade.
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
        network_mode: host
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
        environment:
          RUST_LOG: info
  COMPOSE
end

# `docker compose up` is intentionally not run from mitamae — it requires
# the user's docker group membership and may need an interactive Roon
# pairing on first start. After this cookbook applies, run:
#
#   cd ~/deploy/roon-mcp && docker compose up -d --build
#
# To upgrade to a newer version:
#   1. Bump ROON_MCP_VERSION above, run mitamae
#   2. cd ~/deploy/roon-mcp && docker compose up -d --build --pull always
MItamae.logger.info(
  "roon-mcp: docker-compose.yml staged at ~/deploy/roon-mcp/. " \
  "Run `cd ~/deploy/roon-mcp && docker compose up -d --build` to start."
)
