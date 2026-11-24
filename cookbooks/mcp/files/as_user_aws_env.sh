#!/bin/bash
# as_user_aws_env.sh <user> <command> [args...]
#
# Run <command> as <user> through `sudo -H -u`, with the variables that select
# the AWS identity forwarded explicitly.
#
# Why this exists: mitamae wraps every `execute` that sets `user` in
# `sudo -H -u <user> -- /bin/sh -c "<command>"`, and sudo's env_reset then drops
# AWS_PROFILE / AWS_REGION / AWS_CONFIG_FILE / AWS_SHARED_CREDENTIALS_FILE. The
# auth gate (`require_external_auth`) runs its check in mitamae's own
# environment, so an operator who authenticated with a named profile passed the
# gate and then failed inside the generator with "Unable to locate credentials".
# The gate and every SSM-fetching step in cookbooks/mcp now go through this one
# script, so they cannot see different identities.
#
# Forwarded only when set and non-empty (an empty AWS_PROFILE is not a profile
# name; forwarding it would break the default-profile path). Static credential
# variables (AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_SESSION_TOKEN) are NOT
# forwarded on purpose: that would put the secret in a command line and in
# mitamae's logs. With those the gate fails up front instead of the generator
# failing half way — use a profile (aws configure --profile / aws sso login).
#
# Only variable NAMES are printed (stderr); values never are.
#
# bash 3.2 compatible (macOS /bin/bash).
set -euo pipefail

if [ "$#" -lt 2 ]; then
  echo "usage: as_user_aws_env.sh <user> <command> [args...]" >&2
  exit 64
fi

target_user="$1"
shift

forwarded=()
forwarded_names=""
for name in AWS_PROFILE AWS_REGION AWS_CONFIG_FILE AWS_SHARED_CREDENTIALS_FILE; do
  value="${!name:-}"
  if [ -n "$value" ]; then
    forwarded+=("${name}=${value}")
    forwarded_names="${forwarded_names:+${forwarded_names},}${name}"
  fi
done

if [ -n "$forwarded_names" ]; then
  echo "as_user_aws_env: forwarding ${forwarded_names} to ${target_user}" >&2
fi

# ${arr[@]+"${arr[@]}"}: an empty array expands to nothing under `set -u` on
# bash 3.2 (a bare "${arr[@]}" is an unbound-variable error there).
exec sudo -H -u "$target_user" -- env ${forwarded[@]+"${forwarded[@]}"} "$@"
