# frozen_string_literal: true
#
# consent-app: static-file-only cookbook providing the Hydra consent app
# source (Dockerfile + requirements.txt + app.py).
#
# Currently consumed by pve/lxc-consent.rb which reads the 3 files via
# `File.read(File.expand_path("../cookbooks/consent-app/files/...", ...))`
# and embeds them as `file ... content: src_content` resources at apply
# time. This cookbook does not declare any resources of its own — it
# exists purely as a stable home for the consent-app source so the
# pve recipe stops depending on the legacy `cookbooks/hydra/` cookbook
# (deleted in Phase 8).
#
# If the consent app outgrows the inline-via-File.read pattern (e.g.
# needs its own `directory` / `template` resources), promote this
# cookbook to a real service primitive (like cookbooks/cognee/) and
# update pve/lxc-consent.rb to `include_cookbook "consent-app"`.
