# frozen_string_literal: true
#
# ollama (macOS): the Homebrew formula plus a `brew services` restart so the
# daemon picks up a freshly-installed binary. Linux takes a completely
# different route (upstream installer script + zstd) — see linux.rb.

# Allow callers (e.g. CPU-only LXC entry recipes such as lxc-pro-dev.rb)
# to opt out without forking the llm role. Set node[:llm][:skip_ollama]
# = true before including this cookbook (or include_role "llm"). The guard
# lives in BOTH per-OS recipes because a `return` only unwinds its own file.
if node.dig(:llm, :skip_ollama)
  MItamae.logger.info("ollama: skipped (node[:llm][:skip_ollama] set)")
  return
end

package "ollama" do
  action :install
  not_if "which ollama > /dev/null 2>&1"
end

execute "brew services restart ollama"
