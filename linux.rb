# frozen_string_literal: true

include_recipe "cookbooks/functions/default"

user = ENV["USER"]
node.reverse_merge!(
  setup: {
    root: "#{ENV['HOME']}/.setup_shin1ohno",
    user: user,
    group: user,
  },
  rbenv: {
    root: "#{ENV['HOME']}/.rbenv",
  },
)

include_role "base"
