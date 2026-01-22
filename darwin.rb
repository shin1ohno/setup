# frozen_string_literal: true

include_recipe "cookbooks/functions/default"

machine = nil
if node[:platform] == "darwin"
  machine = run_command("uname -m").stdout.strip
end

user = ENV["USER"]
node.reverse_merge!(
  setup: {
    root: "#{ENV["HOME"]}/.setup_shin1ohno",
    user: user,
    group: "staff",
    system_user: "root",
    system_group: "wheel",
  },
  homebrew: {
    # Set prefix to /opt/homebrew on M1 Mac because Homebrew has changed the default prefix to /opt/homebrew on M1 Mac.
    # https://github.com/Homebrew/install/blob/b62804e014a2d31216e074398411069688517a79/install.sh#L30-L32
    prefix: machine == "arm64" ? "/opt/homebrew" : "/opt/brew",
    machine: machine,
  },
)

# Include modular roles
include_role "core"
include_role "programming"
include_role "llm"
include_role "network"
include_role "extras"

# Legacy roles for backwards compatibility
include_role "manage" # Managed projects setup

# macOS-specific client setup (integrated from client role)
include_cookbook "mac-settings"
include_cookbook "mac-apps"
include_cookbook "macism"
include_cookbook "altserver"
include_cookbook "gpg-backup"

