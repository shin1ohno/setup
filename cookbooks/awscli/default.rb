# frozen_string_literal: true
directory "#{node[:setup][:root]}/awscli" do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
end


case node[:platform]
when "ubuntu"
  archive_path = "#{node[:setup][:root]}/awscli/awscliv2.zip"
  package "unzip" do
    user node[:setup][:system_user]
    not_if { run_command("dpkg-query -W -f='${Status}' unzip 2>/dev/null | grep -q 'install ok installed'", error: false).exit_status == 0 }
  end

  # Download to a .part file and only publish it once unzip agrees the archive
  # is complete. A bare `-o archive_path` guarded on File.exist? leaves a
  # truncated zip behind when the transfer dies mid-flight, and the guard then
  # treats that corpse as done forever: every later apply skips the download
  # and hands the partial file to the unzip below, which fails, which aborts
  # the whole run. Observed on CT 120 (homebridge) — a 46 MB fragment of the
  # 73 MB zip, re-failing on every converge until it was replaced by hand.
  # The integrity check is the guard, so a poisoned cache self-heals.
  execute "download awscli v2 installer" do
    command <<~SH.strip
      set -eu
      curl --silent --fail --show-error \\
        https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip \\
        -o #{archive_path.shellescape}.part
      unzip -t #{archive_path.shellescape}.part >/dev/null
      mv #{archive_path.shellescape}.part #{archive_path.shellescape}
    SH
    not_if "unzip -t #{archive_path.shellescape} >/dev/null 2>&1"
  end

  execute "unzip #{archive_path.shellescape} -d #{node[:setup][:root]}/awscli" do
    not_if { File.exist?("#{node[:setup][:root]}/awscli/aws") }
  end

  execute "sudo -p 'Enter your password to install awscli: ' #{node[:setup][:root]}/awscli/aws/install" do
    # Direct filesystem check — `which aws` was failing under mitamae's
    # specinfra wrapper PATH and re-firing the installer, which then
    # errored with "Found preexisting AWS CLI installation".
    not_if "test -d /usr/local/aws-cli/v2/current"
  end

  # Add /usr/local/bin to mitamae's in-process PATH so subsequent cookbooks'
  # `run_command` calls (compile-time auth probes in require_external_auth,
  # SSM fetch helpers) can find `aws`. The AWS CLI installer drops the
  # binary at /usr/local/aws-cli/v2/current/bin/aws with a /usr/local/bin/aws
  # symlink, but on Debian/Ubuntu LXCs running mitamae from a non-login
  # bash (auto-mitamae SSH ForceCommand, `pct exec ... bash -c`) the
  # default PATH is /sbin:/bin:/usr/sbin:/usr/bin and does NOT include
  # /usr/local/bin. Without this prepend, every SSM-gated cookbook's auth
  # probe returns exit 127 (command not found), and in non-TTY contexts
  # require_external_auth silently skips the gated block — masquerading
  # as "auth not configured" when the actual cause is missing $PATH.
  # See ~/.claude/rules/ruby.md "sudo secure_path strips user home" for
  # the analogous pattern with user-installed shims.
  prepend_path("/usr/local/bin")
when "darwin"
  pkg_path = "#{node[:setup][:root]}/awscli/AWSCLIV2.pkg"

  execute "curl --silent --fail https://awscli.amazonaws.com/AWSCLIV2.pkg -o #{pkg_path.shellescape}" do
    not_if { File.exist?(pkg_path) }
  end

  execute "sudo -p 'Enter your password to install awscli: ' installer -pkg #{pkg_path.shellescape} -target /" do
    not_if { FileTest.directory?("/usr/local/aws-cli") }
  end

  package "awscli" do
    action :remove
    only_if { File.exist?("#{node[:homebrew][:prefix]}/bin/aws") }
  end

  # Lazy-load AWS completion. `complete -C` is bash-style and requires
  # bashcompinit; loading both at every shell start cost ~5ms. The wrapper
  # below pays the cost only on first `aws` invocation, then unfunctions
  # itself so subsequent calls go straight to the real binary.
  add_profile "dot-zsh" do
    bash_content <<~'EOM'
      aws() {
        unfunction aws
        autoload -U bashcompinit && bashcompinit
        complete -C '/usr/local/bin/aws_completer' aws
        command aws "$@"
      }
    EOM
  end

  # Match the Linux-side prepend: ensures `run_command("aws ...")` calls in
  # downstream cookbooks (require_external_auth probes, SSM fetch helpers)
  # find the AWSCLIV2.pkg-installed binary at /usr/local/bin/aws regardless
  # of how mitamae was invoked.
  prepend_path("/usr/local/bin")
else
  raise "Unsupported platform: #{node[:platform]}"
end
