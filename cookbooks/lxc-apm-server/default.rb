# frozen_string_literal: true
#
# lxc-apm-server (CT 116): standalone Elastic APM Server 8.x for OTLP
# ingestion. Receives traces / metrics / logs from 5 home-fleet services
# (weave-server, edge-agent, roon-mcp, cognee-auth-proxy,
# ai-memory-auth-proxy) on :8200, writes traces-apm-* / logs-apm-* /
# metrics-apm-* data streams to the 3-node ES cluster.
#
# Stack:
#   - apm-server 8.16.0 DEB (apt-mark hold)  :8200 (LAN-IP-bound)
#   - systemd unit apm-server.service (DEB-shipped)
#   - /etc/systemd/system/apm-server.service.d/override.conf (cookbook-managed)
#
# Adversarial findings folded in (scalable-noodling-pearl plan):
#   #8  /etc/hosts entries for apm-server.home.local — DNS-independent
#       startup
#   #9  TLS cert SAN already covers apm-server.home.local + LAN IP +
#       localhost (Terraform-managed cert in home-monitor)
#   #10 Bind :8200 to LAN IP, not 0.0.0.0 — Tailscale peers excluded
#
# Migration: this is a greenfield service on a brand-new CT, no docker
# legacy to clean up.

return if node[:platform] == "darwin"

include_cookbook "awscli"

ssh_keys_config = JSON.parse(File.read(File.join(File.dirname(__FILE__), "..", "ssh-keys", "files", "aws-config.json")))
aws_profile = ssh_keys_config["aws_profile"]
aws_region  = ssh_keys_config["aws_region"]

user      = node[:setup][:user]
group     = node[:setup][:group]
lan_ip    = "192.168.1.81"  # devices.json apm-server entry

# Defensive directories.
directory node[:setup][:root] do
  mode "755"
end

directory "#{node[:setup][:root]}/lxc-apm-server" do
  owner user
  group group
  mode "755"
end

files_dir = "#{node[:setup][:root]}/lxc-apm-server/files"
directory files_dir do
  owner user
  group group
  mode "755"
end

# === /etc/hosts entry (adversarial #8 — DNS-independent startup) ===
# Without this, a fresh apm-server boot before LAN DNS is reachable
# would fail to resolve es-{0,1,2}.home.local for the ES output. The
# entries below are the canonical set the cookbook fleet uses; matches
# lxc-elasticsearch / lxc-kibana to keep behavior uniform.
[
  ["192.168.1.77", "es-0.home.local es-0"],
  ["192.168.1.78", "es-1.home.local es-1"],
  ["192.168.1.79", "es-2.home.local es-2"],
  ["192.168.1.80", "kibana.home.local kibana"],
  ["192.168.1.81", "apm-server.home.local apm-server"],
].each do |ip, hostnames|
  execute "ensure /etc/hosts: #{hostnames.split.first}" do
    command "echo '#{ip} #{hostnames}' >> /etc/hosts"
    not_if "grep -qE '^#{Regexp.escape(ip)}[[:space:]]' /etc/hosts"
  end
end

# === Elastic apt repo registration ===

execute "install elastic apt prerequisites" do
  command "apt-get install -y ca-certificates curl gnupg apt-transport-https"
  not_if {
    %w(ca-certificates curl gnupg apt-transport-https).all? { |pkg|
      run_command("dpkg-query -W -f='${Status}' #{pkg} 2>/dev/null | grep -q 'install ok installed'", error: false).exit_status == 0
    }
  }
end

execute "add elastic apt key" do
  command <<~SH.strip
    install -d -m 0755 /etc/apt/keyrings && \
      curl -fsSL https://artifacts.elastic.co/GPG-KEY-elasticsearch | \
      gpg --batch --yes --dearmor -o /etc/apt/keyrings/elastic.gpg && \
      chmod a+r /etc/apt/keyrings/elastic.gpg
  SH
  not_if { File.exist?("/etc/apt/keyrings/elastic.gpg") }
end

execute "add elastic apt repo" do
  command "echo 'deb [signed-by=/etc/apt/keyrings/elastic.gpg] " \
          "https://artifacts.elastic.co/packages/8.x/apt stable main' " \
          "> /etc/apt/sources.list.d/elastic-8.x.list"
  not_if "test -f /etc/apt/sources.list.d/elastic-8.x.list && " \
         "grep -q 'artifacts.elastic.co' /etc/apt/sources.list.d/elastic-8.x.list"
  notifies :run, "execute[apt-get update for elastic]", :immediately
end

execute "apt-get update for elastic" do
  command "apt-get update -qq"
  action :nothing
end

# === Install apm-server DEB ===

execute "install apm-server 8.16.0" do
  command "apt-get install -y apm-server=8.16.0"
  not_if "dpkg-query -W -f='${Version}' apm-server 2>/dev/null | grep -q '^8.16.0$'"
end

execute "apt-mark hold apm-server" do
  command "apt-mark hold apm-server"
  not_if "apt-mark showhold | grep -q '^apm-server$'"
end

# === Cert directory ===

directory "/etc/apm-server/certs" do
  owner "root"
  group "apm-server"
  mode "750"
end

# === apm-server.yml template ===

apm_yml_staging = "#{files_dir}/apm-server.yml"
apm_yml_path    = "/etc/apm-server/apm-server.yml"

# Render template with sed substitution (mirrors lxc-elasticsearch /
# lxc-monitoring pattern). LAN_IP is the only placeholder.
remote_file "#{files_dir}/apm-server.yml.tmpl" do
  source "files/apm-server.yml.tmpl"
  owner user
  group group
  mode "644"
end

execute "render apm-server.yml" do
  command "sed -e 's|@@LAN_IP@@|#{lan_ip}|g' " \
          "#{files_dir}/apm-server.yml.tmpl > #{apm_yml_staging}"
  not_if "test -f #{apm_yml_staging} && " \
         "diff -q <(sed -e 's|@@LAN_IP@@|#{lan_ip}|g' " \
         "#{files_dir}/apm-server.yml.tmpl) #{apm_yml_staging} >/dev/null 2>&1"
end

execute "install apm-server.yml" do
  command "install -m 0640 -o root -g apm-server #{apm_yml_staging} #{apm_yml_path}"
  only_if "test -f #{apm_yml_staging}"
  # not_if must check BOTH content AND ownership/mode — a content-only
  # check skips install when content matches an older PR's wrong owner
  # (e.g. PR #318 left files root:root, PR #320 needed to fix to
  # root:apm-server but `diff -q` was true so install was skipped and
  # owner stayed root:root, crashing apm-server with "permission denied").
  not_if "test -f #{apm_yml_path} && " \
         "diff -q #{apm_yml_staging} #{apm_yml_path} >/dev/null 2>&1 && " \
         "test \"$(stat -c '%U:%G:%a' #{apm_yml_path})\" = 'root:apm-server:640'"
  notifies :run, "execute[restart apm-server]"
end

# === systemd override ===

unit_override_staging = "#{files_dir}/apm-server.service.override.conf"

remote_file unit_override_staging do
  source "files/apm-server.service.override.conf"
  owner user
  group group
  mode "644"
  notifies :run, "execute[apm-server daemon-reload]"
end

execute "create apm-server.service.d directory" do
  command "install -d -m 0755 -o root -g root /etc/systemd/system/apm-server.service.d"
  not_if "test -d /etc/systemd/system/apm-server.service.d"
end

execute "install apm-server systemd override" do
  command "install -m 0644 -o root -g root #{unit_override_staging} " \
          "/etc/systemd/system/apm-server.service.d/override.conf"
  only_if "test -f #{unit_override_staging}"
  not_if "test -f /etc/systemd/system/apm-server.service.d/override.conf && " \
         "diff -q #{unit_override_staging} /etc/systemd/system/apm-server.service.d/override.conf 2>/dev/null"
  notifies :run, "execute[apm-server daemon-reload]"
  notifies :run, "execute[restart apm-server]"
end

execute "apm-server daemon-reload" do
  command "systemctl daemon-reload"
  action :nothing
end

# === SSM-gated env + TLS cert generation ===

generated_dir = "#{node[:setup][:root]}/generated"
directory generated_dir do
  owner user
  group group
  mode "755"
end

env_temp_path   = "#{generated_dir}/apm-server.env"
env_output_path = "/etc/apm-server/apm-server-secrets.env"
generate_env_script = File.join(File.dirname(__FILE__), "files", "generate_env.sh")
fetch_certs_script  = File.join(File.dirname(__FILE__), "files", "fetch_certs.sh")
certs_staging_dir   = "#{generated_dir}/apm-server-certs"

require_external_auth(
  tool_name: "AWS CLI (profile=#{aws_profile}, region=#{aws_region}) for /monitoring/{apm,elastic}/* SSM params",
  check_command: "aws ssm get-parameter --name /monitoring/elastic/apm-server-password " \
                 "--with-decryption --profile #{aws_profile} --region #{aws_region} " \
                 "> /dev/null 2>&1",
  instructions: "Configure '#{aws_profile}' with ssm:GetParameter on " \
                "/monitoring/elastic/* + /monitoring/apm/* in #{aws_region}. " \
                "On a fresh machine: aws configure --profile #{aws_profile}. Then press Enter.",
  # Skip when keystore is loaded with the password key AND certs are
  # already in place. Keystore CLI exits success only if the named key
  # exists, so the grep on `keystore list` is the canonical probe.
  skip_if: -> {
    File.exist?("/var/lib/apm-server/apm-server.keystore") &&
      File.exist?("/etc/apm-server/certs/server.crt") &&
      File.exist?("/etc/apm-server/certs/server.key") &&
      File.exist?("/etc/apm-server/certs/ca.crt") &&
      system("apm-server keystore list 2>/dev/null | grep -q '^APM_SERVER_PASSWORD$'")
  },
) do
  execute "generate apm-server secrets env" do
    command "AWS_PROFILE=#{aws_profile} AWS_REGION=#{aws_region} " \
            "bash #{generate_env_script} #{env_temp_path}"
    user user
  end

  execute "fetch apm-server TLS certs" do
    command "AWS_PROFILE=#{aws_profile} AWS_REGION=#{aws_region} " \
            "bash #{fetch_certs_script} #{certs_staging_dir}"
    user user
  end
end

# === apm-server keystore — password injection ===
#
# Switched away from EnvironmentFile + YAML `${VAR}` substitution (PR
# #318 / #320 approach) because the Terraform-generated random_password
# can contain YAML-significant characters (~, &, <, ,) that apm-server's
# libbeat parses as YAML structure after substitution — producing
# "can not convert 'object' into 'string' accessing
# output.elasticsearch.password" even with the value double-quoted in
# the template. Keystore-resolved values are inserted post-parse so
# quoting / chars are irrelevant.
#
# Keystore file: /var/lib/apm-server/apm-server.keystore (DEB default).
# Owned root:apm-server 0640 — the apm-server runtime user reads it at
# startup.

execute "initialize apm-server keystore" do
  command "apm-server keystore create --force"
  not_if "test -f /var/lib/apm-server/apm-server.keystore"
end

# Re-add the password whenever the staging env file exists (i.e. on
# the apply cycle right after require_external_auth ran). --force makes
# `keystore add` overwrite cleanly. We cannot probe the keystore value
# (CLI lists keys only), so we re-add only when env_temp_path is
# present — the require_external_auth skip_if above already gates that.
execute "add APM_SERVER_PASSWORD to keystore" do
  command "grep ^APM_SERVER_PASSWORD= #{env_temp_path} | cut -d= -f2- | " \
          "apm-server keystore add APM_SERVER_PASSWORD --stdin --force"
  only_if "test -f #{env_temp_path}"
  notifies :run, "execute[chown apm-server keystore]"
  notifies :run, "execute[restart apm-server]"
end

# apm-server strict-perms requires the keystore to be owned by the
# runtime user with mode 0600 (no group read) — `root:apm-server 0640`
# triggers "permission too open" at startup. Chown to
# `apm-server:apm-server 0600` after each `keystore add`.
execute "chown apm-server keystore" do
  command "chown apm-server:apm-server /var/lib/apm-server/apm-server.keystore && " \
          "chmod 0600 /var/lib/apm-server/apm-server.keystore"
  only_if "test -f /var/lib/apm-server/apm-server.keystore"
  not_if "test \"$(stat -c '%U:%G %a' /var/lib/apm-server/apm-server.keystore 2>/dev/null)\" = 'apm-server:apm-server 600'"
end

# Delete the staged env file now that the password is in the keystore.
file env_temp_path do
  action :delete
  only_if "test -f #{env_temp_path}"
end

# Install TLS certs. Owned root:apm-server (Debian apt package installs
# the unit with User=apm-server, so apm-server group must read these).
# server.crt / ca.crt 0640, server.key 0640 (group-read needed for the
# apm-server runtime user).
# Cert installs use the same content+ownership not_if pattern as
# apm-server.yml above — see comment there for the rationale.
execute "install apm-server TLS cert" do
  command "install -m 0640 -o root -g apm-server #{certs_staging_dir}/server.crt " \
          "/etc/apm-server/certs/server.crt"
  only_if "test -f #{certs_staging_dir}/server.crt"
  not_if "test -f /etc/apm-server/certs/server.crt && " \
         "diff -q #{certs_staging_dir}/server.crt /etc/apm-server/certs/server.crt >/dev/null 2>&1 && " \
         "test \"$(stat -c '%U:%G:%a' /etc/apm-server/certs/server.crt)\" = 'root:apm-server:640'"
  notifies :run, "execute[restart apm-server]"
end

execute "install apm-server TLS key" do
  command "install -m 0640 -o root -g apm-server #{certs_staging_dir}/server.key " \
          "/etc/apm-server/certs/server.key"
  only_if "test -f #{certs_staging_dir}/server.key"
  not_if "test -f /etc/apm-server/certs/server.key && " \
         "diff -q #{certs_staging_dir}/server.key /etc/apm-server/certs/server.key >/dev/null 2>&1 && " \
         "test \"$(stat -c '%U:%G:%a' /etc/apm-server/certs/server.key)\" = 'root:apm-server:640'"
  notifies :run, "execute[restart apm-server]"
end

execute "install apm-server CA cert" do
  command "install -m 0640 -o root -g apm-server #{certs_staging_dir}/ca.crt " \
          "/etc/apm-server/certs/ca.crt"
  only_if "test -f #{certs_staging_dir}/ca.crt"
  not_if "test -f /etc/apm-server/certs/ca.crt && " \
         "diff -q #{certs_staging_dir}/ca.crt /etc/apm-server/certs/ca.crt >/dev/null 2>&1 && " \
         "test \"$(stat -c '%U:%G:%a' /etc/apm-server/certs/ca.crt)\" = 'root:apm-server:640'"
  notifies :run, "execute[restart apm-server]"
end

execute "delete apm-server certs staging" do
  command "rm -rf #{certs_staging_dir}"
  only_if "test -d #{certs_staging_dir} && " \
          "test -f /etc/apm-server/certs/server.crt && " \
          "test -f /etc/apm-server/certs/server.key && " \
          "test -f /etc/apm-server/certs/ca.crt"
end

# === Service activation ===

execute "enable + start apm-server" do
  command "systemctl enable --now apm-server.service"
  only_if <<~SH.tr("\n", " ").strip
    test -f /var/lib/apm-server/apm-server.keystore || exit 1;
    test -f #{apm_yml_path} || exit 1;
    test -f /etc/apm-server/certs/server.crt || exit 1;
    systemctl is-enabled apm-server.service > /dev/null 2>&1 &&
    systemctl is-active apm-server.service > /dev/null 2>&1 && exit 1 || exit 0
  SH
end

execute "restart apm-server" do
  command "systemctl restart apm-server.service"
  action :nothing
  only_if "test -f /var/lib/apm-server/apm-server.keystore && test -f #{apm_yml_path} && " \
          "test -f /etc/apm-server/certs/server.crt"
end
