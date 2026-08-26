# frozen_string_literal: true

# Converge /etc/resolv.conf on the Linux fleet — the `options` line and the
# nameserver list. (The cookbook name is historical: it started as the
# options-only successor to cookbooks/dns-prefer-ipv4. It is kept because this
# cookbook already owns resolv.conf convergence and already reaches every
# Linux host via roles/lxc-core + linux.rb; a second cookbook sed-ing the same
# file would leave ownership ambiguous.)
#
# Job 1 is a NEGATIVE assertion: `options no-aaaa` must be ABSENT. This
# cookbook replaces cookbooks/dns-prefer-ipv4, which appended that option
# fleet-wide.
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

# --- Job 2: the nameserver list must be unbound over v4 AND v6, and nothing
# else. ---
#
# Every PVE LXC was handed `nameserver 192.168.1.61` followed by
# `nameserver 1.1.1.1` (home-monitor pve-lxcs.tf, the `dns.servers` block).
# That second line is a SILENT downgrade: if unbound stops answering, the
# fleet does not fail — it quietly starts resolving through plaintext
# Cloudflare, `home.local` names begin returning authoritative NXDOMAIN
# instead of a retryable timeout, and the DoT-only design in cookbooks/unbound
# is defeated without a single error anywhere. That is the exact shape of the
# 2026-08-12 telemetry outage (self-heal #855/#856/#857), which was fixed on
# the PVE host — its resolv.conf has carried no public fallback since — but
# never made symmetric on the LXC side.
#
# The replacement is unbound's own ULA, so the fleet keeps two paths to the
# resolver instead of one path plus an escape hatch to the public internet.
# NOTE: both entries point at the SAME container (CT 118). This is PATH
# redundancy — it survives the v4 path breaking — and NOT resolver HA. If
# unbound itself is down, both entries are down, which is the intended loud
# failure; cookbooks/unbound-watchdog is the recovery lever (it has restarted
# a wedged unbound 13 times, and the PVE host rode all 13 out with no
# fallback configured).
#
# Why the ULA is resolved at converge time instead of written as a literal:
# the SSM host registry (/host-registry/devices) does not carry ULAs, and
# hardcoding one would violate the IP-literal rule. unbound serves its own
# AAAA, so `dns-resolver.home.local` yields it. The lookup goes over the v4
# path to .61, so it is not circular.
#
# Why dig and not getent: getent goes through glibc, which honours the very
# `options no-aaaa` that Job 1 above removes. On a host that has not converged
# yet, `getent ahostsv6 dns-resolver.home.local` returns the v4-mapped
# `::ffff:192.168.1.61` (measured on CT 119) — writing that as a nameserver
# would be actively wrong. dig queries .61 directly and is unaffected.
#
# The `fd97:` prefix test is the one deliberate literal here, paired with
# home-monitor's `local.ula_prefix_64`. It is the only thing standing between
# a malformed lookup and a bad nameserver line, so it is load-bearing: it
# rejects `::ffff:` forms, dig error text, and an empty result alike. If the
# ULA prefix is ever renumbered this cookbook fails SAFE — it stops adding the
# v6 line rather than writing a wrong address.
execute "converge /etc/resolv.conf nameservers onto unbound (v4 + ULA)" do
  command <<~'BASH'
    set -e
    R=/etc/resolv.conf
    # Only touch hosts that already point at unbound. CT 102 (pro-router) and
    # CT 104 (pro-dev) run on Tailscale DNS (100.100.100.100 +
    # fd7a:115c:a1e0::53) and must be left exactly as they are.
    grep -qE '^nameserver[[:space:]]+192\.168\.1\.61[[:space:]]*$' "$R" || exit 0
    sed -i -E '/^nameserver[[:space:]]+1\.1\.1\.1[[:space:]]*$/d' "$R"
    command -v dig >/dev/null 2>&1 || exit 0
    ULA=$(dig +short +time=3 +tries=1 @192.168.1.61 dns-resolver.home.local AAAA 2>/dev/null | head -1)
    case "$ULA" in
      fd97:*)
        grep -qF "nameserver $ULA" "$R" || \
          sed -i -E "0,/^nameserver[[:space:]]+192\.168\.1\.61[[:space:]]*$/s//&\nnameserver $ULA/" "$R"
        ;;
    esac
  BASH
  user node[:setup][:system_user]
  # Proc form for the same reason as Job 1: with a `user` attribute mitamae
  # wraps a string guard in `sudo -u root`, where a non-zero exit for an
  # unrelated reason silently defeats the guard. /etc/resolv.conf is 0644, so
  # the Proc evaluates fine under mitamae's non-root runtime privilege.
  #
  # Fire only on divergence, so a converged host shows this resource as
  # skipped rather than "changed" on every run. Written as one boolean
  # expression with no `next` — mruby, not CRuby (see rules/ruby.md).
  only_if {
    r = "/etc/resolv.conf"
    has_unbound = run_command("grep -qE '^nameserver[[:space:]]+192\\.168\\.1\\.61[[:space:]]*$' #{r}", error: false).exit_status == 0
    has_public  = run_command("grep -qE '^nameserver[[:space:]]+1\\.1\\.1\\.1[[:space:]]*$' #{r}", error: false).exit_status == 0
    has_ula     = run_command("grep -qE '^nameserver[[:space:]]+fd97:' #{r}", error: false).exit_status == 0
    has_unbound && (has_public || !has_ula)
  }
end
