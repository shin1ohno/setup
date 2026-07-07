# frozen_string_literal: true
#
# remind — a Swift + EventKit CLI that registers TODOs into macOS Reminders.
#
# Why EventKit over AppleScript: EventKit talks to the Reminders data-store
# daemon directly (no GUI app launch), is fast/headless, and exposes the full
# reminder model (lists, due-date components, alarms). The tradeoff is a build
# step plus a TCC "Reminders full access" grant on first run.
#
# macOS-only: swiftc + EventKit exist only on darwin. Self-gates so the recipe
# is a no-op if ever reached on Linux.
#
# Idempotency: rebuild only when the shipped source changes (sha256 sentinel)
# or the installed binary is missing. A rebuild changes the ad-hoc signature's
# cdhash, so macOS re-prompts for Reminders access after any source change; for
# a rebuild-stable TCC identity, sign with a self-signed / Developer ID cert.

return if node[:platform] != "darwin"

home     = node[:setup][:home]
src_dir  = "#{home}/.local/src/remind"
bin_dir  = "#{home}/.local/bin"
bin      = "#{bin_dir}/remind"
sentinel = "#{src_dir}/.build-hash"

directory bin_dir do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
  action :create
end

directory src_dir do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
  action :create
end

%w[remind.swift Info.plist].each do |f|
  remote_file "#{src_dir}/#{f}" do
    owner node[:setup][:user]
    group node[:setup][:group]
    mode "644"
    source "files/#{f}"
  end
end

# Build + ad-hoc sign + install in one atomic shell pipeline. mitamae's execute
# runs via /bin/sh; wrap in bash for `set -o pipefail`. A missing swiftc (Xcode
# CLT not installed yet) is a WARN skip, not a hard failure — the next apply
# retries once the toolchain is present.
build_cmd = <<~CMD.strip
  bash -c '
    set -euo pipefail
    if ! command -v swiftc >/dev/null 2>&1; then
      echo "WARN: swiftc not found (install Xcode CLT: xcode-select --install); skipping remind build" >&2
      exit 0
    fi
    swiftc "#{src_dir}/remind.swift" -o "#{src_dir}/remind" \\
      -framework EventKit -framework Foundation \\
      -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "#{src_dir}/Info.plist"
    codesign -s - --force "#{src_dir}/remind"
    install -m 755 "#{src_dir}/remind" "#{bin}"
    cat "#{src_dir}/remind.swift" "#{src_dir}/Info.plist" | shasum -a 256 | cut -d" " -f1 > "#{sentinel}"
  '
CMD

execute "build and install remind" do
  command build_cmd
  user node[:setup][:user]
  not_if %(test -x #{bin} && test -f #{sentinel} && [ "$(cat #{sentinel})" = "$(cat #{src_dir}/remind.swift #{src_dir}/Info.plist | shasum -a 256 | cut -d' ' -f1)" ])
end
