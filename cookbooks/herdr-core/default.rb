# frozen_string_literal: true

# herdr-core (Herdr 2) provides persistent terminals for programs and agents.
# Install it BESIDE Herdr 1 (cookbooks/herdr), which keeps its own binary,
# configuration and panes. Herdr UI starts the core on demand.
#
# Keep this pin aligned with the core version bundled by Herdr UI in
# herdr-gpui/scripts/release/herdr-core.json, and never below the oldest core
# it accepts (MIN_VERSION in herdr-gpui's crates/herdr-core-client/src/hello.rs):
# below that, Herdr UI asks for `hc update`, which the next apply reverts.
# On a version bump, recompute:
#   for t in macos-aarch64 macos-x86_64 linux-aarch64 linux-x86_64; do
#     curl -fsSL "https://releases.herdr.dev/core/<version>/herdr-core-$t.tar.gz" | shasum -a 256
#   done
# The checksums cover the tarballs, each containing one herdr-core executable.

# Local vars, not constants: mitamae loads recipes into one Ruby namespace.
herdr_core_version = "0.1.13"
checksums = {
  "macos-aarch64" => "fc1ffba3820b93b0e2faa5394a64b9ff5528f135611b6034469d81c0fa1c37aa",
  "macos-x86_64"  => "bfb8671d7d40517f8736ec32eb72b823429117db148012a69625afcec582b31d",
  "linux-aarch64" => "82abc30deaf6e7daeca3c60eefc12708f0210f945c28062674be71fcfde17bd5",
  "linux-x86_64"  => "d0dbfdd6e060832c629a6aed03687165479baceab5a5545a103490d0e4adab8c",
}

os = platform_value(darwin: "macos", linux: "linux")
arch = case node[:hw][:machine]
       when "arm64", "aarch64" then "aarch64"
       else "x86_64"
       end
target = "#{os}-#{arch}"
sha = checksums.fetch(target)
url = "https://releases.herdr.dev/core/#{herdr_core_version}/herdr-core-#{target}.tar.gz"

bin_dir = "#{node[:setup][:home]}/.local/bin"
herdr_core_path = "#{bin_dir}/herdr-core"
hc_path = "#{bin_dir}/hc"

directory bin_dir do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
end

# Use bash explicitly: /bin/sh on Linux need not support pipefail.
execute "install herdr-core #{herdr_core_version} (#{target})" do
  user node[:setup][:user]
  command <<~SH.strip
    bash -c '
      set -euo pipefail
      tmp="$(mktemp -d)"
      trap "rm -rf -- \\"$tmp\\"" EXIT
      curl -fsSL --retry 3 --connect-timeout 10 --max-time 120 "#{url}" -o "$tmp/herdr-core.tar.gz"
      echo "#{sha}  $tmp/herdr-core.tar.gz" | shasum -a 256 -c -
      tar --no-same-owner -xzf "$tmp/herdr-core.tar.gz" -C "$tmp"
      install -m 0755 "$tmp/herdr-core" "#{herdr_core_path}"
    '
  SH
  not_if "'#{herdr_core_path}' --version 2>/dev/null | grep -Fqx 'hc #{herdr_core_version}'"
end

# Guard at converge time, and preserve any existing non-symlink at hc. A
# symlink at hc, wherever it points, is repointed at herdr-core.
local_ruby_block "warn about an existing hc path" do
  block do
    MItamae.logger.warn(
      "[herdr-core] #{hc_path} exists and is not a symlink -- skipping hc link; move it aside to enable hc.",
    )
  end
  only_if "test -e '#{hc_path}' && ! test -L '#{hc_path}'"
end

link hc_path do
  to "herdr-core"
  user node[:setup][:user]
  force true
  only_if "test ! -e '#{hc_path}' || test -L '#{hc_path}'"
end

# Unlike Herdr 1, --skill has no YAML frontmatter. Add it before the manual,
# then append setup-specific guidance. Share this composition with the guard
# so a pin, frontmatter or local-guidance edit refreshes the installed skill.
skill_frontmatter = File.join(File.dirname(__FILE__), "files", "skill-frontmatter.md")
skill_local = File.join(File.dirname(__FILE__), "files", "skill-local.md")
skill_body = %({ cat "#{skill_frontmatter}"; "#{herdr_core_path}" --skill; printf "\\n"; cat "#{skill_local}"; })
skill_dir = "#{node[:setup][:home]}/.agents/skills/herdr-core"

["#{node[:setup][:home]}/.agents", "#{node[:setup][:home]}/.agents/skills", skill_dir].each do |dir|
  directory dir do
    owner node[:setup][:user]
    group node[:setup][:group]
    mode "755"
  end
end

execute "install herdr-core agent skill" do
  user node[:setup][:user]
  command <<~SH.strip
    bash -c '
      set -euo pipefail
      tmp="$(mktemp)"
      trap "rm -f -- \\"$tmp\\"" EXIT
      #{skill_body} > "$tmp"
      install -m 0644 "$tmp" "#{skill_dir}/SKILL.md"
    '
  SH
  not_if "bash -c 'set -euo pipefail; #{skill_body}' | cmp -s - '#{skill_dir}/SKILL.md'"
end

agents_skill_link "herdr-core"
