# frozen_string_literal: true
#
# lxc-hydra (CT 106): Ory Hydra OAuth 2.0 / OIDC server, NATIVE systemd.
#
# Why not docker compose: hydra is a single Go binary. The 200 MiB docker
# daemon overhead is unjustified for a single-binary service. The docker
# variant lives in cookbooks/hydra/ for the bare-metal pro deployment.
#
# Aurora DSN fetched from SSM. Aurora hydra db + role is provisioned
# upstream by home-monitor/rds.tf (Phase 0.5-Z Z-3 verifies presence).
#
# RAM 1 GiB / CPU 1.

return if node[:platform] == "darwin"

include_cookbook "hydra-server"
