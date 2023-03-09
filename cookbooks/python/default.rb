package "pyenv"

add_profile "pyenv" do
  bash_content <<~EOS
    export PYENV_ROOT="$HOME/.pyenv"
    command -v pyenv >/dev/null || export PATH="$PYENV_ROOT/bin:$PATH"
    eval "$(pyenv init -)"
    eval `register-python-argcomplete pipx`
  EOS
end

%w(3.9.9).each do |version|
  execute "pyenv install #{version}" do
    not_if "pyenv versions | grep #{version}"
  end

  execute "pyenv global #{version} && python -m ensurepip --upgrade" do
    not_if "which pip"
  end
end
