# frozen_string_literal: true
#
# node-exporter: Prometheus node_exporter v1.11.1 installed as a native
# systemd service. Linux-only; macOS hosts in Phase 4 may use a different
# collector (Phase 4 plan-time decision).
#
# Why direct download instead of mise / apt:
#   - `mise registry node_exporter` returns MISS (verified 2026-05-06)
#   - Debian apt ships an older 1.6.x; Phase 2 fleet observability needs
#     >=1.7 for textfile collector reliability we rely on
#
# What this cookbook installs:
#   - /usr/local/bin/node_exporter (1.11.1, sha256-verified)
#   - /var/lib/node_exporter/textfile/ (writable by root for orchestrator
#     output and other auto-mitamae-target metric drops)
#   - /etc/systemd/system/node-exporter.service (User=root so textfile dir
#     stays writable for the auto-mitamae sibling cookbooks)
#
# References for the asset URL + hash:
#   gh api repos/prometheus/node_exporter/releases/tags/v1.11.1 --jq '.assets[].name'
#   curl -fsSL https://github.com/prometheus/node_exporter/releases/download/v1.11.1/sha256sums.txt
#
# OS gate now lives at the include site (roles/lxc-core, Linux-only).

NODE_EXPORTER_VERSION = "1.11.1"
NODE_EXPORTER_BINARY  = "/usr/local/bin/node_exporter"
NODE_EXPORTER_TEXTFILE_DIR = "/var/lib/node_exporter/textfile"

# Asset is published only as linux-amd64 archive. Extend with arch detection
# if/when an arm64 host enters the fleet.
node_exporter_archive_name = "node_exporter-#{NODE_EXPORTER_VERSION}.linux-amd64.tar.gz"
node_exporter_archive_path = "#{node[:setup][:root]}/node-exporter/#{node_exporter_archive_name}"
node_exporter_url = "https://github.com/prometheus/node_exporter/releases/download/" \
                    "v#{NODE_EXPORTER_VERSION}/#{node_exporter_archive_name}"
node_exporter_sha256 = "9f5ea48e5bc7b656f8a91a32e7d7deb89f70f73dabd0d974418aca15f37d6810"

# Defensive: ensure setup_root exists before we drop the staging directory.
# Per CLAUDE.md "Defensive directory resource" rule — fresh PVE-LXC bootstraps
# call this cookbook before any sibling cookbook has created node[:setup][:root].
directory node[:setup][:root] do
  mode "755"
end

directory "#{node[:setup][:root]}/node-exporter" do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
end

# Idempotency check: skip download/extract/install if the binary on disk is
# already the right version. node_exporter --version writes to stderr.
binary_version_check = "test -x #{NODE_EXPORTER_BINARY} && " \
                       "#{NODE_EXPORTER_BINARY} --version 2>&1 | grep -q 'node_exporter, version #{NODE_EXPORTER_VERSION}'"

execute "download node_exporter v#{NODE_EXPORTER_VERSION}" do
  command "curl -fsSL -o #{node_exporter_archive_path} #{node_exporter_url}"
  user node[:setup][:user]
  not_if binary_version_check
end

execute "verify node_exporter sha256" do
  command "echo '#{node_exporter_sha256}  #{node_exporter_archive_path}' | sha256sum -c -"
  user node[:setup][:user]
  not_if binary_version_check
end

execute "extract + install node_exporter binary" do
  command <<~SH
    set -e
    cd #{node[:setup][:root]}/node-exporter
    tar -xzf #{node_exporter_archive_name}
    sudo install -m 755 -o root -g root \
      node_exporter-#{NODE_EXPORTER_VERSION}.linux-amd64/node_exporter #{NODE_EXPORTER_BINARY}
    rm -rf node_exporter-#{NODE_EXPORTER_VERSION}.linux-amd64
  SH
  user node[:setup][:user]
  not_if binary_version_check
end

# Textfile collector directory. Owned by root (User=root in the unit) so that
# other cookbooks running under root (auto-mitamae-orchestrator in Phase 2b,
# auto-mitamae runner output in Phase 1 deprecation) can drop .prom files
# without permission gymnastics.
#
# Use `execute "sudo install -d"` rather than mitamae's `directory` resource
# because mitamae's mruby fork does NOT propagate the `:user` attribute
# through `run_specinfra(:change_file_owner, ...)` to a `sudo -u <user>`
# wrapping (PR #180 attempted this and reproduced the EPERM at apply time
# despite passing dry-run). On lxc-pro-dev mitamae runs as `shin1ohno`,
# so the bare `chown root:root` issued by the directory resource fails
# with EPERM. The `sudo install -d` pattern mirrors lxc-pro-router's
# system-file pattern (cookbooks/lxc-pro-router/default.rb:35).
execute "create /var/lib/node_exporter as root" do
  command "sudo install -d -m 0755 -o root -g root /var/lib/node_exporter"
  not_if "test -d /var/lib/node_exporter && " \
         "test \"$(stat -c '%U:%G:%a' /var/lib/node_exporter)\" = 'root:root:755'"
end

execute "create #{NODE_EXPORTER_TEXTFILE_DIR} as root" do
  command "sudo install -d -m 0755 -o root -g root #{NODE_EXPORTER_TEXTFILE_DIR}"
  not_if "test -d #{NODE_EXPORTER_TEXTFILE_DIR} && " \
         "test \"$(stat -c '%U:%G:%a' #{NODE_EXPORTER_TEXTFILE_DIR})\" = 'root:root:755'"
end

# Stage + install the systemd unit. The pattern mirrors lxc-pro-router's unit
# install: stage in user space, install via sudo, daemon-reload + enable on
# change.
unit_staging_path = "#{node[:setup][:root]}/node-exporter/node-exporter.service"
unit_system_path  = "/etc/systemd/system/node-exporter.service"

remote_file unit_staging_path do
  source "files/node-exporter.service"
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "644"
end

execute "install node-exporter.service" do
  command "sudo install -m 644 -o root -g root #{unit_staging_path} #{unit_system_path}"
  not_if "diff -q #{unit_staging_path} #{unit_system_path} 2>/dev/null"
  notifies :run, "execute[node-exporter daemon-reload + enable]"
end

execute "node-exporter daemon-reload + enable" do
  command "sudo systemctl daemon-reload && sudo systemctl enable --now node-exporter.service"
  action :nothing
end
