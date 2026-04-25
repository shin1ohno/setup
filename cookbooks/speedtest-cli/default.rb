case node[:platform]
when "darwin"
  ookla_dir = "#{node[:setup][:root]}/speedtest"
  # Ookla ships a single universal2 (arm64 + x86_64) binary on macOS.
  # The arch-specific URLs (-arm64, -x86_64) return 403 from the S3 CDN.
  ookla_url = "https://install.speedtest.net/app/cli/ookla-speedtest-1.2.0-macosx-universal.tgz"

  directory ookla_dir do
    owner node[:setup][:user]
    group node[:setup][:group]
    mode "755"
  end

  execute "download Ookla speedtest CLI" do
    user node[:setup][:user]
    # -fsSL: fail on HTTP errors (the previous -L silently saved 403 error
    # bodies as 263-byte XML, which tar then rejected as "unrecognized
    # archive format").
    command "curl -fsSL #{ookla_url} -o #{ookla_dir}/speedtest.tgz && tar xzf #{ookla_dir}/speedtest.tgz -C #{ookla_dir}"
    not_if "test -x #{ookla_dir}/speedtest"
  end

  execute "install ookla speedtest" do
    user node[:setup][:system_user]
    command "install -m 0755 #{ookla_dir}/speedtest /usr/local/bin/speedtest"
    not_if "test -x /usr/local/bin/speedtest"
  end

  package "speedtest" do
    action :remove
    only_if { brew_formula?("speedtest") }
  end

  execute "brew untap teamookla/speedtest" do
    only_if { brew_tap?("teamookla/speedtest") }
  end
when "ubuntu"
  execute "Install speedtest-cli" do
    command "$HOME/.pyenv/shims/pip install speedtest-cli"
    not_if "test -x $HOME/.pyenv/shims/pip && $HOME/.pyenv/shims/pip list | grep -q speedtest-cli"
  end
end


