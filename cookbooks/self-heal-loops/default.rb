# frozen_string_literal: true
#
# self-heal-loops — headless cron runners for the self-heal create/resolve
# loops on pro-dev (CT 104). Persists the two loops that were previously only
# runnable as interactive `/loop` sessions: a root /etc/cron.d entry invokes
# each wrapper via `runuser -l <user>` so the loop runs as the interactive
# workstation user (whose ~/.claude/.credentials.json, ~/.config/gh, ~/.aws,
# ~/.ssh, and mise env the headless `claude -p` needs).
#
# pro-dev ONLY: this is the one host with valid interactive claude creds + gh
# repo scope + fleet reach. Guarded on hostname; a no-op everywhere else.
#
# Why root cron.d + runuser (not a systemd user timer): auto-mitamae applies
# pro-dev as root, so /etc/cron.d (root-owned) matches the apply context and
# `runuser -l` supplies the full user login env. Mirrors the fleet cron.d
# convention (auto-mitamae-orchestrator, self-heal-observer).
#
# IMPORTANT: node[:setup][:home]/[:user] resolve from ENV (= /root + root under
# an auto-mitamae root apply), so they MUST NOT be used to locate the loop
# user's creds. The loop user is set EXPLICITLY (node[:self_heal_loops][:user],
# default shin1ohno) and the home is resolved via getent.
#
# See docs/self-heal-github-issues-plan.md + ~/self-heal-observability-loop-design.md.

return if node[:platform] == "darwin"

detected_hostname = run_command("hostname -s", error: false).stdout.strip
unless detected_hostname == "pro-dev"
  MItamae.logger.warn(
    "self-heal-loops: host '#{detected_hostname}' is not pro-dev — skipping " \
    "(the self-heal loops only run where interactive claude creds + gh repo " \
    "scope + fleet reach live).",
  )
  return
end

loop_user = (node[:self_heal_loops] && node[:self_heal_loops][:user]) || "shin1ohno"

# Resolve the loop user's home from getent (NOT node[:setup][:home], which is
# /root under an auto-mitamae root apply).
passwd_line = run_command("getent passwd #{loop_user}", error: false).stdout.strip
loop_home = passwd_line.empty? ? "/home/#{loop_user}" : passwd_line.split(":")[5]
loop_home = "/home/#{loop_user}" if loop_home.nil? || loop_home.empty?

staging_dir = "#{node[:setup][:root]}/self-heal-loops"

# Defensive dirs (per ~/.claude/rules/ruby.md). Staging lives under setup_root
# (root-owned under auto-mitamae); logs live under the loop user's ~/.claude.
directory node[:setup][:root] do
  mode "755"
end

directory staging_dir do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
end

# ~/.claude already exists (holds .credentials.json); only ensure the logs
# subdir, owned by the loop user so runuser-spawned wrappers can write it.
directory "#{loop_home}/.claude/logs" do
  owner loop_user
  group loop_user
  mode "755"
  only_if "test -d #{loop_home}/.claude"
end

# Ensure the two self-heal skills the cron invokes are present in the LOOP
# USER's ~/.claude/skills. The claude-code cookbook deploys skills to
# node[:setup][:home]/.claude/skills — which is /root under an auto-mitamae root
# apply, NOT the loop user's home the shin1ohno cron reads. Sync them here
# (single source of truth stays cookbooks/claude-code/files/skills) so the loops
# work regardless of how claude-code was applied.
skills_src = File.expand_path("../claude-code/files/skills", File.dirname(__FILE__))

%w[self-heal-create self-heal-resolve].each do |skill|
  directory "#{loop_home}/.claude/skills/#{skill}" do
    owner loop_user
    group loop_user
    mode "755"
    only_if "test -d #{loop_home}/.claude"
  end
end

execute "sync self-heal skills into #{loop_user} ~/.claude/skills" do
  command <<~SH.strip
    set -e
    for s in self-heal-create self-heal-resolve; do
      cp #{skills_src}/$s/SKILL.md #{loop_home}/.claude/skills/$s/SKILL.md
      chown #{loop_user}:#{loop_user} #{loop_home}/.claude/skills/$s/SKILL.md
    done
  SH
  user node[:setup][:user]
  only_if "test -d #{loop_home}/.claude"
  not_if "diff -q #{skills_src}/self-heal-create/SKILL.md #{loop_home}/.claude/skills/self-heal-create/SKILL.md 2>/dev/null && " \
         "diff -q #{skills_src}/self-heal-resolve/SKILL.md #{loop_home}/.claude/skills/self-heal-resolve/SKILL.md 2>/dev/null"
end

# Stage + install the scripts to /usr/local/bin (root:root 0755): the two cron
# wrappers + the pure-shell create logic (self-heal-create.sh) + the sourced
# liveness-metric helper (self-heal-metric.sh) both wrappers load + the
# observation helper (self-heal-probe.sh) the resolve SKILL calls for
# connect-classification / sleep-vs-wedge diagnosis + the class C' remediation
# executor (self-heal-remediate.sh) that runs ONLY allowlisted known-safe kicks +
# the Phase 3B infra-resize executor (self-heal-infra-apply.sh) — the ONLY holder
# of the terraform apply verb, fail-closed + least-priv (pve-resize) only.
%w[self-heal-create.sh self-heal-create-run.sh self-heal-resolve-run.sh self-heal-metric.sh self-heal-probe.sh self-heal-remediate.sh self-heal-infra-apply.sh].each do |wrapper|
  remote_file "#{staging_dir}/#{wrapper}" do
    source "files/#{wrapper}"
    owner node[:setup][:user]
    group node[:setup][:group]
    mode "0755"
  end

  execute "install #{wrapper} to /usr/local/bin" do
    command "sudo install -m 0755 -o root -g root " \
            "#{staging_dir}/#{wrapper} /usr/local/bin/#{wrapper}"
    not_if "diff -q #{staging_dir}/#{wrapper} /usr/local/bin/#{wrapper} 2>/dev/null"
  end
end

# Install the class C' remediation allowlist (DATA, 0644 root:root) to a stable
# path self-heal-remediate.sh reads. The helper executes an entry's
# recovery_command only on an exact (host, service) match here — the fence that
# keeps the loop from running an arbitrary command. Grown only via PR review.
remote_file "#{staging_dir}/remediation-allowlist.json" do
  source "files/remediation-allowlist.json"
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "0644"
end

execute "install remediation-allowlist.json" do
  command "sudo install -d -m 0755 -o root -g root /usr/local/share/self-heal && " \
          "sudo install -m 0644 -o root -g root " \
          "#{staging_dir}/remediation-allowlist.json /usr/local/share/self-heal/remediation-allowlist.json"
  not_if "diff -q #{staging_dir}/remediation-allowlist.json /usr/local/share/self-heal/remediation-allowlist.json 2>/dev/null"
end

# Install the Phase 3B infra-resize allowlist (DATA, 0644). Empty by default =
# fail-closed (nothing auto-resizes until an owner adds a CT via PR). Read by
# self-heal-infra-apply.sh, which additionally enforces increase-only / floor /
# ceiling / daily-budget / least-priv identity / a fail-closed plan-JSON gate.
remote_file "#{staging_dir}/infra-resize-allowlist.json" do
  source "files/infra-resize-allowlist.json"
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "0644"
end

execute "install infra-resize-allowlist.json" do
  command "sudo install -d -m 0755 -o root -g root /usr/local/share/self-heal && " \
          "sudo install -m 0644 -o root -g root " \
          "#{staging_dir}/infra-resize-allowlist.json /usr/local/share/self-heal/infra-resize-allowlist.json"
  not_if "diff -q #{staging_dir}/infra-resize-allowlist.json /usr/local/share/self-heal/infra-resize-allowlist.json 2>/dev/null"
end

# Pin the PVE root CA (PUBLIC cert, not a key) so self-heal-infra-apply.sh
# verifies the PVE API TLS cert (--cacert) instead of `-k`. The PVE cert's SAN
# includes the LAN IP, so verification works by IP. Without this file the wrapper
# fails closed on TLS (unless SELF_HEAL_ALLOW_INSECURE_PVE=1 is explicitly set).
remote_file "#{staging_dir}/pve-ca.pem" do
  source "files/pve-ca.pem"
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "0644"
end

execute "install pve-ca.pem" do
  command "sudo install -d -m 0755 -o root -g root /etc/self-heal && " \
          "sudo install -m 0644 -o root -g root " \
          "#{staging_dir}/pve-ca.pem /etc/self-heal/pve-ca.pem"
  not_if "diff -q #{staging_dir}/pve-ca.pem /etc/self-heal/pve-ca.pem 2>/dev/null"
end

# Pre-create the two loop liveness .prom files OWNED BY THE LOOP USER inside the
# root-owned node_exporter textfile dir. The wrappers run as the loop user
# (runuser -l) and rewrite these files in place (single printf redirection); they
# own the FILE so they need no write access to the DIR — which stays root:root
# and is (re-)ensured by the node-exporter cookbook included later via lxc_entry.
# This avoids relaxing the shared textfile dir's perms (no ordering conflict with
# node-exporter). `install /dev/null` only runs on first apply (the not_if
# short-circuits once the files are loop-user-owned), so it never truncates a
# live metric on steady-state applies.
textfile_dir = "/var/lib/node_exporter/textfile"
%w[self-heal-create self-heal-resolve].each do |loop|
  prom = "#{textfile_dir}/#{loop}.prom"
  execute "seed #{loop} liveness metric file (loop-user owned)" do
    command "sudo install -d -m 0755 -o root -g root #{textfile_dir} && " \
            "sudo install -m 0644 -o #{loop_user} -g #{loop_user} /dev/null #{prom}"
    not_if "test \"$(stat -c '%U' #{prom} 2>/dev/null)\" = \"#{loop_user}\""
  end
end

# cron.d — high-frequency to minimise downtime. create every 2 min (matches the
# observer cadence — it cannot surface what the observer has not yet written, so
# 2 min is the practical floor), resolve every 5 min. Per-loop flock makes an
# over-scheduled tick a clean no-op when the previous run is still going (or a
# fix PR is mid-flight, caught by the resolve dup-guard), so the only cost of
# the high frequency is extra claude sessions, not pile-up. runuser -l gives
# each wrapper the loop user's full login env.
cron_content = <<~CRON
  # Managed by cookbooks/self-heal-loops. Do not edit.
  PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
  MAILTO=""

  */2 * * * *  root  runuser -l #{loop_user} -c '/usr/local/bin/self-heal-create-run.sh'
  */5 * * * *  root  runuser -l #{loop_user} -c '/usr/local/bin/self-heal-resolve-run.sh'
CRON

file "#{staging_dir}/self-heal-loops.cron" do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "0644"
  content cron_content
end

execute "install self-heal-loops cron.d" do
  command "sudo install -m 0644 -o root -g root " \
          "#{staging_dir}/self-heal-loops.cron /etc/cron.d/self-heal-loops"
  not_if "diff -q #{staging_dir}/self-heal-loops.cron /etc/cron.d/self-heal-loops 2>/dev/null"
end
