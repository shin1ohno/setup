directory "#{ENV["HOME"]}/.config/" do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode '755'
  action :create
end

git_clone "nvim" do
  uri "https://github.com/jdhao/nvim-config.git nvim"
  cwd "#{ENV["HOME"]}/.config/"
end

%w(
pynvim
python-lsp-server[all] pylsp-mypy pyls-isort
pylint flake8
vim-vint
).each do |requirement|
  execute "$(pyenv prefix)/bin/pip install -U #{requirement}" do
    not_if "$(pyenv prefix)/bin/pip list | fgrep -q #{requirement.split("[")[0]}"
  end
end

execute "npm install -g vim-language-server" do
  not_if "which vim-language-server"
  cwd ENV["HOME"]
end

execute "git pull" do
  cwd "#{ENV["HOME"]}/.config/nvim"
end
