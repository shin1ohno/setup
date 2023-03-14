# frozen_string_literal: true

case node[:platform]
when "darwin"
  then
    package "typewritten"

    add_profile "typewritten" do
      bash_content <<"EOM"
      ZSH_THEME=""
      TYPEWRITTEN_PROMPT_LAYOUT="multiline"
      TYPEWRITTEN_RELATIVE_PATH="adaptive"
      TYPEWRITTEN_CURSOR="terminal"
      TYPEWRITTEN_DISABLE_RETURN_CODE=true
      autoload -U promptinit; promptinit
      prompt typewritten
EOM
    end
else
  execute "git clone https://github.com/reobin/typewritten.git #{node[:setup][:root]}/typewritten" do
    not_if { File.exists? "#{node[:setup][:root]}/typewritten" }
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
      autoload -U promptinit; promptinit
      prompt typewritten
EOM
    end
end
