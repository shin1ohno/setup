# HANDOFF Notes

Open operational issues and dashboard caveats discovered during fleet operation. Not blocking, but worth surfacing for the next operator. Append new entries at the top; resolved items move to `## Resolved` at the bottom (or get deleted along with the fix PR).

## `cookbooks/ingest-drop`: missing `fuse3` apt package install

**Symptom**: `ingest-drop.service` (user systemd; both `root` and `shin1ohno` user instances on pro-dev) restarts every ~10 seconds with:

```
rclone[NNN]: ERROR+4: Fatal error: failed to mount FUSE fs:
  fusermount: exec: "fusermount3": executable file not found in $PATH
```

**Affected hosts**: `pro-dev` (CT 104) confirmed. Any Debian/Ubuntu host running `cookbooks/ingest-drop` without `fuse3` apt-installed will fail the same way.

**Root cause**: `cookbooks/ingest-drop/default.rb` generates the systemd unit + rclone config and starts the service, but never installs the `fuse3` apt package. `rclone mount` shells out to `/usr/bin/fusermount3` to set up the FUSE filesystem. Without it, the service fails and restarts under its `Restart=on-failure` directive — endless 10 s loop.

**First failure timestamp on pro-dev**: 2026-05-03 04:28:58 UTC. Pre-existing; unrelated to the wrapper-cookbook restructuring in #216 / #217 / #218 (Phase 1 / Phase 2 pilot / Phase 2 bulk).

**Recommended fix** (~5 lines in `cookbooks/ingest-drop/default.rb`, add before the systemd unit resource):

```ruby
package "fuse3" do
  action :install
  only_if "test -f /etc/debian_version"
  not_if "command -v fusermount3 >/dev/null 2>&1"
end
```

`fuse3` is the same package name on Debian / Ubuntu / Amazon Linux 2023 / Fedora; only the install command differs (apt vs dnf). The Debian-only `only_if` matches the current LXC fleet (all Debian 13 minimal) — extend with an `rhel`/`amazon` branch if the cookbook is later applied to AL2023.

**Manual unblock until the cookbook ships the fix**: `apt-get install -y fuse3` on pro-dev resolves the loop immediately.

**Side effect of the long-running loop**: ~8000 systemd journal entries per day on pro-dev under `ingest-drop.service`. `journalctl --vacuum-size=` may be needed if disk pressure builds during the window before the cookbook fix lands.

## Resolved

(none yet — first iteration of this file)
