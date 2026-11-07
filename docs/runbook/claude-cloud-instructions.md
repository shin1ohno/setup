# Dedicated cloud instruction environment

Status: review proposal for SH1-83. Keep Default unchanged. The new environment
must run setup before starting its first agent session; SessionStart is too late
to establish that session's initial instruction context.

The `claude-cloud.rb` entry distributes `CLAUDE.md`, shared `AGENTS.md`, rules,
reference documents, skills with their helper files, and agent definitions.
It does not install Claude, merge settings/permissions/hooks, register MCP, or
configure an account. `bin/setup` bootstraps the existing pinned mitamae only.
Local `claude-code/default.rb` includes the same distribution subrecipes and
retains its installation, hook, plugin, settings and TODO configuration resources.

Create a **new** cloud environment after reviewing the commit. Paste the following
setup script, replacing `REVIEWED_COMMIT` with the approved commit SHA. Do not edit
the existing Default environment. This is an environment UI operation, not an API
request schema or an operation this branch has already performed.

```bash
set -euo pipefail
git clone --filter=blob:none https://github.com/shin1ohno/setup "$HOME/ManagedProjects/setup"
git -C "$HOME/ManagedProjects/setup" checkout REVIEWED_COMMIT
bash "$HOME/ManagedProjects/setup/bin/setup-claude-cloud" REVIEWED_COMMIT
```

The setup script refuses dirty or unrelated checkouts and exits on failure.
The platform should show that failure in the dedicated environment setup log;
this does not demonstrate failure isolation until a real new environment is
tested. Network access to the public repository and existing mitamae release is
required. No credentials are copied by this script.

Cloud shells use bash, and the dedicated environment has no demonstrated access
to the local fleet or pro-dev. Local operations require a verified connection;
an instruction mentioning a host is not proof of access. Skills that need an
unavailable integration must report that limitation rather than guess results.

Review checks:

- Run `ruby bin/test-claude-distribution` to compare every local resource
  declaration against the pre-split fixture, including the existing hook list.
- Run the cloud entry with mitamae `--dry-run` in a private HOME. This validates
  mruby and distribution resources without applying to the operator's home.
- In a first fresh session of the new environment, record exactly one `/context`,
  its instruction file list, skills, and agent list. This runtime check is unrun
  until the owner selects and creates the dedicated environment.
- Before local rollout, compare local host dry-runs and preserve later hook
  additions at merge. The parser worker's changes belong in the hook section of
  default.rb, which remains outside distribution-only recipes.

Decision: create the opt-in environment for a canary, or retain the current cloud
setup. The first choice adds the full distributed instruction/skill catalog; its
actual startup-token cost must be measured, not inferred from file bytes.
