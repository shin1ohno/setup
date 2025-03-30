remote_file "#{node[:setup][:root]}/uv-install.sh" do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
  source "files/install.sh"
end

execute "sh #{node[:setup][:root]}/uv-install.sh" do
  not_if "which uv"
end

add_profile "uv" do
  bash_content <<~EOS
    # uv Python package manager
    export PATH="$HOME/.cargo/bin:$PATH"
    alias pip="uv pip"
    alias venv="uv venv"
  EOS
  fish_content <<~FISH
    # uv Python package manager
    fish_add_path -m $HOME/.cargo/bin
    alias pip="uv pip"
    alias venv="uv venv"
  FISH
end

