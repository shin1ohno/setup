# frozen_string_literal: true

execute "git clone https://github.com/reobin/typewritten.git #{node[:setup][:root]}/typewritten" do
  not_if { File.exist? "#{node[:setup][:root]}/typewritten" }
end

add_profile "typewritten" do
  bash_content <<"EOM"
  fpath+=#{node[:setup][:root]}/typewritten
  autoload -U promptinit; promptinit
  prompt typewritten
  ZSH_THEME=""
  TYPEWRITTEN_PROMPT_LAYOUT="multiline"
  TYPEWRITTEN_RELATIVE_PATH="adaptive"
  TYPEWRITTEN_CURSOR="terminal"
  TYPEWRITTEN_DISABLE_RETURN_CODE=true
EOM
end

if node[:platform] == "darwin"
  package "typewritten" do
    action :remove
    only_if { brew_formula?("typewritten") }
  end
end
