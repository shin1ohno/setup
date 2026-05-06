# frozen_string_literal: true
#
# Auto-mitamae: drops a systemd timer that pulls origin/main and re-applies
# the host's role file every 15 minutes. Phase 1 scope is the LXC / PVE-host
# track only — root system timer, journald logging, no dashboard POST yet.
#
# The caller (e.g. pve/lxc-weave.rb) MUST set:
#   node[:auto_mitamae][:role_file] = "pve/lxc-<name>.rb"
#   node[:auto_mitamae][:setup_dir] = "/root/setup"   # git checkout root
#
# Future phases extend this cookbook with a user-mode systemd unit (pro-dev),
# a launchd LaunchAgent (macOS), and dashboard POST integration. See
# ~/.claude/plans/valiant-sniffing-yao.md.

raise "auto_mitamae.role_file must be set by the caller" unless node[:auto_mitamae][:role_file]
raise "auto_mitamae.setup_dir must be set by the caller" unless node[:auto_mitamae][:setup_dir]

role_file = node[:auto_mitamae][:role_file]
setup_dir = node[:auto_mitamae][:setup_dir]
setup_root = node[:setup][:root]
cookbook_dir = "#{setup_root}/auto-mitamae"

# 1. Ensure parent setup_root + per-cookbook subdirectory exist. Other
# cookbooks (lxc-pro-router etc.) drop files directly under setup_root
# and assume an earlier cookbook in the chain already created it; PVE
# LXCs that bootstrap straight from `apt install … && git clone … && bin/setup
# && bin/mitamae local pve/lxc-*.rb` do NOT yet have it on first run.
# Be defensive. The per-cookbook subdirectory follows the awscli /
# eternal-terminal convention.
directory setup_root do
  mode "755"
end

directory cookbook_dir do
  mode "755"
end

# 2. Stage the runner script (chmod 755 needs no sudo since we're under
# setup_root, owned by the user running mitamae).
remote_file "#{cookbook_dir}/auto-mitamae.sh" do
  source "files/auto-mitamae.sh"
  mode "755"
end

# 3. Stage the systemd unit files. Inline `content` is preferred over a
# `files/` template because per-host substitution is trivial — matches
# the s3-backup cookbook pattern.
file "#{cookbook_dir}/auto-mitamae.service" do
  mode "644"
  content <<~SERVICE
    [Unit]
    Description=Auto-mitamae fleet apply (#{role_file})
    Documentation=https://github.com/shin1ohno/setup
    After=network-online.target
    Wants=network-online.target

    [Service]
    Type=oneshot
    # systemd PID 1 spawns services with HOME unset; mitamae cookbooks use
    # ENV["HOME"] for path resolution, so pin it explicitly here. Belt-and-
    # suspenders with auto-mitamae.sh's getent-based HOME fallback.
    Environment=HOME=#{node[:setup][:home]}
    Environment=SETUP_DIR=#{setup_dir}
    Environment=ROLE_FILE=#{role_file}
    ExecStart=#{cookbook_dir}/auto-mitamae.sh
    StandardOutput=journal
    StandardError=journal
    # Hardening: deny new privileges and use a private /tmp. mitamae itself
    # writes outside /tmp, so PrivateTmp is fine.
    NoNewPrivileges=yes
    PrivateTmp=yes

    [Install]
    WantedBy=multi-user.target
  SERVICE
end

file "#{cookbook_dir}/auto-mitamae.timer" do
  mode "644"
  content <<~TIMER
    [Unit]
    Description=Periodic auto-mitamae fleet apply (every 15 min)

    [Timer]
    # Fire 15 min past every quarter-hour boundary, with up to 3 min jitter
    # so 7+ LXCs don't all hit the GitHub API simultaneously.
    OnCalendar=*:0/15
    RandomizedDelaySec=180
    # Catch up if the host was off when a fire was scheduled.
    Persistent=true

    [Install]
    WantedBy=timers.target
  TIMER
end

# 4. Install service + timer into /etc/systemd/system/ via sudo. The
# `not_if "diff -q ..."` makes this idempotent — re-applies of mitamae
# do not re-trigger daemon-reload unless the staged file actually
# differs from the deployed one. Pattern copied from cookbooks/lxc-pro-router.
execute "install auto-mitamae.service" do
  command "sudo install -m 644 -o root -g root " \
          "#{cookbook_dir}/auto-mitamae.service /etc/systemd/system/auto-mitamae.service"
  not_if "diff -q #{cookbook_dir}/auto-mitamae.service /etc/systemd/system/auto-mitamae.service 2>/dev/null"
  notifies :run, "execute[auto-mitamae daemon-reload + enable]"
end

execute "install auto-mitamae.timer" do
  command "sudo install -m 644 -o root -g root " \
          "#{cookbook_dir}/auto-mitamae.timer /etc/systemd/system/auto-mitamae.timer"
  not_if "diff -q #{cookbook_dir}/auto-mitamae.timer /etc/systemd/system/auto-mitamae.timer 2>/dev/null"
  notifies :run, "execute[auto-mitamae daemon-reload + enable]"
end

execute "auto-mitamae daemon-reload + enable" do
  command "sudo systemctl daemon-reload && sudo systemctl enable --now auto-mitamae.timer"
  action :nothing
end
