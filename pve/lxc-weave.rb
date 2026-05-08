# frozen_string_literal: true
#
# Entry recipe for the weave LXC (CT 109): weave 4-component MQTT mesh
# (mosquitto + roon-hub + weave-server + weave-web). Connects to lxc-roon
# at roon-lxc.home.local:9330 via roon-hub.
#
# Bind-mount (set up by Terraform):
#   - /mnt/data/weave (rw, idmap)
#
# RAM 4 GiB / CPU 2.
#
# Run inside the LXC after the Terraform layer has provisioned it:
#   apt-get install -y git curl ca-certificates sudo
#   git clone https://github.com/shin1ohno/setup.git /root/setup
#   cd /root/setup && ./bin/setup
#   ./bin/mitamae local pve/lxc-weave.rb

include_recipe "../cookbooks/functions/default"

user = ENV["USER"]
group = `id -gn`.strip
node.reverse_merge!(
  setup: {
    home: ENV["HOME"],
    root: "#{ENV["HOME"]}/.setup_shin1ohno",
    user: user,
    group: group,
    system_user: "root",
    system_group: "root",
  }
)

include_cookbook "docker-engine"

deploy_dir = "#{node[:setup][:home]}/deploy/weave"

# Roon Core LXC reachable on 192.168.1.20 (Phase 9 cutover IP). Default
# is the direct IP rather than `roon-lxc.home.local` because the weave
# LXC's resolv.conf points at 1.1.1.1 (Cloudflare) which cannot resolve
# *.home.local. Override via node[:roon_core][:host] when LAN DNS for
# home.local becomes available (HANDOFF Issue 2.6).
roon_core_host = node.dig(:roon_core, :host) || "192.168.1.20"

# Build images from the upstream weave repo at apply time. Earlier draft
# referenced shin1ohno/{roon-hub,weave-server,weave-web}:latest on Docker
# Hub, but those images aren't published — `docker pull` returned
# "pull access denied for shin1ohno/roon-hub". Switch to git-source
# `build:` (same pattern as cookbooks/lxc-roon-mcp) so the images are
# constructed from the canonical source on every apply.
#
# Override the ref via node[:weave][:git_ref] (default "main"). For a
# stable pin, set to a release tag like "weave-server-v0.1.8".
weave_git_ref = node.dig(:weave, :git_ref) || "main"
weave_git_url = "https://github.com/shin1ohno/weave.git##{weave_git_ref}"

directory deploy_dir do
  owner user
  group group
  mode "755"
end

%w[mosquitto-data mosquitto-log roon-hub-data weave-data].each do |sub|
  directory "#{deploy_dir}/#{sub}" do
    owner user
    group group
    mode "755"
  end
end

# Mosquitto config — anonymous + listener 1883 for inside-LXC use.
# Hardening (auth/TLS) is out of scope for the LAN-only weave mesh.
file "#{deploy_dir}/mosquitto.conf" do
  owner user
  group group
  mode "644"
  content <<~CONF
    listener 1883
    allow_anonymous true
    persistence true
    persistence_location /mosquitto/data/
    log_dest stdout
  CONF
  notifies :run, "execute[restart weave]"
end

# roon-hub binary reads /etc/roon-hub/roon-hub.toml at startup; it does
# NOT read bare env vars like MQTT_HOST (the binary expects ROON_HUB_*
# prefix, e.g. ROON_HUB_MQTT_HOST). Without this file the binary falls
# back to compiled-in defaults that target localhost MQTT, producing
# perpetual "MQTT error: Connection refused (os error 111)" loops.
# token_path is /data/tokens.json so the Roon pairing survives container
# rebuilds via the ./roon-hub-data:/data volume mount.
file "#{deploy_dir}/roon-hub.toml" do
  owner user
  group group
  mode "644"
  content <<~TOML
    [roon]
    extension_id = "com.roon-rs.hub"
    display_name = "roon-hub"
    publisher = "roon-rs"
    email = "dev@example.com"
    token_path = "/data/tokens.json"
    host = "#{roon_core_host}"
    port = 9330

    [mqtt]
    host = "mosquitto"
    port = 1883
    client_id = "roon-hub"
    topic_prefix = "roon"
  TOML
  notifies :run, "execute[restart weave]"
end

# docker-compose.yml — uses upstream-built images for now. When weave-rs
# images are not on a registry, switch to git-source builds (like roon-mcp).
file "#{deploy_dir}/docker-compose.yml" do
  owner user
  group group
  mode "644"
  content <<~COMPOSE
    services:
      mosquitto:
        image: eclipse-mosquitto:2
        container_name: weave-mosquitto
        restart: unless-stopped
        ports:
          - "1883:1883"
        volumes:
          - ./mosquitto.conf:/mosquitto/config/mosquitto.conf:ro
          - ./mosquitto-data:/mosquitto/data
          - ./mosquitto-log:/mosquitto/log

      roon-hub:
        build:
          # roon-hub is part of the cargo workspace at the repo root —
          # building from deploy/roon-hub/ (subdir context) breaks workspace
          # inheritance. Build from repo root, point dockerfile at the
          # subpath. Same applies to weave-server below.
          context: #{weave_git_url}
          dockerfile: deploy/roon-hub/Dockerfile
        image: weave-roon-hub:#{weave_git_ref}
        container_name: weave-roon-hub
        restart: unless-stopped
        depends_on:
          - mosquitto
        # NOTE: roon-hub binary reads /etc/roon-hub/roon-hub.toml (mounted
        # below), NOT these env vars (it expects ROON_HUB_* prefix). Env
        # vars are kept as documentation of intent in case upstream adds
        # a no-prefix env var path in the future.
        environment:
          ROON_CORE_HOST: #{roon_core_host}
          ROON_CORE_PORT: 9330
          MQTT_HOST: mosquitto
          MQTT_PORT: 1883
        volumes:
          - ./roon-hub-data:/data
          - ./roon-hub.toml:/etc/roon-hub/roon-hub.toml:ro

      weave-server:
        build:
          # Cargo workspace root is the repo top-level (Cargo.toml uses
          # workspace.package.edition); subdir context fails with
          # "failed to find a workspace root". Build from repo root.
          context: #{weave_git_url}
          dockerfile: crates/weave-server/Dockerfile
        image: weave-server:#{weave_git_ref}
        container_name: weave-server
        restart: unless-stopped
        depends_on:
          - mosquitto
        environment:
          MQTT_HOST: mosquitto
          MQTT_PORT: 1883
        ports:
          # weave-server listens on 3001 (api_port) per its source. The
          # legacy nginx upstream config in home-monitor still maps 8888
          # → keep both port mappings so old + new clients work. Long-term
          # the home-monitor upstream config should switch to 3001.
          - "3001:3001"
          - "8888:3001"
        volumes:
          - ./weave-data:/data

      weave-web:
        build:
          context: #{weave_git_url}:weave-web
        image: weave-web:#{weave_git_ref}
        container_name: weave-web
        restart: unless-stopped
        depends_on:
          - weave-server
        environment:
          NEXT_PUBLIC_WEAVE_SERVER: http://weave-server:3001
        ports:
          - "3000:3000"
  COMPOSE
  notifies :run, "execute[restart weave]"
end

# Compose orchestration via the compose_service DSL
# (cookbooks/functions/default.rb). BuildKit (default true) is required
# for the `#ref:subdir` git context syntax used by weave-web above;
# classic builder (DOCKER_BUILDKIT=0) does not support subdir context.
# The weave LXC has features_nesting=true (home-monitor#4), so
# BuildKit's rbind requirements are satisfied. No env_path because the
# weave compose spec does not consume a .env file (Roon Core IP and
# weave_git_ref come from node attributes baked into docker-compose.yml
# at apply time).
compose_service "weave" do
  compose_path "#{deploy_dir}/docker-compose.yml"
  deploy_dir deploy_dir
end

include_role "lxc-core"
