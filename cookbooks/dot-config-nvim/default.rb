# frozen_string_literal: true

directory "#{ENV["HOME"]}/.config/" do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
  action :create
end

git_clone "nvim" do
  uri "https://github.com/AstroNvim/AstroNvim nvim"
  cwd "#{ENV["HOME"]}/.config/"
end

git_clone "user" do
  uri "git@github.com:shin1ohno/AstroNvimUserOpts.git user"
  cwd "#{ENV["HOME"]}/.config/nvim/lua/"
end

%w(
pynvim
python-lsp-server[all] pylsp-mypy pyls-isort
pylint flake8
vim-vint
).each do |requirement|
  execute "$HOME/.pyenv/shims/pip install -U #{requirement}" do
    not_if "$HOME/.pyenv/shims/pip list | fgrep -q #{requirement.split("[")[0]}"
  end
end

%w(
  typescript
  typescript-language-server
  @tailwindcss/language-server
).each do |requirement|
  execute "$HOME/.volta/bin/npm install -g #{requirement}" do
    if requirement == "@tailwindcss/language-server"
      requirement = "tailwindcss-language-server"
    elsif requirement == "typescript"
      requirement = "tsserver"
    end
    not_if "which #{requirement}"
    cwd ENV["HOME"]
  end
end

execute "git pull" do
  cwd "#{ENV["HOME"]}/.config/nvim/lua/user"
end

execute "mkdir -p ~/.local/bin"

execute "curl -Ls -o #{ENV["HOME"]}/.local/bin/im-select https://github.com/daipeihust/im-select/blob/8080ad18f20218d1b6b5ef81d26cc5452d56b165/im-select-mac/out/apple/im-select" do
  not_if "which im-select"
end

execute "chmod 777 /Users/shin1ohno/.local/bin/im-select"

execute "nvim --headless -c 'quitall'"
