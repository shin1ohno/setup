# frozen_string_literal: true
#
# pm2 (Linux): `pm2 startup systemd` wiring. The two OS-independent halves are
# install.rb (nodejs + the mise npm install) and profile.rb (the lazy
# completion wrapper); this file holds only what systemd needs, between them.

include_recipe "install"

# `pm2 startup systemd` shells out through mise's shim, and that
# specific subcommand intermittently fails with "pm2 is not a valid
# shim" (mise src/shims.rs err_no_version_set -- a tool-metadata
# resolution issue elsewhere in the toolset, not actually about pm2)
# even though `pm2 --version` and other invocations of the SAME shim
# succeed immediately before and after. Confirmed live: `mise reshim`
# right before this step does not reliably prevent it. mitamae has no
# ignore_failure, so tolerate this non-fatally (systemd auto-start for
# pm2 is a nice-to-have, not something later cookbooks depend on) --
# log a WARN so it's visible rather than silently missing.
execute "setup pm2" do
  cwd node[:setup][:home]
  command "sudo env PATH=$PATH:#{node[:setup][:home]}/.local/share/mise/shims #{node[:setup][:home]}/.local/share/mise/shims/pm2 startup systemd -u $USER --hp #{node[:setup][:home]} || echo 'pm2: startup systemd setup failed (see cookbooks/pm2/linux.rb) -- pm2 will not auto-start on boot; continuing' >&2"
  not_if "systemctl list-unit-files | grep pm2-$USER.service | grep enabled"
end

include_recipe "profile"
