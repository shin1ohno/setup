# frozen_string_literal: true

remote_file "#{node[:setup][:root]}/bun-install.sh" do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
  source "files/install.sh"
end

execute "#{node[:setup][:root]}/bun-install.sh" do
  not_if { File.exist? "#{node[:setup][:home]}/.bun/bin/bun" }
end

add_profile "bun" do
  bash_content <<~'END'
    # Lazy-load bun completion. PATH is set eagerly so `which bun` works;
    # the completion file (~40ms to source) loads only on first bun call.
    export BUN_INSTALL="$HOME/.bun"
    export PATH="$BUN_INSTALL/bin:$PATH"
    bun() {
      unset -f bun
      [ -s "$HOME/.bun/_bun" ] && source "$HOME/.bun/_bun"
      bun "$@"
    }
  END
end

# bun's self-upgrade hits GitHub's release API, which rate-limits
# unauthenticated requests from the fleet's shared egress IP (HTTP 403).
# Two guards keep a failed upgrade from aborting the whole mitamae run —
# it previously failed the auto-mitamae canary (pro-dev) and stalled the
# entire fleet rollout:
#   - non-fatal: the `|| echo` + `; touch` chain swallows the upgrade's
#     exit status so a 403 (or any upstream hiccup) does not fail mitamae.
#   - daily: `not_if` skips when the stamp was refreshed within 24h, so
#     the upgrade is attempted at most once/day instead of every cycle.
# The stamp is touched even on failure, so a persistent 403 backs off for
# a day rather than retrying (and re-hitting the rate limit) every apply.
bun_upgrade_stamp = "#{node[:setup][:home]}/.bun/.last-upgrade-check"
execute "bun upgrade (best-effort, daily)" do
  command "#{node[:setup][:home]}/.bun/bin/bun upgrade || " \
          "echo 'bun: upgrade failed (upstream/rate-limit), continuing' >&2; " \
          "touch #{bun_upgrade_stamp}"
  only_if { File.exist? "#{node[:setup][:home]}/.bun/bin/bun" }
  not_if "test -f #{bun_upgrade_stamp} && find #{bun_upgrade_stamp} -mtime -1 | grep -q ."
end

