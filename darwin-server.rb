# frozen_string_literal: true

include_recipe "cookbooks/functions/default"

machine = nil
if node[:platform] == "darwin"
  machine = run_command("uname -m").stdout.strip
end

user = ENV["USER"]
node.reverse_merge!(
  setup: {
    root: "#{ENV['HOME']}/.setup_shin1ohno",
    user: user,
    group: "staff",
  },
  rbenv: {
    root: "#{ENV['HOME']}/.rbenv",
  },
  homebrew: {
    # Set prefix to /opt/homebrew on M1 Mac because Homebrew has changed the default prefix to /opt/homebrew on M1 Mac.
    # https://github.com/Homebrew/install/blob/b62804e014a2d31216e074398411069688517a79/install.sh#L30-L32
    prefix: machine == "arm64" ? "/opt/homebrew" : "/opt/brew",
    machine: machine,
  },
)

include_role "base"
include_role "client"
include_cookbook "roon-server"

