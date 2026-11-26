# frozen_string_literal: true

# Stop /var/cache/apt/archives from growing without bound, and reclaim what
# has already accumulated.
#
# Debian never deletes a downloaded .deb on its own, and nothing in this repo
# ever ran `apt-get clean`, so every host has been keeping every package it
# ever installed. Measured across the running fleet 2026-08-23: 0.9-3.1 GB per
# LXC, ~22 GB total. It is worst where it hurts most — CTs 101 / 102 / 118
# have 4 GB disks, so ~23% of the whole filesystem was .debs that were already
# installed and will never be read again.
#
# Why this is not cosmetic: a full root filesystem does NOT fail the resource
# that filled it. It fails `apt-get update` with "Disk quota exceeded" (exit
# 100), which aborts the mitamae run at `execute[update_package_index]` —
# before ANY cookbook's own resources are reached. CT 108 spent five days in
# exactly that state: every apply died at apt, so the compose service it was
# supposed to converge was never even visited, and the host sat on a
# known-leaking image while the fleet reported it as merely "failing" (#913).
# Disk that fills for one reason takes the whole convergence pipeline down
# with it.
#
# Why the `apt` command already looks clean but `apt-get` does not: apt ships
# `Binary::apt::APT::Keep-Downloaded-Packages "0"` as a built-in default. The
# `Binary::<progname>::` scope applies that ONLY to the `apt` command. This
# fleet installs through `apt-get` (mitamae's `package` resource, plus the
# explicit `apt-get install` executes in docker-engine and friends), which is
# a different progname and therefore keeps its downloads. Setting the option
# unscoped covers every frontend.
#
# Verified on debian:trixie-slim (apt 3.0.3 — the version every probed CT
# runs), with the image's own /etc/apt/apt.conf.d/docker-clean removed so the
# baseline matches a real host:
#
#   apt-get install --reinstall tzdata, no option   -> 1 .deb kept
#   apt-get install --reinstall tzdata, option set  -> 0 .deb kept
#
# The first line is the positive control: without removing docker-clean the
# baseline also reads 0, which would have made the option look load-bearing
# when it was the image cleaning up.
#
# Linux-only (apt does not exist on darwin); cookbooks/apt-no-keep-downloads/
# platform marks it so a cross-OS include raises at the include layer rather
# than silently no-opping.

apt_conf = "/etc/apt/apt.conf.d/99-no-keep-downloads"
directive = 'APT::Keep-Downloaded-Packages "false";'

# Single-pipeline execute (write + chmod) rather than a `file` resource: a
# file/remote_file with an owner triggers mitamae's internal `sudo chown`,
# which fails without a terminal on the non-TTY fleet
# (~/ManagedProjects/setup/.claude/rules/ruby.md).
execute "install #{apt_conf}" do
  command <<~BASH
    printf '%s\\n' '#{directive}' > #{apt_conf} && chmod 0644 #{apt_conf}
  BASH
  user node[:setup][:system_user]
  # Content-aware, not File.exist? — a truncated or hand-edited file re-writes
  # instead of counting as done. Proc form, not the string form: with a `user`
  # attribute mitamae wraps a string guard in `sudo -u root`, which can fail
  # to non-zero for reasons unrelated to the match and defeat the guard (same
  # reasoning as cookbooks/resolv-options). The file is 0644, so the Proc
  # evaluates correctly under mitamae's non-root runtime privilege too.
  not_if { run_command("grep -qF '#{directive}' #{apt_conf} 2>/dev/null", error: false).exit_status == 0 }
end

# One-time reclaim of what accumulated before the directive existed. Guarded
# on archives actually holding a .deb, so once the directive is in force this
# stops firing instead of running `apt-get clean` on every converge —
# self-limiting rather than permanently noisy.
#
# The guard reads a world-readable path (/var/cache/apt/archives is 0755), so
# it evaluates correctly whether mitamae is running as root (LXC) or as the
# operator user (bare metal). `ls` on a non-matching glob exits non-zero,
# which is exactly the "nothing to do" signal wanted here.
#
# The guard also skips, at WARN, while another apt process holds a lock that
# `apt-get clean` needs. It takes both /var/cache/apt/archives/lock and
# /var/lib/apt/lists/lock (fcntl F_SETLK, apt 2.8.4 strace and apt 3.0.3
# source) and exits 100 if either is held, which aborts the whole converge.
# unattended-upgrades holds the archives lock while its downloaded .debs sit
# in archives and deletes them after a successful install
# (Keep-Debs-After-Install defaults to false), so its .debs and its lock
# exist at the same moment; sh1-cloud's linux.rb apply stopped at this
# resource that way on 2026-11-26. The lists lock is held by apt-daily's
# `apt-get update`. Skipping loses nothing: the .debs stay and the next
# converge retries.
#
# The guard does not try the lock itself: a trial lock would contend with the
# apt run it is trying to avoid. It reads /proc/locks instead, the kernel's
# lock table (0444; stat needs only search permission on the 0755 lock
# directories), and matches the lock file's device and inode on a POSIX or
# OFD line. The device comes from `stat %d` with glibc's dev_t split rather
# than %Hd/%Ld so it does not depend on the coreutils version. If the probe
# cannot run, the guard reports "not held" and the old behaviour returns. A
# lock taken in the milliseconds between guard and command still fails the
# run, as before.
apt_clean_locks = {
  "/var/cache/apt/archives/lock" => "usually unattended-upgrades downloading",
  "/var/lib/apt/lists/lock" => "usually apt-daily's apt-get update",
}

execute "reclaim /var/cache/apt/archives" do
  command "apt-get clean"
  user node[:setup][:system_user]
  only_if do
    debs = run_command("ls /var/cache/apt/archives/*.deb >/dev/null 2>&1", error: false).exit_status == 0
    held = apt_clean_locks.keys.select do |lock|
      probe = <<~SH
        set -- $(stat -c '%d %i' #{lock} 2>/dev/null) && [ $# -eq 2 ] || exit 1
        dev=$(printf '%02x:%02x' $(( ($1 >> 8) & 0xfff )) $(( ($1 & 0xff) | (($1 >> 12) & 0xfff00) )))
        grep -qE "^[0-9]+: (-> )?(POSIX|OFDLCK) .* $dev:$2 " /proc/locks
      SH
      run_command(probe, error: false).exit_status == 0
    end
    if debs && !held.empty?
      MItamae.logger.warn(
        "apt-no-keep-downloads: " + held.map { |lock| "#{lock} held (#{apt_clean_locks[lock]})" }.join(", ") +
        " — /var/cache/apt/archives NOT reclaimed this run; the next converge retries."
      )
    end
    debs && held.empty?
  end
end
