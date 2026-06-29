# frozen_string_literal: true
#
# Entry recipe for the es-memory LXC: unified Cognee + Mem0 MCP server backed
# by the ElasticSearch cluster (es-0/1/2). Replaces the Cognee (RDS pgvector /
# kuzu) and Mem0 (Qdrant / Aurora pgvector) storage stacks with BM25 +
# dense_vector kNN hybrid search. See cookbooks/lxc-es-memory.
#
# Run inside the LXC after the Terraform layer has provisioned it:
#   apt-get install -y git curl ca-certificates sudo
#   git clone https://github.com/shin1ohno/setup.git /root/setup
#   cd /root/setup && ./bin/setup
#   ./bin/mitamae local pve/lxc-es-memory.rb

include_recipe "../cookbooks/functions/default"

# No docker-engine: the stack runs as native systemd units + a Python venv
# (see cookbooks/lxc-es-memory, which pulls in awscli for the SSM .env gate).
include_cookbook "lxc-es-memory"
lxc_entry(tags: ["lxc", "es-memory"])
