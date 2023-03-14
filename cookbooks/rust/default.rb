execute "curl https://sh.rustup.rs -sSf | sh -s -- --no-modify-path -y" do
  not_if { File.exists? "$HOME/.cargo/" }
end

add_profile "cargo" do
  bash_content 'source "$HOME/.cargo/env"'
end
