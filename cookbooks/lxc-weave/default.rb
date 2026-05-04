# frozen_string_literal: true
#
# lxc-weave (CT 109): weave 4-component MQTT mesh + UI.
#
# Components (all docker compose):
#   - weave-server (Rust, MQTT broker bridge + state hub)
#   - weave-web (Next.js UI)
#   - roon-hub (Rust, Roon Core ↔ MQTT bridge)
#   - mosquitto (MQTT broker)
#
# Bind-mount (set up by Terraform):
#   - /mnt/data/weave (rw, idmap)
#
# RAM 4 GiB / CPU 2.

return if node[:platform] == "darwin"

include_cookbook "docker-engine"

user = node[:setup][:user]
group = node[:setup][:group]
deploy_dir = "#{node[:setup][:home]}/deploy/weave"

# Roon Core LXC reachable over the home.local DNS zone. Override via
# node[:roon_core][:host] when running against a non-LXC Roon deployment.
roon_core_host = node.dig(:roon_core, :host) || "roon-lxc.home.local"

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
          context: #{weave_git_url}
          dockerfile: deploy/roon-hub/Dockerfile
        image: weave-roon-hub:#{weave_git_ref}
        container_name: weave-roon-hub
        restart: unless-stopped
        depends_on:
          - mosquitto
        environment:
          ROON_CORE_HOST: #{roon_core_host}
          ROON_CORE_PORT: 9330
          MQTT_HOST: mosquitto
          MQTT_PORT: 1883
        volumes:
          - ./roon-hub-data:/data

      weave-server:
        build:
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
          - "8888:8888"
        volumes:
          - ./weave-data:/data

      weave-web:
        build:
          context: #{weave_git_url}
          dockerfile: weave-web/Dockerfile
        image: weave-web:#{weave_git_ref}
        container_name: weave-web
        restart: unless-stopped
        depends_on:
          - weave-server
        environment:
          NEXT_PUBLIC_WEAVE_SERVER: http://weave-server:8888
        ports:
          - "3000:3000"
  COMPOSE
  notifies :run, "execute[restart weave]"
end

compose_path = "#{deploy_dir}/docker-compose.yml"
project_name = File.basename(deploy_dir)

execute "ensure weave running" do
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

execute "restart weave" do
  command "DOCKER_BUILDKIT=0 docker compose -f #{compose_path} up -d --build"
  user user
  action :nothing
end
