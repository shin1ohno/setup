# frozen_string_literal: true
#
# python: the OS-independent half — pyenv itself, the lazy-loading profile
# fragment, and the interpreter versions from node[:python][:versions].
# Included by darwin.rb directly and by linux.rb after the distro dev headers,
# so resource order matches the pre-split default.rb on both platforms.

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
    # Lazy-load pyenv + pipx argcomplete: shims on PATH so python/pip work
    # immediately; `pyenv init` and the argcomplete eval run only when
    # pyenv or pipx is first invoked. Saves ~100-150ms at shell start.
    export PYENV_ROOT="$HOME/.pyenv"
    export PATH="$PYENV_ROOT/shims:$PYENV_ROOT/bin:$PATH"
    pyenv() {
      unset -f pyenv
      eval "$(pyenv init -)"
      pyenv "$@"
    }
    pipx() {
      unset -f pipx
      # register-python-argcomplete emits bash-style `complete -F`, which
      # requires bashcompinit. Load both here so 10-dot-zsh can keep
      # bashcompinit out of the eager startup path.
      autoload -U bashcompinit && bashcompinit
      eval "$(register-python-argcomplete pipx)"
      command pipx "$@"
    }
  EOS
end

node[:python][:versions].each do |version|
  execute "$HOME/.pyenv/bin/pyenv install #{version}" do
    not_if "$HOME/.pyenv/bin/pyenv versions | grep #{version}"
  end

  execute "$HOME/.pyenv/bin/pyenv global #{version} && $HOME/.pyenv/shims/python -m ensurepip --upgrade && $HOME/.pyenv/bin/pyenv rehash && $HOME/.pyenv/shims/pip install argcomplete" do
    not_if "$HOME/.pyenv/shims/pip list | fgrep -q argcomplete"
    cwd node[:setup][:home]
  end
end

execute "$HOME/.pyenv/shims/pip install --upgrade pip" do
  only_if "test -x $HOME/.pyenv/shims/pip"
end
