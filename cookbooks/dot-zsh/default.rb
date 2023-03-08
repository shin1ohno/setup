include_cookbook "typewritten"
include_cookbook "oh-my-zsh"

add_profile "dot-zsh" do
  priority 10
  bash_content <<"EOM"
export PATH=#{ENV['HOME']}/.local/bin:$PATH
export ARCHPREFERENCE=arm64
alias bri="envchain bricolage bundle exec bricolage"
autoload -U bashcompinit
bashcompinit
EOM
end
