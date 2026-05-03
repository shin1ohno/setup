# frozen_string_literal: true

# pyenv installs Python by compiling from source — Linux needs the dev
# headers up front, otherwise `pyenv install <ver>` builds Python without
# bz2 / ssl / readline / sqlite extensions and the post-install
# `pip install argcomplete` later fails for missing _ssl module.
if node[:platform] != "darwin"
  %w[
    make build-essential libssl-dev zlib1g-dev libbz2-dev libreadline-dev
    libsqlite3-dev libncursesw5-dev xz-utils tk-dev libxml2-dev
    libxmlsec1-dev libffi-dev liblzma-dev
  ].each do |pkg|
    package pkg do
      user node[:setup][:system_user]
      not_if { run_command("dpkg-query -W -f='${Status}' #{pkg} 2>/dev/null | grep -q 'install ok installed'", error: false).exit_status == 0 }
    end
  end
end

remote_file "#{node[:setup][:root]}/pyenv-install.sh" do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
  source "files/install.sh"
end

execute "#{node[:setup][:root]}/pyenv-install.sh" do
  not_if { File.exist? "#{node[:setup][:home]}/.pyenv/bin" }
end

# Make pyenv visible to subsequent cookbooks in the same mitamae run (e.g.
# speedtest-cli uses bare `pip` from `~/.pyenv/shims`). Idempotent — no-op
# on re-run if already on PATH.
prepend_path(
  "#{node[:setup][:home]}/.pyenv/bin",
  "#{node[:setup][:home]}/.pyenv/shims",
)

add_profile "pyenv" do
  bash_content <<~EOS
    export PYENV_ROOT="$HOME/.pyenv"
    command -v pyenv >/dev/null || export PATH="$PYENV_ROOT/bin:$PATH"
    eval "$(pyenv init -)"
    eval `register-python-argcomplete pipx`
  EOS
end

node[:python][:versions].each do |version|
  if node[:platform] == "darwin" && version == "3.12.0"
    execute "openssl homebrew fix" do
      command "source $HOME/.bash_profile"
      command <<~EOS
      brew uninstall --ignore-dependencies openssl@1.1                                                           setup -> main
      env CONFIGURE_OPTS='--enable-optimizations' pyenv install 3.12.0
      brew install openssl@1.1
      EOS
      not_if "$HOME/.pyenv/bin/pyenv versions | grep #{version}"
    end
  else
    execute "$HOME/.pyenv/bin/pyenv install #{version}" do
      not_if "$HOME/.pyenv/bin/pyenv versions | grep #{version}"
    end
  end

  execute "$HOME/.pyenv/bin/pyenv global #{version} && $HOME/.pyenv/shims/python -m ensurepip --upgrade && $HOME/.pyenv/bin/pyenv rehash && $HOME/.pyenv/shims/pip install argcomplete" do
    not_if "$HOME/.pyenv/shims/pip list | fgrep -q argcomplete"
    cwd node[:setup][:home]
  end
end

execute "$HOME/.pyenv/shims/pip install --upgrade pip" do
  only_if "test -x $HOME/.pyenv/shims/pip"
end
