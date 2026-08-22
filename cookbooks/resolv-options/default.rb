# frozen_string_literal: true

# Converge the `options` line of /etc/resolv.conf on the Linux fleet.
#
# Today the whole job is a NEGATIVE assertion: `options no-aaaa` must be
# ABSENT. This cookbook replaces cookbooks/dns-prefer-ipv4, which appended
# that option fleet-wide.
#
# Why the option existed: 192.168.1.253 (the RTX1210 DNS proxy) did not return
# NODATA for AAAA, so glibc's dual-stack getaddrinfo waited out a ~5s timeout
# per lookup. AWS CLI / boto3 paid ~16-18s per call, which stretched
# auto-mitamae-orchestrator cycles past their 5-min cron window and froze the
# fleet for 49 min on 2026-05-17.
#
# Why it must go: the RTX proxy is no longer the fleet's resolver. unbound on
# CT 118 (cookbooks/unbound) took that role and answers AAAA correctly and
# fast — measured 2026-08-21 against the exact name from that incident:
#
#   dig @192.168.1.61 sts.ap-northeast-1.amazonaws.com AAAA
#     -> NOERROR / ANSWER: 0 (NODATA) / 0.059s      (the RTX path was 5.037s)
#
# With the option in place every host is blind to AAAA, so the fleet cannot
# use IPv6 for anything resolved by name — which is now the blocker rather
# than the protection. Removing it is what makes the LAN's IPv6 usable.
#
# This is an explicit removal rather than a plain cookbook deletion because
# the old cookbook APPENDED the line: on a PVE LXC it lands after the
# `# --- END PVE ---` marker and survives CT restarts, so deleting the
# cookbook alone would leave the option in place on every existing host
# forever.
#
# Linux-only: macOS uses a different resolver stack and never carried the
# option, so cookbooks/resolv-options/platform marks this linux-only and a
# cross-OS include raises at the include layer.

# Non-interpolating heredoc: the sed program carries backreferences and
# character classes that Ruby's double-quote escaping would eat (`\1` becomes
# a literal 0x01 in an interpolating heredoc). Nothing here needs a Ruby
# value, so the quoted form is both safer and simpler.
#
# The program strips the `no-aaaa` TOKEN rather than the whole line, then
# tidies whitespace and drops the line only if nothing else was on it — a
# future `options` line carrying other settings survives intact.
# /etc/resolv.conf is 0644 but writing it needs root, hence
# `user node[:setup][:system_user]`.
execute "drop `options no-aaaa` from /etc/resolv.conf" do
  command <<~'BASH'
    sed -i -E -e '/^options[[:space:]]/ s/(^|[[:space:]])no-aaaa([[:space:]]|$)/\1\2/g' \
              -e '/^options/ s/[[:space:]]+/ /g' \
              -e '/^options/ s/[[:space:]]+$//' \
              -e '/^options$/d' \
              /etc/resolv.conf
  BASH
  user node[:setup][:system_user]
  # Proc form, not the string form: with `user node[:setup][:system_user]` a
  # string guard is wrapped in `sudo -u root` and can fail to non-zero for
  # reasons unrelated to the match, defeating the guard (same reasoning as
  # cookbooks/arp-flux/default.rb). The file is world-readable, so the Proc
  # evaluates correctly under mitamae's non-root runtime privilege too.
  only_if { run_command("grep -qE '^options[[:space:]].*no-aaaa' /etc/resolv.conf", error: false).exit_status == 0 }
end
