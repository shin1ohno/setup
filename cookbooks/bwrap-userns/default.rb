# frozen_string_literal: true

# Restore bubblewrap's ability to create unprivileged user namespaces where
# Ubuntu's AppArmor hardening blocks it.
#
# Why: Ubuntu 24.04 ships kernel.apparmor_restrict_unprivileged_userns=1. An
# unconfined binary that creates an unprivileged user namespace is transitioned
# into /etc/apparmor.d/unprivileged_userns, which carries `audit deny
# capability`, so bwrap cannot write uid_map and aborts with
# "bwrap: setting up uid map: Permission denied".
#
# Codex CLI (roles/llm -> cookbooks/codex-cli) runs every sandboxed shell
# command through bwrap on Linux. Both -s read-only and -s workspace-write take
# that path, and the older landlock backend is incompatible with 0.8-era
# permission profiles (`use_linux_sandbox_bwrap` is gone from `codex features
# list`, `use_legacy_landlock` is deprecated and refuses workspace-write), so on
# an affected host EVERY Codex exec fails and the only way to run the agent is
# `-s danger-full-access` — i.e. with no sandbox at all. Measured on sh1-cloud
# 2026-08-05: three of three agents reported `bwrap: setting up uid map:
# Permission denied` for `herdr --version`, `sed`, and `touch` alike.
#
# Two halves are needed. Codex prefers a system bwrap on PATH over its bundled
# copy ("no system bwrap was found on PATH and no bundled
# codex-resources/bwrap binary was found next to the Codex executable" is its
# own error string), so the package supplies a stable /usr/bin/bwrap; and the
# profile in files/ grants userns to exactly that path. Ubuntu's bubblewrap
# package ships no profile of its own — verified by downloading the .deb and
# listing it: /usr/bin/bwrap and nothing else.
#
# Self-gating: both resources are no-ops where the restriction is absent (older
# kernels, non-Ubuntu distributions), so this cookbook is safe on any Linux host
# and does nothing on one that never had the problem.
#
# Linux-only: cookbooks/bwrap-userns/platform marks it, so a cross-OS include
# raises at the include layer instead of silently declaring no resources. macOS
# Codex sandboxes with seatbelt and never touches bwrap.

install_package "bubblewrap" do
  ubuntu "bubblewrap"
  arch   "bubblewrap"
end

profile_src = File.expand_path("../files/bwrap-userns", __FILE__)
profile_dst = "/etc/apparmor.d/bwrap-userns"
restrict_sysctl = "/proc/sys/kernel/apparmor_restrict_unprivileged_userns"

# Proc-form guards throughout: a string guard on a resource carrying
# `user node[:setup][:system_user]` is wrapped in `sudo -u root` and silently
# exits non-zero on these hosts, defeating the check (same trap documented in
# cookbooks/arp-flux and the install_package helper).
restricted = lambda {
  run_command("test -r #{restrict_sysctl}", error: false).exit_status == 0 &&
    run_command("cat #{restrict_sysctl}", error: false).stdout.strip == "1"
}

# /etc/apparmor.d is 0755 and its profiles are 0644 root:root, so the content
# comparison needs no privilege — unlike the 0440 sudoers case, a plain diff is
# a valid guard here.
execute "install bwrap userns apparmor profile" do
  command <<~BASH
    cp #{profile_src} #{profile_dst}
    chown root:root #{profile_dst}
    chmod 644 #{profile_dst}
  BASH
  user node[:setup][:system_user]
  only_if { restricted.call }
  not_if {
    run_command("test -f #{profile_dst} && diff -q #{profile_src} #{profile_dst}", error: false).exit_status == 0
  }
end

# Load it into the kernel. The guard is the functional test rather than
# `aa-status`: a loaded profile that still cannot create a namespace is not
# converged, and this exact command is what Codex's sandbox does first.
execute "load bwrap userns apparmor profile" do
  command "apparmor_parser -r #{profile_dst}"
  user node[:setup][:system_user]
  only_if { restricted.call }
  not_if {
    run_command("bwrap --unshare-user --dev-bind / / true", error: false).exit_status == 0
  }
end
