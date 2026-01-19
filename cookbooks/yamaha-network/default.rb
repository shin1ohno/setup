add_profile "yamaha-network" do
  bash_content <<~'BASH'
    # AWS profile for RTX router management (override with RTX_AWS_PROFILE env var)
    : "${RTX_AWS_PROFILE:=default}"

    # Retrieve RTX router admin password from AWS SSM Parameter Store
    rtx-admin-pass() {
      aws ssm get-parameter \
        --name "/rtx-routers/$1/admin_password" \
        --with-decryption \
        --query 'Parameter.Value' \
        --output text \
        --profile "${RTX_AWS_PROFILE}"
    }

    # Retrieve RTX router user password from AWS SSM Parameter Store
    # Usage: rtx-user-pass <router_name> <username>
    rtx-user-pass() {
      aws ssm get-parameter \
        --name "/rtx-routers/$1/user_password/$2" \
        --with-decryption \
        --query 'Parameter.Value' \
        --output text \
        --profile "${RTX_AWS_PROFILE}"
    }
  BASH
end
