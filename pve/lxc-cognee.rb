# frozen_string_literal: true
#
# Entry recipe for the cognee LXC (CT 105): Cognee MCP stack via docker compose
# (cognee API + chromadb + qdrant + redis + auth-proxy).
#
# Run inside the LXC after the Terraform layer has provisioned it:
#   apt-get install -y git curl ca-certificates sudo
#   git clone https://github.com/shin1ohno/setup.git /root/setup
#   cd /root/setup && ./bin/setup
#   ./bin/mitamae local pve/lxc-cognee.rb

include_recipe "../cookbooks/functions/default"

user = ENV["USER"]
group = `id -gn`.strip
node.reverse_merge!(
  setup: {
    home: ENV["HOME"],
    root: "#{ENV["HOME"]}/.setup_shin1ohno",
    user: user,
    group: group,
    system_user: "root",
    system_group: "root",
  }
)

# Bootstrap aws CLI auth before any cookbook that uses require_external_auth.
# aws-credentials writes ~/.aws/config (login_session for sh1admn admin)
# at compile time so `aws login --profile sh1admn --remote` works, then
# uses sh1admn creds to fetch pve-bootstrap-ssm access keys from SSM and
# write them to ~/.aws/credentials. Downstream cookbooks (cognee,
# auto-mitamae-target, etc.) then find pve-bootstrap-ssm pre-configured.
node.reverse_merge!(
  aws_credentials: {
    bootstrap_profile: "sh1admn",
    profiles: {
      "pve-bootstrap-ssm" => {
        access_key_id_ssm:     "/home-monitor/iam/pve-bootstrap-ssm/access-key-id",
        secret_access_key_ssm: "/home-monitor/iam/pve-bootstrap-ssm/secret-access-key",
        region:                "ap-northeast-1",
      },
    },
  }
)
include_cookbook "aws-credentials"

include_cookbook "docker-engine"
include_cookbook "cognee"
include_role "lxc-core"

node.reverse_merge!(elastic_agent: { tags: ["lxc", "cognee"] })
include_cookbook "elastic-agent"
