# frozen_string_literal: true

execute "curl https://pyenv.run | bash" do
  not_if { File.exists? "#{ENV["HOME"]}/.pyenv/bin" }
end

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
    cwd ENV["HOME"]
  end
end

execute "$HOME/.pyenv/shims/pip install --upgrade pip"
