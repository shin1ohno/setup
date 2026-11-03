## Local integration (mitamae-managed)

This machine's herdr-core (Herdr 2) is managed by `cookbooks/herdr-core`
in the setup repo (`~/ManagedProjects/setup`). `hc` links to `herdr-core`.

**Do not run `hc update`.** Setup pins the version and sha256; an apply
reverts a self-update. To change versions, bump `herdr_core_version` and the
checksums in `cookbooks/herdr-core/default.rb` instead. This skill regenerates
from the pinned binary.

Herdr 1 (`herdr`, managed by `cookbooks/herdr`) keeps running beside it.
Herdr 1 panes and Herdr 2 terminals are separate.

Herdr UI starts the core on demand. **`hc server stop` parks kept terminals;
never stop a core you did not start.**
