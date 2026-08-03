# frozen_string_literal: true
#
# envchain — keychain-backed environment variables.
#
# darwin-only (see cookbooks/envchain/platform): roles/core has always included
# this cookbook behind a darwin condition, so the `ubuntu` (`#skip!`) and `arch`
# arms of the pre-migration `case node[:platform]` were unreachable from every
# entry recipe. The marker file states that restriction where the include layer
# can enforce it, and turns a cross-OS `COOKBOOK=envchain` test run into a loud
# refusal instead of a silent no-op.
package "envchain"
