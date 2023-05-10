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

