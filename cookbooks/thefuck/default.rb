package "thefuck"

add_profile "thefuck" do
  bash_content <<~EOS
    eval $(thefuck --alias --enable-experimental-instant-mode)
  EOS
end
