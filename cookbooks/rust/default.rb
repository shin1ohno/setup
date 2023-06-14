execute "curl https://sh.rustup.rs -sSf | sh -s -- --no-modify-path -y" do
  not_if { File.exists? "#{ENV["HOME"]}/.cargo/env" }
end

add_profile "cargo" do
  bash_content 'source "$HOME/.cargo/env"'
end

execute "$HOME/.cargo/bin/rustup update stable"
execute "$HOME/.cargo/bin/cargo install bottom --locked" do
  not_if "which btm"
end
