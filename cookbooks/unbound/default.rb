# frozen_string_literal: true
#
# cookbooks/unbound: LAN DNS resolver for the home network (CT 118 / 192.168.1.61).
# Replaces the RTX1210 forwarder, which does not serve TCP/53 — RFC 7766 TCP
# fallback on truncated (>512B) responses fails there, breaking Linux name
# resolution. unbound serves UDP+TCP and:
#   home.local              -> served LOCALLY from local-data rendered from SSM
#                              (/host-registry/home-local-records); unknown names
#                              fall through to VPC Route53 (10.33.128.2)
#   1.168.192.in-addr.arpa  -> VPC Route53 resolver (10.33.128.2)
#   everything else         -> Cloudflare DoT (1.1.1.1@853 / 1.0.0.1@853)
#
# Serving home.local locally removes the dependency on the (wedge-prone) VPC
# Route53 forward path and mirrors what the RTX rtx_dns_server "hosts" block did.

return if node[:platform] == "darwin"

staging_dir = "#{node[:setup][:root]}/unbound"

# AWS profile/region for the SSM fetch of home.local records. Reuse the
# bootstrap pair from cookbooks/ssh-keys (pve-bootstrap-ssm / ap-northeast-1) so
# the generator targets the same IAM principal the rest of the fleet uses for
# /host-registry/* reads (the existing /host-registry/* IAM grant covers it).
aws_config   = JSON.parse(File.read(File.join(File.dirname(__FILE__), "..", "ssh-keys", "files", "aws-config.json")))
aws_profile  = aws_config["aws_profile"]
aws_region   = aws_config["aws_region"]
ssm_param    = "/host-registry/home-local-records"
template_src = "#{staging_dir}/home-monitor.conf.tmpl"
rendered_cfg = "#{staging_dir}/home-monitor.conf"
gen_script   = "#{staging_dir}/generate-home-local.sh"

# Fresh Debian LXC: refresh apt index + TLS roots before installing unbound.
# jq is required by the home.local generator (generate-home-local.sh).
execute "apt-get update (unbound)" do
  command "sudo apt-get update -qq"
  not_if "dpkg -s unbound jq >/dev/null 2>&1"
end

execute "install unbound + ca-certificates + jq" do
  command "sudo apt-get install -y unbound ca-certificates jq && sudo update-ca-certificates"
  not_if "dpkg -s unbound jq >/dev/null 2>&1"
end

# systemd-resolved (if present) binds :53 and collides with unbound on 0.0.0.0:53.
execute "disable systemd-resolved (collides with unbound on :53)" do
  command "sudo systemctl disable --now systemd-resolved"
  only_if "systemctl is-active systemd-resolved >/dev/null 2>&1 || systemctl is-enabled systemd-resolved >/dev/null 2>&1"
end

# Defensive parent dirs (fresh LXC may not have setup_root yet).
# Per CLAUDE.md "Defensive directory resource" rule — fresh PVE-LXC bootstraps
# call this cookbook before any sibling cookbook has created node[:setup][:root].
directory node[:setup][:root] do
  mode "755"
end

directory staging_dir do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
end

# Stage the config template + the home.local local-data generator.
remote_file template_src do
  source "files/home-monitor.conf.tmpl"
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "0644"
end

remote_file gen_script do
  source "files/generate-home-local.sh"
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "0755"
end

# Render home-monitor.conf from the template: fetch the home.local A-record map
# from SSM (/host-registry/home-local-records, published by home-monitor
# Terraform) and splice local-zone/local-data entries at the marker, so unbound
# serves home.local LOCALLY (VPC-independent). Runs every apply; the install
# step below is gated by a content diff so an unchanged render is a no-op (no
# restart). On SSM failure the generator emits a WARN and renders home.local as
# forward-only — never an invalid config — so it is safe to run unconditionally
# without require_external_auth gating (which would skip under non-TTY apply and
# leave no rendered output).
execute "render unbound home-monitor.conf from SSM home.local records" do
  command "AWS_PROFILE=#{aws_profile} AWS_REGION=#{aws_region} " \
          "SSM_PARAM=#{ssm_param} " \
          "TEMPLATE=#{template_src} OUTPUT=#{rendered_cfg} " \
          "bash #{gen_script}"
  user node[:setup][:user]
end

execute "install /etc/unbound/unbound.conf.d/home-monitor.conf" do
  command "sudo install -m 644 -o root -g root " \
          "#{rendered_cfg} " \
          "/etc/unbound/unbound.conf.d/home-monitor.conf"
  not_if "diff -q #{rendered_cfg} /etc/unbound/unbound.conf.d/home-monitor.conf 2>/dev/null"
  notifies :run, "execute[validate + restart unbound]"
end

# Validate config BEFORE (re)starting — never restart on a broken config.
execute "validate + restart unbound" do
  command "sudo unbound-checkconf && sudo systemctl restart unbound"
  action :nothing
end

execute "enable unbound" do
  command "sudo systemctl enable unbound"
  not_if "systemctl is-enabled unbound >/dev/null 2>&1"
end

# Self-heal: start unbound if it is installed+enabled but not currently running
# (manual stop, crash, OOM). Mirrors node-exporter's `enable --now` posture so a
# re-run with an unchanged config still asserts the running state.
execute "ensure unbound running" do
  command "sudo systemctl start unbound"
  not_if "systemctl is-active --quiet unbound"
end
