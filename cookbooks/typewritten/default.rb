# frozen_string_literal: true

package "typewritten"

add_profile "homebrew" do
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
