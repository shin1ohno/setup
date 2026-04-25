# frozen_string_literal: true
#
# roon-mcp: SSE MCP server exposing Roon Core as AI assistant tools.
# Linux-only — included from linux.rb. macOS is intentionally not supported
# (Roon Core lives on the Linux server; running roon-mcp on a Mac would only
# add an extra network hop).
#
# Per-host deploy:
#   - cargo install roon-mcp                    → ~/.cargo/bin/roon-mcp
#   - ~/.config/roon-rs/tokens.json must already hold a paired token
#     (one-time bootstrap via `roon-cli` or first stdio run; not managed here
#     because Roon's pairing requires interactive approval in the Roon UI)
#   - systemd --user unit, user runs `systemctl --user enable --now roon-mcp`

# Constant names are prefixed to avoid mruby's cross-recipe global namespace
# (frozen constants get silently overwritten when two cookbooks reuse the same name).
ROON_MCP_VERSION = "0.5.2"
ROON_MCP_SSE_PORT = 8080
ROON_MCP_CORE_HOST = "192.168.1.20"
ROON_MCP_CORE_PORT = 9330

user = node[:setup][:user]
home = node[:setup][:home]
cargo_bin = "#{home}/.cargo/bin/roon-mcp"

# Binary install — idempotent via .crates.toml grep. Same shape as edge-agent.
execute "cargo install roon-mcp #{ROON_MCP_VERSION}" do
  command "#{home}/.cargo/bin/cargo install roon-mcp --version #{ROON_MCP_VERSION} --locked"
  user user
  cwd home
  not_if "grep -q '\"roon-mcp #{ROON_MCP_VERSION} (registry' #{home}/.cargo/.crates.toml 2>/dev/null"
end

directory "#{home}/.config/systemd/user" do
  owner user
  mode "755"
end

file "#{home}/.config/systemd/user/roon-mcp.service" do
  owner user
  mode "644"
  content <<~UNIT
    [Unit]
    Description=roon-mcp (SSE)
    Documentation=https://github.com/shin1ohno/roon-rs
    After=network-online.target
    Wants=network-online.target

    [Service]
    Type=simple
    ExecStart=#{cargo_bin} --transport sse --http-port #{ROON_MCP_SSE_PORT} --host #{ROON_MCP_CORE_HOST} --port #{ROON_MCP_CORE_PORT} --allowed-host pro.home.local
    Environment=RUST_LOG=info
    Restart=on-failure
    RestartSec=5s

    [Install]
    WantedBy=default.target
  UNIT
end

# systemctl --user requires the user's DBus session — not available to mitamae.
# Run once interactively after the first apply:
#   systemctl --user daemon-reload
#   systemctl --user enable --now roon-mcp
