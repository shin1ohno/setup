# frozen_string_literal: true

# Ensure Node.js is installed via mise for language servers
include_cookbook "nodejs"

directory "#{ENV["HOME"]}/.config/" do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
  action :create
end

git_clone "nvim" do
  uri "git@github.com:shin1ohno/astro.git nvim"
  cwd "#{ENV["HOME"]}/.config/"
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
  typescript@beta
  typescript-language-server@latest
  @tailwindcss/language-server@latest
).each do |package_spec|
  package_name = package_spec.sub(/@[^@]+$/, "")
  execute "install #{package_name} via mise" do
    user node[:setup][:user]
    command "$HOME/.local/bin/mise use --global npm:#{package_spec}"
    not_if "$HOME/.local/bin/mise list | grep -q 'npm:#{package_name}'"
    cwd ENV["HOME"]
  end
end

execute "git pull" do
  cwd "#{ENV["HOME"]}/.config/nvim/"
end

execute "mkdir -p ~/.local/bin" do
  not_if "test -d ~/.local/bin"
end

case node[:platform]
when "darwin"
  execute "brew tap daipeihust/tap && brew install im-select" do
    not_if "which im-select"
  end
end
