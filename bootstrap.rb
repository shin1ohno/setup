# frozen_string_literal: true
#
# bootstrap.rb — phase 1 of `bin/converge` (ADR 0012): install the external
# tools whose PRESENCE the auth gates test at COMPILE time, and nothing else.
#
# require_external_auth (cookbooks/functions) probes `aws` while the entry
# recipe compiles, which is before any resource that installs `aws` has
# converged. On a fresh machine the first apply of darwin.rb / linux.rb
# therefore skipped every SSM-gated cookbook (gate reason tool_missing) and the
# README asked for a second apply. This recipe is applied FIRST, in its own
# mitamae process, so the normal entry recipe compiles afterwards with the
# tools already present and its gates evaluate for real.
#
# Scope rule: only prerequisite TOOLS. No auth gate, no host configuration —
# those belong to the normal entry recipe, which stays the single owner of
# the machine's converged state. Adding a cookbook here is justified only when
# a require_external_auth gate somewhere tests for the binary it installs
# (today: tool_binary "aws" → cookbooks/awscli).
include_recipe "cookbooks/functions/default"
include_platform_cookbook "awscli"
