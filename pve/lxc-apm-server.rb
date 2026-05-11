# frozen_string_literal: true
#
# Entry recipe for CT 116 apm-server (Phase 2 of standalone APM Server
# plan, ~/.claude/plans/scalable-noodling-pearl.md). Single-cookbook
# host: install apm-server 8.16 + TLS + systemd + SSM-gated secrets.
# All work lives in cookbooks/lxc-apm-server/default.rb; this file is
# the per-LXC entrypoint so `./bin/mitamae local pve/lxc-apm-server.rb`
# converges the apm-server LXC into the running fleet shape.

include_cookbook "ssh-keys"
include_cookbook "lxc-apm-server"
