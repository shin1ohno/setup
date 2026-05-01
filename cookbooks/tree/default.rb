# frozen_string_literal: true

case node[:platform]
when "darwin"
  package "tree"
else
  package "tree" do
    user "root"
    # Proc not_if bypasses the user-wrapped idempotency check that
    # always reports "not installed" on this host. See
    # cookbooks/functions/default.rb for the install_package equivalent.
    not_if { run_command("dpkg-query -W -f='${Status}' tree 2>/dev/null | grep -q 'install ok installed'", error: false).exit_status == 0 }
  end
end

