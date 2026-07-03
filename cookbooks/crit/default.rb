# frozen_string_literal: true

# crit — local-first code review tool for the developer / AI-agent feedback loop.
# A single Go binary that serves a browser-based review UI (plans/docs, code
# diffs, live localhost proxy, HTML preview). Binds 127.0.0.1, zero telemetry,
# no auth for local use. https://crit.md/  •  github.com/tomasz-tomczyk/crit
#
# Not in the mise core registry (`mise registry crit` → not found), so it is
# installed via the github backend from GitHub releases. Upstream ships
# darwin/linux amd64+arm64 assets under tags like `v0.17.1`; the github backend
# selects the right asset per host. (The ubi backend also works but mise has
# deprecated it in favour of github, removal slated for mise 2027.1.0.) The
# companion Claude Code plugin (crit@crit) is registered by the claude-code
# cookbook and enabled via enabledPlugins.
include_cookbook "mise"

mise_tool "tomasz-tomczyk/crit" do
  backend "github"
end
